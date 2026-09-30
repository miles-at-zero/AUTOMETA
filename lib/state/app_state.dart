import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_services.dart';
import '../core/utils/logger.dart';
import '../data/repositories/recipient.dart';
import '../domain/engine/engine_events.dart';
import '../domain/engine/approval_request.dart';
import '../domain/engine/engine_ports.dart';
import '../domain/engine/idempotency.dart';
import '../domain/models/execution.dart';
import '../domain/models/execution_status.dart';
import '../domain/models/workflow.dart';
import '../domain/schedule/schedule_calculator.dart';
import '../services/notifications/notification_service.dart';
import '../services/templates/template_gallery.dart';

/// One row in the dashboard's "TODAY" list.
@immutable
class ScheduledSlot {
  const ScheduledSlot({required this.at, required this.workflow, this.execution});

  final DateTime at;
  final Workflow workflow;

  /// The recorded outcome, when this slot has already fired.
  final ExecutionRecord? execution;

  ExecutionStatus get status => execution?.status ?? ExecutionStatus.pending;

  bool get hasRun => execution != null;
}

/// Application-wide observable state.
///
/// The single place the UI reads automation data from. It owns the subscription
/// to the engine's event stream, so every screen updates when a background run
/// finishes — including one started by AlarmManager while the app was closed.
class AppState extends ChangeNotifier {
  AppState({required this.services}) {
    _subscription = services.engine.events.listen(_onEngineEvent, onError: _onError);
  }

  final AppServices services;
  final Logger _log = Logger.withTag('STATE');

  StreamSubscription<EngineEvent>? _subscription;

  List<Workflow> _workflows = <Workflow>[];
  List<ExecutionRecord> _recent = <ExecutionRecord>[];
  List<ScheduledSlot> _today = <ScheduledSlot>[];
  List<ApprovalTicket> _approvals = <ApprovalTicket>[];
  WorkflowRun? _nextRun;
  List<WorkflowRun> _upcoming = <WorkflowRun>[];
  bool _loading = true;
  String? _lastError;

  List<Workflow> get workflows => _workflows;
  List<ExecutionRecord> get recentExecutions => _recent;
  List<ScheduledSlot> get todaySlots => _today;
  List<ApprovalTicket> get pendingApprovals => _approvals;
  WorkflowRun? get nextRun => _nextRun;
  List<WorkflowRun> get upcoming => _upcoming;
  bool get isLoading => _loading;
  String? get lastError => _lastError;

  bool get isPaused => services.settings.isPaused;

  int get activeCount => _workflows.where((Workflow w) => w.enabled).length;

  int get failureCount =>
      _recent.where((ExecutionRecord e) => e.status == ExecutionStatus.failed).length;

  ExecutionRecord? get lastExecution => _recent.isEmpty ? null : _recent.first;

  bool get hasAnyWorkflow => _workflows.isNotEmpty;

