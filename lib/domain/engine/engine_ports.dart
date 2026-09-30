import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../models/execution.dart';
import '../models/execution_status.dart';
import '../models/step.dart';
import '../models/workflow.dart';
import '../validation/workflow_validator.dart';

/// The engine's view of app-wide state. Implemented by the settings layer.
abstract class EngineStateProvider {
  /// Spec §25: "Pause all automations".
  bool get isPaused;

  /// Alias used when a workflow says "Dad" and no override is set.
  String get defaultRecipientName;

  /// Extra `{{variables}}` injected into every run (device name, city…).
  Map<String, String> get runtimeVariables;

  /// Whether the user granted the Android notification permission.
  bool get notificationsPermitted;
}

/// Duplicate guard port. The durable implementation is backed by a unique
/// index on `executions.idempotency_key`; tests use an in-memory one.
abstract class IdempotencyStore {
  /// Atomically claims [key]. Returns `false` when it was already claimed.
  Future<bool> claim(String key, {required String executionId});

  Future<bool> isClaimed(String key);

  /// Releases a claim, used when a run is cancelled before it did anything.
  Future<void> release(String key);
}

/// Persistence / side-channel port for engine output.
abstract class EngineSink {
  Future<void> onExecutionStart(ExecutionRecord record);
  Future<void> onExecutionUpdate(ExecutionRecord record);
  Future<void> onApprovalRequested(dynamic ticket);
}

/// How the engine should treat a `WAIT` block.
enum DelayHandling {
  /// Sleep in this isolate. Only safe for short waits while the app is alive.
  inProcess,

  /// Hand the wait back to the scheduler, which re-arms an alarm.
  reschedule,
}

@immutable
class DelayRequest {
  const DelayRequest({
    required this.executionId,
    required this.workflowId,
    required this.duration,
    required this.remainingSteps,
    required this.isBackground,
  });

  final String executionId;
  final String workflowId;
  final Duration duration;
  final int remainingSteps;

  /// True when the run was started by AlarmManager rather than the UI.
  final bool isBackground;
}

@immutable
class DelayDecision {
  const DelayDecision(this.handling);

  final DelayHandling handling;

  static const DelayDecision sleep = DelayDecision(DelayHandling.inProcess);
  static const DelayDecision defer = DelayDecision(DelayHandling.reschedule);
}

typedef DelayHandler = Future<DelayDecision> Function(DelayRequest request);

/// Injectable clock/sleep so retry backoff and waits are testable.
class EngineTime {
  const EngineTime({DateTime Function()? clock, Future<void> Function(Duration)? sleep})
      : _clock = clock,
        _sleep = sleep;

  final DateTime Function()? _clock;
  final Future<void> Function(Duration)? _sleep;

  DateTime now() => _clock == null ? DateTime.now() : _clock!();
  Future<void> sleep(Duration duration) =>
      _sleep == null ? Future<void>.delayed(duration) : _sleep!(duration);
}

/// Outcome of walking a step list.
@immutable
class FlowOutcome {
  const FlowOutcome({
    this.status = ExecutionStatus.success,
    this.reason,
    this.code,
    this.resumeAt,
    this.pendingApprovalId,
    this.pendingStepId,
    this.pendingProgram = const <WorkflowStep>[],
    this.stepsExecuted = 0,
  });

  final ExecutionStatus status;
  final String? reason;
  final String? code;
  final DateTime? resumeAt;

  /// Ticket id of the approval the run is parked on.
  final String? pendingApprovalId;

  /// Id of the block that is parked.
  final String? pendingStepId;

  /// The blocks that still need to run, in order, starting with the parked one.
  final List<WorkflowStep> pendingProgram;
  final int stepsExecuted;
}

/// The result of a dry run, shaped for the preview sheet in spec §24.
@immutable
class DryRunReport {
  const DryRunReport({
    required this.workflow,
    required this.record,
    required this.validation,
    required this.wouldRunAt,
  });

  final Workflow workflow;
  final ExecutionRecord record;
  final ValidationResult validation;

  /// When the schedule would next fire, or null for manual/webhook triggers.
  final DateTime? wouldRunAt;

  bool get canRun => validation.isValid && record.stepResults.isNotEmpty;

  List<String> get summaryLines => record.stepResults
      .map(
        (StepExecution s) => '${s.kind.label}: ${s.title}'
            '${s.detail == null || s.detail!.isEmpty ? '' : ' — ${s.detail}'}',
      )
      .toList(growable: false);
}
