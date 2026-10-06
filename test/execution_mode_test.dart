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
      expect(i.single.label, 'Personal WhatsApp: prepare message (you tap Send)');
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

    test('AND/OR conditions map every rule with the match mode', () {
      final Workflow w = wf(const WebhookTrigger(token: 't'), <WorkflowStep>[
        const ConditionStep(
          id: 'c',
          condition: Condition(left: '{{payload.status}}', operator: ConditionOperator.equals, right: 'paid'),
          more: <Condition>[Condition(left: '{{payload.note}}', operator: ConditionOperator.notContains, right: 'test')],
          matchAny: true,
          thenSteps: <WorkflowStep>[notify],
        ),
      ]);
      final CloudMapping m = CloudMapper(phoneFor: (_) => null, webhookId: 'wh').map(w);
      expect(m.ok, isTrue, reason: m.issues.map((CapabilityIssue i) => i.reason).join());
      final Map<String, dynamic> c = (m.body['steps'] as List<dynamic>)[0] as Map<String, dynamic>;
      expect(c['mode'], 'any');
      expect((c['rules'] as List<dynamic>).length, 2);
      expect((c['rules'] as List<dynamic>)[1], containsPair('op', 'not_contains'));
    });

    test('Gmail trigger + send map to the gmail integration and need a Cloud connection', () {
      final Workflow w = wf(const GmailTrigger(query: 'subject:invoice'), <WorkflowStep>[
        const GmailSendStep(id: 'g', to: 'dad@example.com', subject: 'Hi', body: 'From {{email.from}}'),
      ]);
      final CloudMapping missing = CloudMapper(phoneFor: (_) => null).map(w);
      expect(missing.ok, isFalse);
      expect(missing.issues.single.label, 'Gmail');
      final CloudMapping m = CloudMapper(phoneFor: (_) => null, gmailConnectionId: 'c_g').map(w);
      expect(m.ok, isTrue);
      expect(m.body['trigger'], containsPair('connectionId', 'c_g'));
      expect((m.body['trigger'] as Map<String, dynamic>)['key'], 'new_email');
      expect((m.body['steps'] as List<dynamic>).single, containsPair('action', 'send_email'));
    });

    test('Telegram send is Cloud-only, needs a bot connection and maps to telegram.send_message', () {
      const TelegramSendStep step = TelegramSendStep(id: 't', chatId: '@family', text: 'Hi {{weekday}}', silent: true);
      final Workflow w = wf(const ScheduleTrigger(), <WorkflowStep>[step]);
      // Round-trips through JSON storage.
      final WorkflowStep back = WorkflowStep.fromJson(step.toJson());
      expect(back, isA<TelegramSendStep>());
      expect((back as TelegramSendStep).chatId, '@family');
      expect(back.silent, isTrue);
      // Blocked on-device, allowed in Cloud.
      expect(ExecutionCapabilities.check(w, ExecutionMode.onDevice), isNotEmpty);
      expect(ExecutionCapabilities.check(w, ExecutionMode.cloud), isEmpty);
      // No connection = honest blocking issue, never a fake success.
      final CloudMapping missing = CloudMapper(phoneFor: (_) => null).map(w);
      expect(missing.ok, isFalse);
      expect(missing.issues.single.label, 'Telegram');
      final CloudMapping m = CloudMapper(phoneFor: (_) => null, telegramConnectionId: 'c_t').map(w);
      expect(m.ok, isTrue, reason: m.issues.map((CapabilityIssue i) => i.reason).join());
      final Map<String, dynamic> s = (m.body['steps'] as List<dynamic>).single as Map<String, dynamic>;
      expect(s, containsPair('integration', 'telegram'));
      expect(s, containsPair('action', 'send_message'));
      expect(s, containsPair('connectionId', 'c_t'));
      expect(s['config'], containsPair('chatId', '@family'));
      expect(s['config'], containsPair('silent', 'yes'));
      // Incomplete block is a validation error.
      final Workflow bad = wf(const ScheduleTrigger(), <WorkflowStep>[const TelegramSendStep(id: 't')]);
      expect(const WorkflowValidator().validate(bad).issues.any((ValidationIssue i) => i.code == 'telegram.incomplete'), isTrue);
    });
  });

  group('canonical {{weekday}} variable', () {
    test('builder {{weekday}} and legacy {{day}} both reach Cloud as "weekday"', () {
      for (final String left in <String>['{{weekday}}', '{{day}}', '{{ day }}']) {
        final Workflow w = wf(const ScheduleTrigger(), <WorkflowStep>[
          ConditionStep(id: 'c', condition: Condition(left: left, operator: ConditionOperator.equals, right: 'Sunday'), thenSteps: const <WorkflowStep>[
            NotificationStep(id: 'n', title: 'Summary', body: 'Happy {{day}}, it is {{weekday}}'),
          ]),
        ]);
        // Saved → reloaded keeps the user's text untouched.
        final Workflow saved = Workflow.fromJson(w.toJson());
        final CloudMapping m = CloudMapper(phoneFor: (_) => null).map(saved);
        expect(m.ok, isTrue, reason: m.issues.map((CapabilityIssue i) => i.reason).join());
        final List<dynamic> steps = m.body['steps'] as List<dynamic>;
        expect(((steps[0] as Map<String, dynamic>)['rules'] as List<dynamic>).single, containsPair('field', 'weekday'));
        expect(((steps[1] as Map<String, dynamic>)['config'] as Map<String, dynamic>)['body'], 'Happy {{weekday}}, it is {{weekday}}');
      }
    });
  });

  test('device-only variables are reported before saving to Cloud (never silently empty)', () {
    final Workflow w = wf(const ScheduleTrigger(), <WorkflowStep>[
      const NotificationStep(id: 'n', title: 'Hi', body: '{{greeting}} Dad, it is {{weekday}} {{time}}'),
      const ConditionStep(id: 'c', condition: Condition(left: '{{day_short}}', operator: ConditionOperator.equals, right: 'Sun'), thenSteps: <WorkflowStep>[notify]),
    ]);
    final CloudMapping m = CloudMapper(phoneFor: (_) => null).map(w);
    final List<CapabilityIssue> v = m.issues.where((CapabilityIssue i) => i.label == 'Variables').toList();
    expect(v.length, 2);
    expect(v[0].reason, contains('{{greeting}}'));
    expect(v[0].reason, startsWith('{{greeting}} only'), reason: '{{weekday}} / {{time}} are Cloud variables, not flagged');
    expect(v[1].reason, contains('{{day_short}}'));
  });

  group('V1 conditions + Gmail (domain)', () {
    test('multi-rule condition round-trips; legacy single rule still parses', () {
      const ConditionStep c = ConditionStep(
        id: 'c',
        condition: Condition(left: '{{day}}', operator: ConditionOperator.equals, right: 'Sunday'),
        more: <Condition>[Condition(left: '{{time}}', operator: ConditionOperator.contains, right: '18')],
        thenSteps: <WorkflowStep>[notify],
      );
      final ConditionStep back = WorkflowStep.fromJson(c.toJson()) as ConditionStep;
      expect(back.conditions.length, 2);
      expect(back.matchAny, isFalse);
      expect(back.describe(), contains(' AND '));
      final ConditionStep legacy = WorkflowStep.fromJson(<String, dynamic>{
        'id': 'l', 'type': 'condition', 'if': <String, dynamic>{'left': '{{day}}', 'operator': '==', 'right': 'Monday'}, 'then': <dynamic>[],
      }) as ConditionStep;
      expect(legacy.conditions.length, 1);
    });

    test('empty condition blocks activation', () {
      final Workflow w = wf(const ManualTrigger(), <WorkflowStep>[
        const ConditionStep(id: 'c', condition: Condition(left: '', operator: ConditionOperator.equals), thenSteps: <WorkflowStep>[notify]),
      ], mode: ExecutionMode.onDevice);
      expect(const WorkflowValidator().validate(w).issues.any((ValidationIssue i) => i.code == 'condition.incomplete'), isTrue);
    });

    test('Gmail is Cloud-only and never offered as an on-device block', () {
      final Workflow w = wf(const GmailTrigger(), <WorkflowStep>[const GmailSendStep(id: 'g', to: 'a@b.co', subject: 's', body: 'b')]);
      expect(ExecutionCapabilities.check(w, ExecutionMode.cloud), isEmpty);
      expect(ExecutionCapabilities.check(w, ExecutionMode.onDevice).length, 2);
      final GmailTrigger t = WorkflowTrigger.fromJson(const GmailTrigger(query: 'from:x').toJson()) as GmailTrigger;
      expect(t.query, 'from:x');
    });
  });
}
