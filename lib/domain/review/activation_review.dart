import '../models/step.dart';
import '../models/workflow.dart';

/// Plain-language summary shown before an automation is activated, so the
/// user confirms what will really happen (and what won't).
class ActivationReview {
  const ActivationReview({required this.where, required this.when, required this.actions, required this.notes});

  final String where;
  final String when;

  /// One line per block, in order. Real-world effects are called out.
  final List<String> actions;

  /// Honest caveats: personal WhatsApp hand-off, device reliability, etc.
  final List<String> notes;

  static ActivationReview of(Workflow w) {
    final List<String> actions = <String>[];
    final Set<String> notes = <String>{};
    void walk(List<WorkflowStep> steps, String indent) {
      for (final WorkflowStep s in steps) {
        switch (s) {
          case WhatsAppStep(:final WhatsAppMode mode, :final String recipient):
            if (mode == WhatsAppMode.send) {
              actions.add('${indent}Sends a real WhatsApp Business message to $recipient (official API)');
            } else if (mode == WhatsAppMode.prepare) {
              actions.add('${indent}Prepares a WhatsApp message to $recipient: you tap Send');
              notes.add('Personal WhatsApp messages are never sent automatically. You\'ll get a "message ready" notification and send it yourself.');
            } else {
              actions.add('${indent}Opens a WhatsApp chat with $recipient');
            }
          case GmailSendStep(:final String to):
            actions.add('${indent}Sends a real email from your Gmail to ${to.isEmpty ? '…' : to}');
          case TelegramSendStep(:final String chatId):
            actions.add('${indent}Sends a real Telegram message from your bot to ${chatId.isEmpty ? '…' : chatId}');
          case HttpStep() || WebhookStep():
            actions.add('${indent}Calls an external URL: ${s.describe()}');
          case ConditionStep(:final List<WorkflowStep> thenSteps):
            actions.add('$indent${s.describe()}, then:');
            walk(thenSteps, '$indent   ');
          default:
            actions.add('$indent${s.kind.label}: ${s.describe()}');
        }
      }
    }

    walk(w.steps, '');
    if (w.isCloud) {
      notes.add('Runs on Autometa Cloud, even when your phone is off. Failures appear in Activity and as alerts.');
    } else {
      notes.add('Runs on this phone. Android battery settings can delay or skip runs; see Settings → Background reliability.');
    }
    return ActivationReview(
      where: w.isCloud ? '☁️ Autometa Cloud' : '📱 This device',
      when: w.trigger.describe(),
      actions: actions,
      notes: notes.toList(),
    );
  }
}
