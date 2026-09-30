import 'package:autometa/domain/engine/engine_ports.dart';
import 'package:autometa/domain/engine/step_context.dart';
import 'package:autometa/domain/engine/step_executor.dart';
import 'package:autometa/domain/engine/step_result.dart';
import 'package:autometa/domain/models/execution.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';

class FakeState implements EngineStateProvider {
  FakeState({this.isPaused = false});

  @override
  bool isPaused;

  @override
  String get defaultRecipientName => 'Dad';

  @override
  Map<String, String> get runtimeVariables => const <String, String>{};

  @override
  bool get notificationsPermitted => true;
}

class MemoryIdempotency implements IdempotencyStore {
  final Map<String, String> claims = <String, String>{};

  @override
  Future<bool> claim(String key, {required String executionId}) async {
    if (claims.containsKey(key)) return false;
    claims[key] = executionId;
    return true;
  }

  @override
  Future<bool> isClaimed(String key) async => claims.containsKey(key);

  @override
  Future<void> release(String key) async => claims.remove(key);
}

class RecordingSink implements EngineSink {
  final List<ExecutionRecord> updates = <ExecutionRecord>[];
  final List<dynamic> approvals = <dynamic>[];

  @override
  Future<void> onExecutionStart(ExecutionRecord record) async => updates.add(record);

  @override
  Future<void> onExecutionUpdate(ExecutionRecord record) async => updates.add(record);

  @override
  Future<void> onApprovalRequested(dynamic ticket) async => approvals.add(ticket);
}

/// Scriptable executor: returns queued results in order, then the default.
class ScriptedExecutor extends StepExecutor {
  ScriptedExecutor(this.kind, {List<StepResult>? script, this.fallback = const StepResult.done(detail: 'ok')})
      : script = script ?? <StepResult>[];

  @override
  final StepKind kind;
  final List<StepResult> script;
  final StepResult fallback;
  final List<String> resolvedMessages = <String>[];
  int calls = 0;

  @override
  Future<bool> get isAvailable async => true;

  @override
  String get availabilityHint => 'test';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    calls++;
    if (step is NotificationStep) resolvedMessages.add(context.resolve(step.body));
    if (step is WhatsAppStep) resolvedMessages.add(context.resolve(step.message));
    if (context.dryRun) return const StepResult.simulated(detail: 'sim');
    return script.isNotEmpty ? script.removeAt(0) : fallback;
  }
}

Workflow dadWorkflow({String id = 'wf-morning', String time = '07:00', String message = 'Good morning Dad', int retries = 2}) =>
    Workflow(
      id: id,
      name: 'Morning Dad',
      timeZone: 'Africa/Lagos',
      maxRetries: retries,
      trigger: ScheduleTrigger(timeOfDay: time),
      steps: <WorkflowStep>[
        WhatsAppStep(id: '$id-s1', recipient: 'Dad', message: message),
      ],
    );

const EngineTime instantTime = EngineTime(sleep: _noSleep);
Future<void> _noSleep(Duration _) async {}
