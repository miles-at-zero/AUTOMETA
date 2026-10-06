import 'package:autometa/domain/models/condition.dart';
import 'package:autometa/domain/models/execution_mode.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/review/activation_review.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('personal WhatsApp review says you tap Send; device caveat shown', () {
    const Workflow w = Workflow(
      id: 'w', name: 'Morning Dad', timeZone: 'Africa/Lagos', executionMode: ExecutionMode.onDevice,
      trigger: ScheduleTrigger(timeOfDay: '07:00'),
      steps: <WorkflowStep>[WhatsAppStep(id: 's', recipient: 'Dad', message: 'Good morning Dad')],
    );
    final ActivationReview r = ActivationReview.of(w);
    expect(r.where, contains('This device'));
    expect(r.actions.single, contains('you tap Send'));
    expect(r.notes.join(), contains('never sent automatically'));
    expect(r.notes.join(), contains('battery'));
  });

  test('Cloud review calls out real sends, including inside conditions', () {
    const Workflow w = Workflow(
      id: 'w', name: 'Sunday', timeZone: 'Africa/Lagos', executionMode: ExecutionMode.cloud,
      trigger: ScheduleTrigger(timeOfDay: '18:00'),
      steps: <WorkflowStep>[
        ConditionStep(id: 'c', condition: Condition(left: '{{weekday}}', operator: ConditionOperator.equals, right: 'Sunday'), thenSteps: <WorkflowStep>[
          WhatsAppStep(id: 'b', mode: WhatsAppMode.send, account: 'business', recipient: 'Dad', message: 'Hi'),
          GmailSendStep(id: 'g', to: 'dad@example.com', subject: 'Hi', body: 'b'),
        ]),
      ],
    );
    final ActivationReview r = ActivationReview.of(w);
    expect(r.where, contains('Cloud'));
    expect(r.actions[0], startsWith('IF'));
    expect(r.actions[1], contains('real WhatsApp Business message to Dad'));
    expect(r.actions[2], contains('real email'));
    expect(r.notes.join(), contains('phone is off'));
  });
}
