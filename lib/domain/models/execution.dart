import 'package:flutter/foundation.dart';

import '../../core/utils/json_utils.dart';
import 'execution_status.dart';
import 'step.dart';

/// What happened to a single block during a run.
///
/// `simulated` exists so a dry run can never be mistaken for a real effect
/// (spec §24, §40).
enum StepOutcome {
  pending('pending', 'Pending'),
  success('success', 'Done'),
  failed('failed', 'Failed'),
  skipped('skipped', 'Skipped'),
  awaitingApproval('awaiting_approval', 'Waiting for approval'),
  simulated('simulated', 'Simulated');

  const StepOutcome(this.wire, this.label);

  final String wire;
  final String label;

  static StepOutcome fromWire(Object? value, {StepOutcome fallback = pending}) {
    final String raw = '$value'.toLowerCase();
    for (final StepOutcome outcome in StepOutcome.values) {
      if (outcome.wire == raw || outcome.name.toLowerCase() == raw) return outcome;
    }
    return fallback;
  }
}

/// Why a run started. Persisted with the execution so the activity log can
/// distinguish a schedule firing from a user pressing "Run now".
enum TriggerSource {
  schedule('schedule', 'Schedule'),
  manual('manual', 'Manual run'),
  test('test', 'Test run'),
  webhook('webhook', 'Webhook'),
  appEvent('app_event', 'App event'),
  approvalResume('approval_resume', 'Resumed after approval'),
  retry('retry', 'Retry');

  const TriggerSource(this.wire, this.label);

  final String wire;
  final String label;

  static TriggerSource fromWire(Object? value, {TriggerSource fallback = manual}) {
    final String raw = '$value'.toLowerCase();
    for (final TriggerSource source in TriggerSource.values) {
      if (source.wire == raw || source.name.toLowerCase() == raw) return source;
    }
    return fallback;
  }
}

/// The recorded outcome of one block.
@immutable
class StepExecution {
  const StepExecution({
    required this.stepId,
    required this.kind,
    required this.title,
    required this.outcome,
    this.detail,
    this.code,
    this.startedAt,
    this.finishedAt,
    this.attempts = 1,
    this.simulated = false,
  });

  final String stepId;
  final StepKind kind;
  final String title;
  final StepOutcome outcome;
  final String? detail;

  /// Machine code for the outcome, e.g. `whatsapp.handed_to_user`. The UI uses
  /// this to refuse to print "Sent" for anything it cannot confirm.
  final String? code;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int attempts;

  /// True when the block ran in a dry run, or was a no-op preview.
  final bool simulated;

  Duration? get duration {
    final DateTime? start = startedAt;
    final DateTime? end = finishedAt;
    if (start == null || end == null) return null;
    return end.difference(start);
  }

  StepExecution copyWith({
    StepOutcome? outcome,
    String? detail,
    String? code,
    DateTime? finishedAt,
    int? attempts,
  }) =>
      StepExecution(
        stepId: stepId,
        kind: kind,
        title: title,
        outcome: outcome ?? this.outcome,
        detail: detail ?? this.detail,
        code: code ?? this.code,
        startedAt: startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        attempts: attempts ?? this.attempts,
        simulated: simulated,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'step_id': stepId,
        'kind': kind.wire,
        'title': title,
        'outcome': outcome.wire,
        if (detail != null) 'detail': detail,
        if (code != null) 'code': code,
        if (startedAt != null) 'started_at': startedAt!.toUtc().toIso8601String(),
        if (finishedAt != null) 'finished_at': finishedAt!.toUtc().toIso8601String(),
        'attempts': attempts,
        'simulated': simulated,
      };

  factory StepExecution.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return StepExecution(
      stepId: asString(map['step_id']),
      kind: StepKind.fromWire(map['kind']),
      title: asString(map['title']),
      outcome: StepOutcome.fromWire(map['outcome']),
      detail: asStringOrNull(map['detail']),
      code: asStringOrNull(map['code']),
      startedAt: asDateTime(map['started_at']),
      finishedAt: asDateTime(map['finished_at']),
      attempts: asInt(map['attempts'], fallback: 1),
      simulated: asBool(map['simulated']),
    );
  }
}

/// A full audit record for one execution of one workflow.
@immutable
class ExecutionRecord {
  const ExecutionRecord({
    required this.id,
    required this.workflowId,
    required this.workflowName,
    required this.idempotencyKey,
    required this.scheduledFor,
    required this.status,
    this.source = TriggerSource.schedule,
    this.startedAt,
    this.finishedAt,
    this.attempt = 1,
    this.maxAttempts = 1,
    this.dryRun = false,
    this.failureReason,
    this.failureCode,
    this.stepResults = const <StepExecution>[],
    this.resumeAt,
    this.resumeProgram = const <WorkflowStep>[],
    this.pendingStepId,
    this.createdAt,
  });

