import 'dart:convert';

import 'package:autometa/domain/models/condition.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/validation/workflow_validator.dart';
import 'package:autometa/services/templates/template_gallery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('spec §36 JSON shape parses', () {
    final Workflow w = Workflow.fromJson(jsonDecode('''
      {"id":"x","name":"Morning Dad",
       "trigger":{"type":"schedule","time":"07:00","repeat":"daily"},
       "steps":[{"id":"s","type":"whatsapp","mode":"prepare","recipient":"Dad","message":"Good morning Dad"}]}'''));
    expect(w.name, 'Morning Dad');
    expect((w.steps.single as WhatsAppStep).mode, WhatsAppMode.prepare);
    expect(const WorkflowValidator().validate(w).isValid, isTrue);
  });

  test('every block type survives a JSON round-trip, including nested branches', () {
    final Workflow w = Workflow(
      id: 'all',
      name: 'All blocks',
      trigger: const ScheduleTrigger(timeOfDay: '18:00', repeat: ScheduleRepeat.days, weekdays: <int>{1, 3, 5}),
      steps: const <WorkflowStep>[
        AiStep(id: 'a', prompt: 'p'),
        HttpStep(id: 'h', url: 'https://example.com', method: 'POST', headers: <String, String>{'X': '1'}),
        WebhookStep(id: 'wh', url: 'https://hooks.example.com'),
        ClipboardStep(id: 'c', text: 't'),
        OpenUrlStep(id: 'o', url: 'https://example.com'),
        DelayStep(id: 'd', seconds: 60),
        SetVariableStep(id: 'v', name: 'n', value: '1'),
        ConditionStep(
          id: 'if',
          condition: Condition(left: '{{n}}', operator: ConditionOperator.greaterThan, right: '0'),
          thenSteps: <WorkflowStep>[NotificationStep(id: 'n1', body: 'yes')],
          elseSteps: <WorkflowStep>[WhatsAppStep(id: 'w1', message: 'no')],
        ),
      ],
    );
    final Workflow back = Workflow.fromJson(jsonDecode(jsonEncode(w.toJson())));
    expect(back.steps.map((WorkflowStep s) => s.kind), w.steps.map((WorkflowStep s) => s.kind));
    final ConditionStep c = back.steps.last as ConditionStep;
    expect(c.condition.operator, ConditionOperator.greaterThan);
    expect((c.elseSteps.single as WhatsAppStep).message, 'no');
    expect((back.trigger as ScheduleTrigger).effectiveWeekdays, <int>{1, 3, 5});
  });

  test('delays are capped to prevent runaway workflows', () {
    final DelayStep d = DelayStep.fromJson(<String, dynamic>{'id': 'd', 'seconds': 999999999});
    expect(d.effectiveSeconds, lessThanOrEqualTo(12 * 3600));
  });

  test('validator catches broken definitions', () {
    final ValidationResult r = const WorkflowValidator().validate(const Workflow(
      id: 'b',
      name: '',
      trigger: ScheduleTrigger(timeOfDay: '7am'),
      steps: <WorkflowStep>[WhatsAppStep(id: 'w', recipient: '', message: '')],
    ));
    expect(r.isValid, isFalse);
    expect(r.errors.length, greaterThanOrEqualTo(3));
  });

  test('acceptance: all three Dad workflows come from templates, no code changes', () {
    for (final (String id, String time, String msg) in <(String, String, String)>[
      ('morning_dad', '07:00', 'Good morning Dad'),
      ('evening_dad', '20:00', 'Good evening Dad'),
      ('night_dad', '22:00', 'Good night Dad'),
    ]) {
      final Workflow w = TemplateGallery.byId(id)!.instantiate(timeZone: 'Africa/Lagos');
      expect((w.trigger as ScheduleTrigger).timeOfDay, time);
      expect((w.steps.single as WhatsAppStep).message, msg);
      expect(w.enabled, isFalse, reason: 'templates are activated only by the user');
      expect(const WorkflowValidator().validate(w).isValid, isTrue);
    }
  });

  test('templates honour a custom recipient', () {
    final Workflow w = TemplateGallery.byId('morning_dad')!.instantiate(recipient: 'Mum');
    final WhatsAppStep s = w.steps.single as WhatsAppStep;
    expect(s.recipient, 'Mum');
    expect(s.message, 'Good morning Mum');
  });

  test('every gallery template is valid', () {
    for (final AutomationTemplate t in TemplateGallery.all) {
      expect(const WorkflowValidator().validate(t.instantiate()).errors, isEmpty, reason: t.id);
    }
  });
}
