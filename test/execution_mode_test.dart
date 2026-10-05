import 'package:autometa/cloud/cloud_mapper.dart';
import 'package:autometa/domain/capabilities/execution_capabilities.dart';
import 'package:autometa/domain/models/condition.dart';
import 'package:autometa/domain/models/execution_mode.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/validation/workflow_validator.dart';
import 'package:flutter_test/flutter_test.dart';

Workflow wf(WorkflowTrigger trigger, List<WorkflowStep> steps, {ExecutionMode mode = ExecutionMode.cloud}) =>
    Workflow(id: 'w', name: 'Morning', trigger: trigger, steps: steps, timeZone: 'Africa/Lagos', executionMode: mode);

const NotificationStep notify = NotificationStep(id: 'n', title: 'Hi', body: 'Good morning');
const WhatsAppStep prepare = WhatsAppStep(id: 'p', recipient: 'Dad', message: 'Hi Dad');
const WhatsAppStep bizSend = WhatsAppStep(id: 'b', mode: WhatsAppMode.send, account: 'business', recipient: 'Dad', message: 'Hi Dad');
const WhatsAppStep personalSend = WhatsAppStep(id: 'x', mode: WhatsAppMode.send, account: 'personal', recipient: 'Dad', message: 'Hi');

void main() {
  group('data model', () {
    test('legacy definitions without execution_mode stay On-device', () {
      final Workflow w = Workflow.fromJson(<String, dynamic>{
        'id': 'old', 'name': 'Old', 'trigger': <String, dynamic>{'type': 'schedule', 'time_of_day': '07:00'}, 'steps': <dynamic>[],
      });
      expect(w.executionMode, ExecutionMode.onDevice);
    });

    test('mode and cloud id round-trip', () {
      final Workflow w = wf(const ScheduleTrigger(), <WorkflowStep>[notify]).copyWith(cloudId: 'a_1');
      final Workflow back = Workflow.fromJson(w.toJson());
      expect(back.executionMode, ExecutionMode.cloud);
      expect(back.cloudId, 'a_1');
    });

    test('Cloud automations never run locally', () {
      final Workflow w = wf(const ScheduleTrigger(), <WorkflowStep>[notify]).copyWith(enabled: true);
      expect(w.runsLocally, isFalse);
      expect(w.copyWith(executionMode: ExecutionMode.onDevice).runsLocally, isTrue);
    });

    test('Cloud is the recommended default', () => expect(ExecutionMode.recommended, ExecutionMode.cloud));
  });

  group('capabilities', () {
    test('schedule + notification runs in both modes', () {
      final Workflow w = wf(const ScheduleTrigger(), <WorkflowStep>[notify]);
      expect(ExecutionCapabilities.check(w, ExecutionMode.cloud), isEmpty);
      expect(ExecutionCapabilities.check(w, ExecutionMode.onDevice), isEmpty);
    });

    test('Prepare WhatsApp is On-device only and names the step', () {
      final List<CapabilityIssue> i = ExecutionCapabilities.check(wf(const ScheduleTrigger(), <WorkflowStep>[prepare]), ExecutionMode.cloud);
      expect(i.single.stepId, 'p');
      expect(i.single.label, 'Prepare WhatsApp message');
    });

    test('silent send from personal WhatsApp is unsupported everywhere', () {
      for (final ExecutionMode m in ExecutionMode.values) {
        expect(ExecutionCapabilities.check(wf(const ScheduleTrigger(), <WorkflowStep>[personalSend], mode: m), m), isNotEmpty);
        expect(const WorkflowValidator().validate(wf(const ScheduleTrigger(), <WorkflowStep>[personalSend], mode: m)).isValid, isFalse);
      }
    });

    test('Business API send works in both modes', () {
      final Workflow w = wf(const ScheduleTrigger(), <WorkflowStep>[bizSend]);
      expect(ExecutionCapabilities.check(w, ExecutionMode.cloud), isEmpty);
      expect(ExecutionCapabilities.check(w, ExecutionMode.onDevice), isEmpty);
    });

    test('webhook trigger is Cloud only; phone events are device only', () {
      expect(ExecutionCapabilities.check(wf(const WebhookTrigger(token: 't'), <WorkflowStep>[notify]), ExecutionMode.onDevice), isNotEmpty);
      expect(ExecutionCapabilities.check(wf(const AppEventTrigger(event: 'charging'), <WorkflowStep>[notify]), ExecutionMode.cloud), isNotEmpty);
    });

    test('validator blocks activating in a mode that cannot run a block', () {
      final ValidationResult r = const WorkflowValidator().validate(wf(const ScheduleTrigger(), <WorkflowStep>[prepare]));
      expect(r.isValid, isFalse);
      expect(r.errors.single.code, 'capability.cloud');
    });

    test('Cloud conditions must be last, without ELSE, on a variable', () {
      const ConditionStep good = ConditionStep(
        id: 'c',
        condition: Condition(left: '{{payload.priority}}', operator: ConditionOperator.equals, right: 'high'),
        thenSteps: <WorkflowStep>[notify],
      );
      expect(ExecutionCapabilities.check(wf(const ManualTrigger(), <WorkflowStep>[good]), ExecutionMode.cloud), isEmpty);
      expect(ExecutionCapabilities.check(wf(const ManualTrigger(), <WorkflowStep>[good, notify]), ExecutionMode.cloud), isNotEmpty);
    });

    test('bestModeFor keeps Cloud when possible, falls back for device-only templates', () {
      expect(ExecutionCapabilities.bestModeFor(wf(const ScheduleTrigger(), <WorkflowStep>[notify]), ExecutionMode.cloud), ExecutionMode.cloud);
      expect(ExecutionCapabilities.bestModeFor(wf(const ScheduleTrigger(), <WorkflowStep>[prepare]), ExecutionMode.cloud), ExecutionMode.onDevice);
    });
  });

  group('cloud mapper', () {
    CloudMapper mapper({String? wa = 'c_wa'}) => CloudMapper(phoneFor: (String a) => a == 'Dad' ? '2348012345678' : null, whatsappConnectionId: wa);

    test('weekday schedule → server days (0 = Sunday)', () {
      final CloudMapping m = mapper().map(wf(const ScheduleTrigger(timeOfDay: '07:00', repeat: ScheduleRepeat.days, weekdays: <int>{1, 7}), <WorkflowStep>[notify]));
      expect(m.ok, isTrue);
      expect(m.body['trigger'], <String, dynamic>{
        'integration': 'autometa', 'key': 'schedule',
        'schedule': <String, dynamic>{'times': <String>['07:00'], 'days': <int>[0, 1]},
      });
      expect(m.body['timezone'], 'Africa/Lagos');
      expect((m.body['steps'] as List<dynamic>).single, containsPair('action', 'notify'));
    });

    test('Business send → whatsapp.send_text with resolved number and connection', () {
      final CloudMapping m = mapper().map(wf(const ScheduleTrigger(), <WorkflowStep>[bizSend]));
      final Map<String, dynamic> s = (m.body['steps'] as List<dynamic>).single as Map<String, dynamic>;
      expect(s['action'], 'send_text');
      expect(s['connectionId'], 'c_wa');
      expect(s['config'], <String, dynamic>{'to': '2348012345678', 'text': 'Hi Dad'});
    });

    test('missing Cloud WhatsApp connection is a blocking issue, not a silent change', () {
      expect(mapper(wa: null).map(wf(const ScheduleTrigger(), <WorkflowStep>[bizSend])).ok, isFalse);
    });

    test('device-only block makes the mapping fail', () {
      expect(mapper().map(wf(const ScheduleTrigger(), <WorkflowStep>[prepare])).ok, isFalse);
    });

    test('condition + then steps flatten in order', () {
      const ConditionStep c = ConditionStep(
        id: 'c',
        condition: Condition(left: '{{payload.status}}', operator: ConditionOperator.isNotEmpty),
        thenSteps: <WorkflowStep>[notify],
      );
      final List<dynamic> steps = mapper().map(wf(const ManualTrigger(), <WorkflowStep>[c])).body['steps'] as List<dynamic>;
      expect((steps[0] as Map<String, dynamic>)['type'], 'condition');
      expect(((steps[0] as Map<String, dynamic>)['rules'] as List<dynamic>).single, containsPair('op', 'exists'));
      expect((steps[1] as Map<String, dynamic>)['action'], 'notify');
    });
  });
}
