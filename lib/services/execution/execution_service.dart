import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../../data/repositories/approval_repository.dart';
import '../../data/repositories/execution_repository.dart';
import '../../data/repositories/workflow_repository.dart';
import '../../domain/engine/approval_request.dart';
import '../../domain/engine/engine_ports.dart';
import '../../domain/engine/idempotency.dart';
import '../../domain/engine/workflow_engine.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_status.dart';
import '../../domain/models/trigger.dart';
import '../../domain/models/workflow.dart';
import '../../domain/schedule/schedule_calculator.dart';
import '../notifications/notification_service.dart';
import '../scheduler/scheduler_service.dart';

/// Orchestrates a single automation run end to end.
///
/// This is the layer both the UI and the background isolate call. It owns the
/// order of operations: load → guard → run → notify → re-arm. Keeping that
/// sequence in one place is what stops the two callers from drifting apart.
class ExecutionService {
  ExecutionService({
    required this.engine,
    required this.workflows,
    required this.executions,
    required this.approvals,
    required this.scheduler,
    required this.notifications,
    required this.calculator,
    required this.pausedProvider,
    this.catchUpWindow = const Duration(hours: 2),
  });

  final WorkflowEngine engine;
  final WorkflowRepository workflows;
  final ExecutionRepository executions;
  final ApprovalRepository approvals;
  final SchedulerService scheduler;
  final NotificationService notifications;
  final ScheduleCalculator calculator;

  /// Spec §25: the single source of truth for "pause everything".
  final Future<bool> Function() pausedProvider;

  /// How far back catch-up will look. Beyond this a missed run is recorded as
  /// skipped rather than fired, because a 3-day-late "good morning" is worse
  /// than no message at all.
  final Duration catchUpWindow;

  final Logger _log = Logger.withTag(LogTags.engine);

  /// A scheduled alarm fired.
  Future<ExecutionRecord?> runScheduled({
    required String workflowId,
    required DateTime scheduledFor,
  }) async {
    final Workflow? workflow = await workflows.byId(workflowId);
    if (workflow == null) {
      _log.warn('Alarm fired for unknown workflow $workflowId');
      return null;
    }
    if (!workflow.enabled) {
      _log.info('Alarm fired for disabled workflow "${workflow.name}"');
      return null;
    }

    // After a reboot or a long Doze, Android delivers overdue alarms at once.
    // A "good morning" that is hours late is worse than none: record a SKIP.
    final Duration late = DateTime.now().toUtc().difference(scheduledFor.toUtc());
    await _recordAlarmFire(workflow, scheduledFor, late);
    if (late > catchUpWindow) {
      final String key = IdempotencyKeys.forScheduledRun(workflow: workflow, scheduledFor: scheduledFor);
      final ExecutionRecord skipped =
          await executions.anyForKey(key) ? (await executions.lastForWorkflow(workflow.id))! : await _recordSkipped(workflow, scheduledFor);
      await scheduler.armWorkflow(workflow, after: _afterSlot(scheduledFor));
      return skipped;
    }

    final ExecutionRecord record = await engine.execute(
      workflow,
      source: TriggerSource.schedule,
      scheduledFor: scheduledFor,
      isBackground: true,
    );
    await notifications.notifyExecution(record);
    await _armResumeIfDeferred(record);

    // Re-arm for the next occurrence regardless of this run's outcome, so a
    // failure today does not silence the automation forever. Computed from
    // after the slot that just ran: an alarm delivered slightly early must
    // not re-arm the same slot (which would loop until the clock passes it).
    await scheduler.armWorkflow(workflow, after: _afterSlot(scheduledFor));
    return record;
  }

  /// User pressed "Run now".
  Future<ExecutionRecord?> runNow(String workflowId) async {
    final Workflow? workflow = await workflows.byId(workflowId);
    if (workflow == null) return null;
    final ExecutionRecord record = await engine.execute(
      workflow,
      source: TriggerSource.manual,
      scheduledFor: DateTime.now(),
    );
    await notifications.notifyExecution(record);
    await _armResumeIfDeferred(record);
    return record;
  }

