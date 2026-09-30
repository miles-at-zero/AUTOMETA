import 'package:autometa/domain/engine/engine_ports.dart';
import 'package:autometa/domain/engine/step_executor.dart';
import 'package:autometa/domain/engine/step_result.dart';
import 'package:autometa/domain/engine/workflow_engine.dart';
import 'package:autometa/domain/models/condition.dart';
import 'package:autometa/domain/models/execution.dart';
import 'package:autometa/domain/models/execution_status.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/schedule/schedule_calculator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  setUpAll(ScheduleCalculator.ensureTimeZonesLoaded);

  late ScriptedExecutor whatsapp;
  late ScriptedExecutor notify;
  late MemoryIdempotency idem;
  late FakeState state;
  late RecordingSink sink;
  late WorkflowEngine engine;
  int ids = 0;

  setUp(() {
    whatsapp = ScriptedExecutor(StepKind.whatsapp);
    notify = ScriptedExecutor(StepKind.notification);
    idem = MemoryIdempotency();
    state = FakeState();
    sink = RecordingSink();
    engine = WorkflowEngine(
      registry: StepExecutorRegistry(<StepExecutor>[whatsapp, notify]),
      idempotency: idem,
      state: state,
      sink: sink,
      time: instantTime,
      idGenerator: () => 'id-${ids++}',
    );
  });

  final DateTime slot = DateTime.utc(2026, 10, 1, 6); // 07:00 Lagos

  test('scheduled run succeeds and records every step', () async {
    final ExecutionRecord r = await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    expect(r.status, ExecutionStatus.success);
    expect(r.stepResults, hasLength(1));
    expect(whatsapp.resolvedMessages.single, 'Good morning Dad');
  });

  test('duplicate protection: second trigger for the same slot is SKIPPED', () async {
    final ExecutionRecord first = await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    final ExecutionRecord second = await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    expect(first.status, ExecutionStatus.success);
    expect(second.status, ExecutionStatus.skipped);
    expect(second.failureCode, 'engine.duplicate');
    expect(whatsapp.calls, 1, reason: 'the message must not be delivered twice');
  });

  test('manual runs never collide with each other or with the schedule', () async {
    await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    final ExecutionRecord m1 = await engine.execute(dadWorkflow(), source: TriggerSource.manual);
    final ExecutionRecord m2 = await engine.execute(dadWorkflow(), source: TriggerSource.manual);
    expect(<ExecutionStatus>[m1.status, m2.status], everyElement(ExecutionStatus.success));
  });

  test('pause: scheduled runs are skipped, nothing executes', () async {
    state.isPaused = true;
    final ExecutionRecord r = await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    expect(r.status, ExecutionStatus.skipped);
    expect(r.failureCode, 'engine.paused');
    expect(whatsapp.calls, 0);
    state.isPaused = false;
    final ExecutionRecord resumed = await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    expect(resumed.status, ExecutionStatus.success, reason: 'a paused slot was never claimed');
  });

  test('retries: retriable failure is retried up to maxRetries then FAILED', () async {
    whatsapp.script.addAll(List<StepResult>.filled(5, const StepResult.failed(reason: 'offline', retriable: true)));
    final ExecutionRecord r = await engine.execute(dadWorkflow(retries: 2), source: TriggerSource.schedule, scheduledFor: slot);
    expect(r.status, ExecutionStatus.failed);
    expect(whatsapp.calls, 3);
    expect(r.stepResults.single.attempts, 3);
  });

  test('retries: recovers on second attempt', () async {
    whatsapp.script.add(const StepResult.failed(reason: 'blip', retriable: true));
    final ExecutionRecord r = await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    expect(r.status, ExecutionStatus.success);
    expect(whatsapp.calls, 2);
  });

  test('retries: non-retriable failure stops immediately', () async {
    whatsapp.script.add(const StepResult.failed(reason: 'bad token'));
    final ExecutionRecord r = await engine.execute(dadWorkflow(retries: 5), source: TriggerSource.schedule, scheduledFor: slot);
    expect(r.status, ExecutionStatus.failed);
    expect(whatsapp.calls, 1);
  });

  test('dry run performs nothing real and is marked simulated', () async {
    final DryRunReport report = await engine.dryRun(dadWorkflow());
    expect(report.record.dryRun, isTrue);
    expect(report.record.stepResults.single.outcome, StepOutcome.simulated);
    expect(idem.claims, isEmpty, reason: 'dry runs must not consume the schedule slot');
  });

  test('conditions pick the right branch', () async {
    Workflow wf(String day) => Workflow(
          id: 'wf-cond-$day',
          name: 'Cond',
          trigger: const ManualTrigger(),
          variables: <String, String>{'today': day},
          steps: <WorkflowStep>[
            ConditionStep(
              id: 'c',
              condition: const Condition(left: '{{today}}', operator: ConditionOperator.equals, right: 'Sunday'),
              thenSteps: const <WorkflowStep>[NotificationStep(id: 'a', body: 'Sunday message')],
              elseSteps: const <WorkflowStep>[NotificationStep(id: 'b', body: 'normal message')],
            ),
          ],
        );
    await engine.execute(wf('Sunday'));
    await engine.execute(wf('Monday'));
    expect(notify.resolvedMessages, <String>['Sunday message', 'normal message']);
  });

  test('variables flow from set_variable into later blocks', () async {
    final Workflow wf = Workflow(
      id: 'wf-var',
      name: 'Vars',
      trigger: const ManualTrigger(),
      steps: const <WorkflowStep>[
        SetVariableStep(id: 'v', name: 'who', value: '{{name}}'),
        NotificationStep(id: 'n', body: 'Hi {{who}}, happy {{day}}'),
      ],
    );
    await engine.execute(wf);
    expect(notify.resolvedMessages.single, startsWith('Hi Dad, happy '));
  });

  test('approval parks the run and resume only replays the tail', () async {
    whatsapp.script.add(const StepResult(outcome: StepOutcome.awaitingApproval, detail: 'wait'));
    final Workflow wf = Workflow(
      id: 'wf-appr',
      name: 'Appr',
      trigger: const ManualTrigger(),
      steps: const <WorkflowStep>[
        NotificationStep(id: 'n1', body: 'before'),
        WhatsAppStep(id: 'w', message: 'hello'),
        NotificationStep(id: 'n2', body: 'after'),
      ],
    );
    final ExecutionRecord parked = await engine.execute(wf);
    expect(parked.status, ExecutionStatus.waitingApproval);
    expect(sink.approvals, hasLength(1));
    expect(parked.resumeProgram.map((WorkflowStep s) => s.id), <String>['w', 'n2']);

    final ExecutionRecord done = await engine.resumeAfterApproval(workflow: wf, record: parked, approved: true);
    expect(done.status, ExecutionStatus.success);
    expect(notify.resolvedMessages, <String>['before', 'after'], reason: 'n1 must not run twice');
  });

  test('rejecting an approval cancels the run', () async {
    whatsapp.script.add(const StepResult(outcome: StepOutcome.awaitingApproval));
    final ExecutionRecord parked = await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    final ExecutionRecord r = await engine.resumeAfterApproval(workflow: dadWorkflow(), record: parked, approved: false);
    expect(r.status, ExecutionStatus.cancelled);
  });

  test('long waits are deferred to the scheduler, not slept', () async {
    final Workflow wf = Workflow(
      id: 'wf-wait',
      name: 'Wait',
      trigger: const ManualTrigger(),
      steps: const <WorkflowStep>[
        NotificationStep(id: 'a', body: 'one'),
        DelayStep(id: 'd', seconds: 1800),
        NotificationStep(id: 'b', body: 'two'),
      ],
    );
    final ExecutionRecord r = await engine.execute(wf);
    expect(r.status, ExecutionStatus.pending);
    expect(r.resumeAt, isNotNull);
    expect(r.resumeProgram.single.id, 'b');
    expect(notify.resolvedMessages, <String>['one']);
  });

  test('invalid workflow is refused with a readable reason', () async {
    final Workflow wf = Workflow(id: 'bad', name: '', trigger: const ManualTrigger(), steps: const <WorkflowStep>[]);
    final ExecutionRecord r = await engine.execute(wf);
    expect(r.status, ExecutionStatus.failed);
    expect(r.failureCode, 'workflow.invalid');
  });

  test('missing integration fails honestly instead of claiming success', () async {
    final Workflow wf = Workflow(
      id: 'wf-http',
      name: 'Http',
      trigger: const ManualTrigger(),
      steps: const <WorkflowStep>[HttpStep(id: 'h', url: 'https://example.com')],
    );
    final ExecutionRecord r = await engine.execute(wf);
    expect(r.status, ExecutionStatus.failed);
    expect(r.failureReason, contains('not available'));
  });
}
