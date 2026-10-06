import '../../domain/capabilities/execution_capabilities.dart';
import '../../domain/models/execution_mode.dart';
import '../../domain/models/step.dart';
import '../../domain/models/trigger.dart';
import '../../domain/models/workflow.dart';
import 'template_gallery.dart';

/// The original "Dad reminders" use case, now one optional template set:
/// Morning 07:00, Evening 20:00 and Night 22:00 (all editable).
class DadReminders {
  const DadReminders._();

  static const List<String> templateIds = <String>['morning_dad', 'evening_dad', 'night_dad'];

  /// Default time of each reminder, read from its template.
  static String defaultTime(String templateId) {
    final Object? t = TemplateGallery.byId(templateId)!.definition['trigger'];
    return t is Map ? '${t['time']}' : '07:00';
  }

  /// Builds INACTIVE drafts for the chosen reminders. The user reviews and
  /// activates them through the normal activation review.
  ///
  /// * [business] false = Personal WhatsApp, PREPARE only: Autometa prepares
  ///   the message and opens WhatsApp, and the user taps Send. Never sent
  ///   automatically, and never converted to WhatsApp Business.
  /// * [business] true = WhatsApp Business (official Cloud API) send, which
  ///   needs a WhatsApp Business connection before it can be activated.
  ///
  /// Execution mode follows the normal rules: the user's default (Cloud) when
  /// every block supports it; Personal prepare stays on this device.
  static List<Workflow> buildDrafts({
    required Map<String, String> times,
    required String recipient,
    required bool business,
    required String timeZone,
    required ExecutionMode defaultMode,
    String Function()? idGenerator,
  }) {
    final String name = recipient.trim().isEmpty ? 'Dad' : recipient.trim();
    final List<Workflow> out = <Workflow>[];
    for (final String id in templateIds) {
      final String? time = times[id];
      if (time == null) continue;
      Workflow w = TemplateGallery.byId(id)!.instantiate(recipient: name, timeZone: timeZone, idGenerator: idGenerator);
      final WorkflowTrigger t = w.trigger;
      if (t is ScheduleTrigger) w = w.copyWith(trigger: t.copyWith(timeOfDay: time));
      w = w.copyWith(steps: <WorkflowStep>[
        for (final WorkflowStep s in w.steps)
          if (s is WhatsAppStep) s.copyWith(mode: business ? WhatsAppMode.send : WhatsAppMode.prepare) else s,
      ]);
      w = w.copyWith(executionMode: ExecutionCapabilities.bestModeFor(w, defaultMode), enabled: false);
      out.add(w);
    }
    return out;
  }
}