  /// Webhook / app-event entry point.
  Future<ExecutionRecord?> runFromEvent({
    required String workflowId,
    required TriggerSource source,
    Map<String, String> variables = const <String, String>{},
  }) async {
    final Workflow? workflow = await workflows.byId(workflowId);
    if (workflow == null) return null;
    final ExecutionRecord record = await engine.execute(
      workflow,
      source: source,
      scheduledFor: DateTime.now(),
      runtimeVariables: variables,
    );
    await notifications.notifyExecution(record);
    await _armResumeIfDeferred(record);
    return record;
  }

  /// Test run (spec §24). Never touches the duplicate guard or the scheduler.
  Future<DryRunReport> dryRun(Workflow workflow) => engine.dryRun(workflow);

  /// Retries a failed run (spec §22).
  ///
  /// A retry is a *new* attempt with a fresh ad-hoc key: reusing the original
  /// key would be rejected by the duplicate guard, which is the correct
  /// behaviour for a schedule but not for an explicit user retry.
  Future<ExecutionRecord?> retry(String executionId) async {
    final ExecutionRecord? original = await executions.byId(executionId);
    if (original == null) return null;
    final Workflow? workflow = await workflows.byId(original.workflowId);
    if (workflow == null) return null;

    final ExecutionRecord record = await engine.execute(
      workflow,
      source: TriggerSource.retry,
      scheduledFor: original.scheduledFor,
    );
    await notifications.notifyExecution(record);
    await _armResumeIfDeferred(record);
    return record;
  }

  /// Approves or rejects a pending action (spec §23).
  Future<ExecutionRecord?> resolveApproval({
    required String ticketId,
    required bool approved,
  }) async {
    final ApprovalTicket? ticket = await approvals.byId(ticketId);
    if (ticket == null) return null;

    if (ticket.isExpiredAt(DateTime.now())) {
      await approvals.decide(ticketId, ApprovalDecision.expired);
      final ExecutionRecord? record = await executions.byId(ticket.executionId);
      return record?.copyWith(
        status: ExecutionStatus.skipped,
        finishedAt: DateTime.now(),
        failureReason: 'Approval expired before a decision',
        failureCode: 'approval.expired',
        clearPending: true,
      );
    }

    final Workflow? workflow = await workflows.byId(ticket.workflowId);
    final ExecutionRecord? record = await executions.byId(ticket.executionId);
    await approvals.decide(ticketId, approved ? ApprovalDecision.approved : ApprovalDecision.rejected);

    if (workflow == null || record == null) {
      _log.warn('Approval $ticketId refers to a workflow or run that no longer exists');
      return null;
    }

    final ExecutionRecord resumed = await engine.resumeAfterApproval(
      workflow: workflow,
      record: record,
      approved: approved,
    );
    await notifications.notifyExecution(resumed);
    await _armResumeIfDeferred(resumed);
    return resumed;
  }