  Future<void> refresh() async {
    try {
      final List<Workflow> workflows = await services.workflows.getAll();
      final ScheduleCalculator calculator = services.calculator;

      _workflows = workflows;
      _nextRun = calculator.nextRunAcross(workflows);
      _upcoming = calculator.upcomingRuns(workflows, limit: 8);
      _recent = await services.executions.recent(limit: 40);
      _approvals = await services.approvals.pending();

      // Build today's slot list: scheduled occurrences plus what actually ran.
      final DateTime now = DateTime.now();
      final DateTime start = DateTime(now.year, now.month, now.day);
      final DateTime end = start.add(const Duration(days: 1));
      final List<ExecutionRecord> ranToday = await services.executions.onDay(now);
      final Map<String, ExecutionRecord> ranByKey = <String, ExecutionRecord>{
        for (final ExecutionRecord record in ranToday) record.idempotencyKey.split('#').first: record,
      };

      final List<ScheduledSlot> slots = <ScheduledSlot>[];
      for (final Workflow workflow in workflows) {
        if (!workflow.enabled || !workflow.isScheduled) continue;
        for (final DateTime at in calculator.occurrencesBetween(workflow, from: start, to: end)) {
          final String key = IdempotencyKeys.forScheduledRun(workflow: workflow, scheduledFor: at);
          slots.add(ScheduledSlot(at: at, workflow: workflow, execution: ranByKey[key]));
        }
      }
      // Manual and event-driven runs have their own keys, so surface them too.
      for (final ExecutionRecord record in ranToday) {
        final bool alreadyListed =
            slots.any((ScheduledSlot s) => s.execution?.id == record.id);
        if (!alreadyListed) {
          final Workflow? workflow = _workflowById(record.workflowId);
          if (workflow != null) {
            slots.add(ScheduledSlot(at: record.scheduledFor, workflow: workflow, execution: record));
          }
        }
      }
      slots.sort((ScheduledSlot a, ScheduledSlot b) => a.at.compareTo(b.at));
      _today = slots;

      _lastError = null;
    } catch (error, stackTrace) {
      _log.error('Refresh failed', error, stackTrace);
      _lastError = '$error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Workflow? _workflowById(String id) {
    for (final Workflow workflow in _workflows) {
      if (workflow.id == id) return workflow;
    }
    return null;
  }

  Workflow? workflowById(String id) => _workflowById(id);

  void _onEngineEvent(EngineEvent event) {
    if (event is ExecutionFinishedEvent ||
        event is ExecutionSkippedEvent ||
        event is ApprovalRequestedEvent) {
      unawaited(refresh());
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    _log.error('Engine stream error', error, stackTrace);
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<Workflow> save(Workflow workflow) async {
    final Workflow saved = await services.workflows.save(workflow);
    await services.scheduler.armWorkflow(saved);
    await refresh();
    return saved;
  }

  Future<void> delete(String workflowId) async {
    await services.scheduler.disarmWorkflow(workflowId);
    await services.approvals.deleteForWorkflow(workflowId);
    await services.workflows.delete(workflowId);
    await refresh();
  }

  Future<void> setEnabled(String workflowId, bool enabled) async {
    final Workflow? workflow = await services.workflows.byId(workflowId);
    if (workflow == null) return;
    final Workflow updated = workflow.copyWith(enabled: enabled);
    await services.workflows.save(updated);
    if (enabled) {
      await services.scheduler.armWorkflow(updated);
    } else {
      await services.scheduler.disarmWorkflow(workflowId);
    }
    await refresh();
  }

  Future<Workflow> duplicate(Workflow workflow, {String Function()? idGenerator}) async {
    final String newId = idGenerator == null
        ? DateTime.now().microsecondsSinceEpoch.toRadixString(36)
        : idGenerator();
    final Workflow copy = workflow.copyWith(name: '${workflow.name} (copy)');
    final Workflow renamed = Workflow.fromJson(<String, dynamic>{
      ...copy.toJson(),
      'id': newId,
      'enabled': false,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    return save(renamed);
  }

  Future<ExecutionRecord?> runNow(String workflowId) async {
    final ExecutionRecord? record = await services.execution.runNow(workflowId);
    await refresh();
    return record;
  }

  Future<DryRunReport> dryRun(Workflow workflow) => services.execution.dryRun(workflow);

  Future<ExecutionRecord?> retry(String executionId) async {
    final ExecutionRecord? record = await services.execution.retry(executionId);
    await refresh();
    return record;
  }

  Future<ExecutionRecord?> resolveApproval(String ticketId, {required bool approved}) async {
    final ExecutionRecord? record =
        await services.execution.resolveApproval(ticketId: ticketId, approved: approved);
    await refresh();
    return record;
  }

  Future<void> setPaused(bool paused) async {
    await services.settings.setPaused(paused);
    if (paused) {
      await services.scheduler.disarmAll();
    } else {
      await services.scheduler.syncAll();
    }
    await refresh();
  }

  /// Creates a workflow from a gallery template and enables it if asked.
  Future<Workflow> instantiateTemplate(
    AutomationTemplate template, {
    required String timeZone,
    bool enable = false,
    String recipient = 'Dad',
  }) async {
    final Workflow workflow = template.instantiate(
      timeZone: timeZone,
      recipient: recipient,
    );
    final Workflow enabled = enable ? workflow.copyWith(enabled: true) : workflow;
    return save(enabled);
  }

  Future<void> installStarters({required String timeZone, String recipient = 'Dad'}) async {
    for (final AutomationTemplate template in TemplateGallery.starters) {
      if (template.id == 'sunday_ai_summary') continue;
      await instantiateTemplate(
        template,
        timeZone: timeZone,
        recipient: recipient,
        enable: true,
      );
    }
  }

  /// Creates the default recipient alias with no number attached, so a user
  /// can build workflows before deciding who they message (spec §5).
  Future<void> seedDefaultContact() async {
    final String name = services.settings.defaultRecipientName;
    final Recipient? existing = await services.contacts.byAlias(name);
    if (existing != null) return;
    await services.contacts.save(Recipient(
      id: 'contact-${name.toLowerCase()}',
      alias: name,
      displayName: name,
      phoneE164: '',
      notes: 'Added automatically. Set the number before WhatsApp blocks can run.',
    ));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }
}
