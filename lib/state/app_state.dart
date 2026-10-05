import '../domain/models/step.dart';
import '../services/integrations/whatsapp/whatsapp_models.dart';
import '../services/integrations/whatsapp/whatsapp_adapter.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../cloud/cloud_session.dart';
import '../domain/capabilities/execution_capabilities.dart';
import '../domain/models/execution_mode.dart';

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
/// Outcome of "Move to Cloud" / "Move to this device".
class MoveResult {
  const MoveResult({required this.ok, required this.message, this.issues = const <CapabilityIssue>[], this.needsAccount = false});

  final bool ok;
  final String message;
  final List<CapabilityIssue> issues;
  final bool needsAccount;
}

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

  /// Set once the Cloud session exists (see main.dart).
  CloudSession? cloud;

  /// Saves locally, and for Cloud automations mirrors the change to the
  /// backend (which owns their scheduling). An enabled Cloud automation is
  /// only saved once the backend accepted it, so the phone never shows
  /// "Active" for something that isn't running anywhere. Throws
  /// [CloudException] with the blocking items.
  Future<Workflow> save(Workflow workflow) async {
    Workflow toSave = workflow;
    if (workflow.isCloud) {
      final CloudSession? c = cloud;
      if (c == null || !c.signedIn) {
        if (workflow.enabled) {
          throw CloudException('Sign in to Autometa Cloud to activate Cloud automations. Your draft can be saved as inactive.', needsAccount: true);
        }
      } else if (workflow.enabled || workflow.cloudId != null) {
        toSave = workflow.copyWith(cloudId: await c.sync(workflow));
      }
    }
    final Workflow saved = await services.workflows.save(toSave);
    await services.scheduler.armWorkflow(saved); // Disarms Cloud ones.
    await refresh();
    return saved;
  }

  Future<void> delete(String workflowId) async {
    final Workflow? w = await services.workflows.byId(workflowId);
    if (w?.cloudId != null && cloud?.signedIn == true) {
      try {
        await cloud!.remove(w!.cloudId!);
      } on CloudException catch (e) {
        if (e.offline) rethrow; // Don't orphan a running Cloud automation.
      }
    }
    await services.scheduler.disarmWorkflow(workflowId);
    await services.approvals.deleteForWorkflow(workflowId);
    await services.workflows.delete(workflowId);
    await refresh();
  }

  Future<void> setEnabled(String workflowId, bool enabled) async {
    final Workflow? workflow = await services.workflows.byId(workflowId);
    if (workflow == null) return;
    if (workflow.isCloud) {
      await save(workflow.copyWith(enabled: enabled));
      return;
    }
    final Workflow updated = workflow.copyWith(enabled: enabled);
    await services.workflows.save(updated);
    if (enabled) {
      await services.scheduler.armWorkflow(updated);
    } else {
      await services.scheduler.disarmWorkflow(workflowId);
    }
    await refresh();
  }

  /// Steps 1-12 of the migration spec: validate every block for Cloud, then
  /// create the Cloud copy with the same name/trigger/conditions/actions,
  /// switch the mode, and stop the phone's alarms. Local history stays on the
  /// same automation. Nothing changes when any step can't move.
  Future<MoveResult> moveToCloud(Workflow w) async {
    final List<CapabilityIssue> blocking = ExecutionCapabilities.check(w, ExecutionMode.cloud);
    if (blocking.isNotEmpty) {
      return MoveResult(ok: false, message: 'This automation needs attention before it can move to Cloud.', issues: blocking);
    }
    final CloudSession? c = cloud;
    if (c == null || !c.signedIn) {
      return const MoveResult(ok: false, needsAccount: true, message: 'Sign in to Autometa Cloud first. It\'s what keeps automations running when your phone is off.');
    }
    try {
      final Workflow moved = w.copyWith(executionMode: ExecutionMode.cloud);
      final String id = await c.sync(moved);
      await services.workflows.save(moved.copyWith(cloudId: id));
      await services.scheduler.disarmWorkflow(w.id);
      await refresh();
      return MoveResult(ok: true, message: '"${w.name}" now runs in Cloud${w.enabled ? ' and keeps running when Autometa is closed' : ''}.');
    } on CloudException catch (e) {
      return MoveResult(ok: false, message: e.message, issues: e.issues, needsAccount: e.needsAccount);
    }
  }

  /// Only offered when every block can run on the phone. The Cloud copy is
  /// paused (not deleted) so its history stays available.
  Future<MoveResult> moveToDevice(Workflow w) async {
    final List<CapabilityIssue> blocking = ExecutionCapabilities.check(w, ExecutionMode.onDevice);
    if (blocking.isNotEmpty) {
      return MoveResult(ok: false, message: 'This automation can\'t run on this device.', issues: blocking);
    }
    try {
      if (w.cloudId != null && cloud?.signedIn == true) await cloud!.pause(w.cloudId!);
    } on CloudException catch (e) {
      return MoveResult(ok: false, message: e.message);
    }
    final Workflow local = w.copyWith(executionMode: ExecutionMode.onDevice);
    await services.workflows.save(local);
    await services.scheduler.armWorkflow(local);
    await refresh();
    return MoveResult(ok: true, message: '"${w.name}" now runs on this device. ${ExecutionCopy.recommendation}');
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

  /// Runs on the device for On-device automations. Cloud ones run on the
  /// backend through [CloudSession.run] (see the automation screen).
  Future<ExecutionRecord?> runNow(String workflowId) async {
    final Workflow? w = _workflowById(workflowId);
    if (w != null && w.isCloud) {
      final CloudSession? c = cloud;
      if (c == null || w.cloudId == null) throw CloudException('Sign in to Autometa Cloud and save this automation first.', needsAccount: c?.signedIn != true);
      await c.run(w.cloudId!);
      return null;
    }
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
    // New automations get the user's default (Cloud unless changed) when every
    // block supports it; device-only templates (e.g. "Prepare WhatsApp") stay local.
    ExecutionMode mode = ExecutionCapabilities.bestModeFor(workflow, services.settings.defaultExecution);
    if (mode.isCloud && enable && cloud?.signedIn != true && ExecutionCapabilities.check(workflow, ExecutionMode.onDevice).isEmpty) {
      mode = ExecutionMode.onDevice; // Can't activate in Cloud without an account.
    }
    final Workflow typed = workflow.copyWith(executionMode: mode);
    final Workflow enabled = enable ? typed.copyWith(enabled: true) : typed;
    try {
      return await save(enabled);
    } on CloudException {
      // Cloud unreachable or not ready: never lose the template. Run it on the
      // device when every block allows, otherwise keep it as an inactive draft.
      if (ExecutionCapabilities.check(workflow, ExecutionMode.onDevice).isEmpty) {
        return save(enabled.copyWith(executionMode: ExecutionMode.onDevice));
      }
      return save(enabled.copyWith(enabled: false));
    }
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

  /// Pre-activation check for on-device WhatsApp "send" blocks: automatic
  /// sending only exists through WhatsApp Business. If the block would use
  /// Personal WhatsApp, or Business isn't set up, explain it now, before
  /// activation, instead of failing at run time. Nothing is ever converted to
  /// "prepare". (Cloud sends are checked by the Cloud mapper/validator.)
  Future<List<String>> whatsappSendProblems(Workflow w) async {
    if (w.isCloud) return const <String>[];
    final List<String> out = <String>[];
    Future<void> walk(List<WorkflowStep> steps) async {
      for (final WorkflowStep s in steps) {
        if (s is ConditionStep) await walk(s.thenSteps);
        if (s is! WhatsAppStep || s.mode != WhatsAppMode.send) continue;
        final WhatsAppAdapter? a = await services.whatsapp.adapterFor(s.account);
        if (a == null || a.accountType == WhatsAppAccountType.personal) {
          out.add('"${s.describe()}" uses Personal WhatsApp, which can\'t send automatically. '
              'Switch the block to "Prepare message" (you tap Send), or choose the WhatsApp Business account.');
        } else if (!await a.canSendNow()) {
          out.add('"${s.describe()}" needs WhatsApp Business, which isn\'t set up. Connect it in Connections → WhatsApp.');
        }
      }
    }

    await walk(w.steps);
    return out;
  }
}