  /// Fires runs that were deferred or dropped while the app was not running.
  ///
  /// Android can delay an exact alarm under Doze or drop it entirely after a
  /// force-stop. Rather than promise punctuality, AUTOMETA detects the gap on
  /// the next maintenance wake and either catches up (inside [catchUpWindow])
  /// or records an honest SKIP.
  Future<List<ExecutionRecord>> catchUpMissedRuns() async {
    final List<ExecutionRecord> outcomes = <ExecutionRecord>[];
    final DateTime now = DateTime.now();
    final List<Workflow> enabled = await workflows.getEnabled();

    for (final Workflow workflow in enabled) {
      final DateTime? next = calculator.nextOccurrence(workflow);
      if (next == null) continue;

      // Walk backwards from the next scheduled slot to find slots that were
      // missed between the last known run and now.
      final ExecutionRecord? last = await executions.lastForWorkflow(workflow.id);
      DateTime cursor = last == null
          ? now.subtract(catchUpWindow)
          : last.scheduledFor;
      if (cursor.isBefore(now.subtract(catchUpWindow))) {
        cursor = now.subtract(catchUpWindow);
      }

      int guard = 0;
      while (guard++ < 8) {
        final DateTime? slot = calculator.nextOccurrence(workflow, after: cursor);
        if (slot == null || !slot.isBefore(now)) break;
        cursor = slot;

        final String key = IdempotencyKeys.forScheduledRun(
          workflow: workflow,
          scheduledFor: slot,
        );
        if (await executions.anyForKey(key)) continue;

        final bool insideWindow = now.difference(slot) <= catchUpWindow;
        _log.info('Catch-up for "${workflow.name}" @ ${slot.toIso8601String()} '
            '(${insideWindow ? 'running' : 'too old — recording SKIP'})');

        final ExecutionRecord record = insideWindow
            ? await engine.execute(
                workflow,
                source: TriggerSource.schedule,
                scheduledFor: slot,
                isBackground: true,
              )
            : await _recordSkipped(workflow, slot);
        outcomes.add(record);
        if (insideWindow) await notifications.notifyExecution(record);
      }
    }

    return outcomes;
  }

  static DateTime _afterSlot(DateTime slot) {
    final DateTime now = DateTime.now().toUtc();
    final DateTime past = slot.toUtc().add(const Duration(seconds: 1));
    return past.isAfter(now) ? past : now;
  }

  /// Optional diagnostics hook: every alarm delivery and how late it was.
  Future<void> Function(Workflow workflow, DateTime scheduledFor, Duration late)? alarmFireLog;

  Future<void> _recordAlarmFire(Workflow workflow, DateTime scheduledFor, Duration late) async {
    try {
      await alarmFireLog?.call(workflow, scheduledFor, late);
    } catch (error) {
      _log.warn('Could not record alarm diagnostics', error);
    }
  }

  Future<ExecutionRecord> _recordSkipped(Workflow workflow, DateTime slot) async {
    final ExecutionRecord record = ExecutionRecord(
      id: IdempotencyKeys.forScheduledRun(workflow: workflow, scheduledFor: slot),
      workflowId: workflow.id,
      workflowName: workflow.name,
      idempotencyKey: IdempotencyKeys.forScheduledRun(
        workflow: workflow,
        scheduledFor: slot,
      ),
      scheduledFor: slot,
      status: ExecutionStatus.skipped,
      source: TriggerSource.schedule,
      startedAt: DateTime.now(),
      finishedAt: DateTime.now(),
      failureReason: 'Missed while the app was not running and too old to send now',
      failureCode: 'engine.missed',
      createdAt: DateTime.now(),
    );
    await executions.insert(record);
    return record;
  }

  /// Runs any execution parked on a deferred `WAIT` whose time has come.
  Future<List<ExecutionRecord>> resumeDeferredRuns() async {
    final List<ExecutionRecord> pending = await executions.pending();
    final DateTime now = DateTime.now();
    final List<ExecutionRecord> resumed = <ExecutionRecord>[];

    for (final ExecutionRecord record in pending) {
      final DateTime? resumeAt = record.resumeAt;
      if (record.status != ExecutionStatus.pending || resumeAt == null) continue;
      if (resumeAt.isAfter(now)) continue;

      final Workflow? workflow = await workflows.byId(record.workflowId);
      if (workflow == null) continue;

      resumed.add(await engine.resumeAfterApproval(
        workflow: workflow,
        record: record,
        approved: true,
        isApprovalDecision: false,
      ));
    }
    return resumed;
  }

  Future<void> _armResumeIfDeferred(ExecutionRecord record) async {
    final DateTime? at = record.resumeAt;
    if (record.status == ExecutionStatus.pending && at != null) {
      await scheduler.armResume(executionId: record.id, at: at);
    }
  }

  /// Expires approvals nobody answered.
  Future<int> expireStaleApprovals() => approvals.expireStale();
}