  final String id;
  final String workflowId;
  final String workflowName;

  /// Duplicate guard (spec §21): workflow + date + scheduled time + target.
  final String idempotencyKey;

  /// The wall-clock moment this run was scheduled for.
  final DateTime scheduledFor;

  final ExecutionStatus status;
  final TriggerSource source;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int attempt;
  final int maxAttempts;
  final bool dryRun;
  final String? failureReason;
  final String? failureCode;
  final List<StepExecution> stepResults;

  /// Set when the run is parked on a `WAIT` block that outlives the current
  /// process: the scheduler re-arms an alarm for this instant and resumes.
  final DateTime? resumeAt;

  /// The not-yet-run tail of the program, captured the moment the run parks on
  /// an approval or a deferred wait. Replaying this on resume is what stops an
  /// approved action from re-running the blocks before it.
  final List<WorkflowStep> resumeProgram;

  /// Step the run is currently parked on, if any.
  final String? pendingStepId;
  final DateTime? createdAt;

  bool get isTerminal => status.isTerminal;

  Duration? get duration {
    final DateTime? start = startedAt;
    final DateTime? end = finishedAt;
    if (start == null || end == null) return null;
    return end.difference(start);
  }

  /// Label used on the activity screen. Failed runs surface their reason.
  String get statusLabel => status.label;

  ExecutionRecord copyWith({
    ExecutionStatus? status,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? attempt,
    int? maxAttempts,
    String? failureReason,
    String? failureCode,
    List<StepExecution>? stepResults,
    DateTime? resumeAt,
    List<WorkflowStep>? resumeProgram,
    String? pendingStepId,
    bool clearPending = false,
    bool clearFailure = false,
  }) =>
      ExecutionRecord(
        id: id,
        workflowId: workflowId,
        workflowName: workflowName,
        idempotencyKey: idempotencyKey,
        scheduledFor: scheduledFor,
        status: status ?? this.status,
        source: source,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        attempt: attempt ?? this.attempt,
        maxAttempts: maxAttempts ?? this.maxAttempts,
        dryRun: dryRun,
        failureReason: clearFailure ? null : (failureReason ?? this.failureReason),
        failureCode: clearFailure ? null : (failureCode ?? this.failureCode),
        stepResults: stepResults ?? this.stepResults,
        resumeAt: resumeAt ?? this.resumeAt,
        resumeProgram: resumeProgram ?? this.resumeProgram,
        pendingStepId: clearPending ? null : (pendingStepId ?? this.pendingStepId),
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'workflow_id': workflowId,
        'workflow_name': workflowName,
        'idempotency_key': idempotencyKey,
        'scheduled_for': scheduledFor.toUtc().toIso8601String(),
        'status': status.wire,
        'source': source.wire,
        if (startedAt != null) 'started_at': startedAt!.toUtc().toIso8601String(),
        if (finishedAt != null) 'finished_at': finishedAt!.toUtc().toIso8601String(),
        'attempt': attempt,
        'max_attempts': maxAttempts,
        'dry_run': dryRun,
        if (failureReason != null) 'failure_reason': failureReason,
        if (failureCode != null) 'failure_code': failureCode,
        'steps': stepResults.map((StepExecution s) => s.toJson()).toList(),
        if (resumeAt != null) 'resume_at': resumeAt!.toUtc().toIso8601String(),
        if (resumeProgram.isNotEmpty)
          'resume_program': resumeProgram.map((WorkflowStep s) => s.toJson()).toList(),
        if (pendingStepId != null) 'pending_step_id': pendingStepId,
        if (createdAt != null) 'created_at': createdAt!.toUtc().toIso8601String(),
      };

  factory ExecutionRecord.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return ExecutionRecord(
      id: asString(map['id']),
      workflowId: asString(map['workflow_id']),
      workflowName: asString(map['workflow_name']),
      idempotencyKey: asString(map['idempotency_key']),
      scheduledFor: asDateTime(map['scheduled_for']) ?? DateTime.now(),
      status: ExecutionStatus.fromWire(map['status']),
      source: TriggerSource.fromWire(map['source']),
      startedAt: asDateTime(map['started_at']),
      finishedAt: asDateTime(map['finished_at']),
      attempt: asInt(map['attempt'], fallback: 1),
      maxAttempts: asInt(map['max_attempts'], fallback: 1),
      dryRun: asBool(map['dry_run']),
      failureReason: asStringOrNull(map['failure_reason']),
      failureCode: asStringOrNull(map['failure_code']),
      stepResults: asList(map['steps'])
          .map((Object? e) => StepExecution.fromJson(e))
          .toList(growable: false),
      resumeAt: asDateTime(map['resume_at']),
      resumeProgram: WorkflowStep.listFromJson(map['resume_program']),
      pendingStepId: asStringOrNull(map['pending_step_id']),
      createdAt: asDateTime(map['created_at']),
    );
  }
}
