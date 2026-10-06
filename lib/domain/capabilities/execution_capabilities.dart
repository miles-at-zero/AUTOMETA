import 'package:meta/meta.dart';

import '../models/condition.dart';
import '../models/execution_mode.dart';
import '../models/step.dart';
import '../models/trigger.dart';
import '../models/workflow.dart';

/// Which execution modes a trigger / condition / action supports.
enum CapabilitySupport { cloud, onDevice, both, unsupported }

@immutable
class Capability {
  const Capability(this.support, {this.cloudNote, this.deviceNote});

  final CapabilitySupport support;

  /// Why it can't run in Cloud (or a caveat when it can).
  final String? cloudNote;

  /// Why it can't run on the device (or the OS caveat when it can).
  final String? deviceNote;

  bool supports(ExecutionMode mode) => switch (support) {
        CapabilitySupport.both => true,
        CapabilitySupport.cloud => mode == ExecutionMode.cloud,
        CapabilitySupport.onDevice => mode == ExecutionMode.onDevice,
        CapabilitySupport.unsupported => false,
      };

  String? noteFor(ExecutionMode mode) => mode == ExecutionMode.cloud ? cloudNote : deviceNote;
}

/// A step or trigger that the chosen mode can't execute.
@immutable
class CapabilityIssue {
  const CapabilityIssue({required this.label, required this.reason, this.stepId});

  final String? stepId;
  final String label;
  final String reason;

  @override
  String toString() => '$label: $reason';
}

/// Single source of truth for what runs where. The builder filters pickers
/// with it, activation and "Move to Cloud" refuse anything it rejects, and the
/// cloud mapper only translates what it accepts. Keep it honest: only claim
/// support the matching execution adapter really implements.
abstract final class ExecutionCapabilities {
  static const String _gmailDevice = 'Gmail works through Autometa Cloud (your Google sign-in is stored encrypted on the server, never on the phone). Switch this automation to Cloud.';
  static const String _telegramDevice = 'Telegram works through Autometa Cloud (your bot token is stored encrypted on the server, never on the phone). Switch this automation to Cloud.';
  static const String _osNote = 'Runs on time only while Android allows it (battery saver, exact-alarm and notification permissions).';

  /// Cloud condition operators (server/src/cloud/engine.js evalRule).
  static const Map<ConditionOperator, String> cloudOperators = <ConditionOperator, String>{
    ConditionOperator.equals: 'eq',
    ConditionOperator.notEquals: 'neq',
    ConditionOperator.contains: 'contains',
    ConditionOperator.notContains: 'not_contains',
    ConditionOperator.startsWith: 'starts_with',
    ConditionOperator.greaterThan: 'gt',
    ConditionOperator.lessThan: 'lt',
    ConditionOperator.isNotEmpty: 'exists',
    ConditionOperator.isEmpty: 'not_exists',
  };

  /// Cloud conditions read a field such as `{{payload.priority}}`.
  static final RegExp cloudField = RegExp(r'^\s*\{\{\s*([\w.]+)\s*\}\}\s*$');

  static Capability trigger(WorkflowTrigger t) => switch (t) {
        ScheduleTrigger() => const Capability(CapabilitySupport.both, deviceNote: _osNote),
        ManualTrigger() => const Capability(CapabilitySupport.both),
        DateTimeTrigger() => const Capability(CapabilitySupport.onDevice,
            cloudNote: 'One-off date reminders run only on this device for now. Use a repeating schedule for Cloud.', deviceNote: _osNote),
        AppEventTrigger() => const Capability(CapabilitySupport.onDevice,
            cloudNote: 'Phone events (charging, boot, connectivity…) only happen on the phone.'),
        GmailTrigger() => const Capability(CapabilitySupport.cloud,
            cloudNote: 'Autometa Cloud checks your connected Gmail about every minute.',
            deviceNote: _gmailDevice),
        WebhookTrigger() => const Capability(CapabilitySupport.cloud,
            deviceNote: 'A phone can\'t receive webhooks from the internet. Use Cloud for webhook triggers.'),
      };

  static Capability step(WorkflowStep s) => switch (s) {
        WhatsAppStep(:final WhatsAppMode mode, :final String? account) => mode == WhatsAppMode.send
            ? (account == 'personal'
                ? const Capability(CapabilitySupport.unsupported,
                    cloudNote: 'Autometa never sends silently from personal WhatsApp. Use "Prepare message" (you tap Send) or the official WhatsApp Business API.',
                    deviceNote: 'Autometa never sends silently from personal WhatsApp. Use "Prepare message" (you tap Send) or the official WhatsApp Business API.')
                : const Capability(CapabilitySupport.both,
                    cloudNote: 'Sends with the official WhatsApp Business API from your Cloud WhatsApp connection.',
                    deviceNote: 'Sends with the official WhatsApp Business API from this phone.'))
            : const Capability(CapabilitySupport.onDevice,
                cloudNote: 'Preparing a message opens WhatsApp on your phone for you to tap Send, so it runs on this device.'),
        NotificationStep() => const Capability(CapabilitySupport.both,
            cloudNote: 'Appears in Autometa\'s notification inbox.', deviceNote: 'Shows an Android notification.'),
        HttpStep() => const Capability(CapabilitySupport.both, cloudNote: 'Public https:// URLs only.'),
        WebhookStep() => const Capability(CapabilitySupport.both, cloudNote: 'Public https:// URLs only.'),
        DelayStep() => const Capability(CapabilitySupport.both),
        AiStep() => const Capability(CapabilitySupport.onDevice, cloudNote: 'AI blocks use your on-device AI key and run on this device for now.'),
        ClipboardStep() => const Capability(CapabilitySupport.onDevice, cloudNote: 'The clipboard exists only on your phone.'),
        OpenUrlStep() => const Capability(CapabilitySupport.onDevice, cloudNote: 'Opening a link needs your phone.'),
        SetVariableStep() => const Capability(CapabilitySupport.onDevice, cloudNote: 'Variables blocks run on this device for now.'),
        ConditionStep() => const Capability(CapabilitySupport.both),
        GmailSendStep() => const Capability(CapabilitySupport.cloud, cloudNote: 'Sends from the Gmail account connected to Autometa Cloud.', deviceNote: _gmailDevice),
        TelegramSendStep() => const Capability(CapabilitySupport.cloud, cloudNote: 'Sends from your Telegram bot connected to Autometa Cloud.', deviceNote: _telegramDevice),
      };

  /// Block-picker level support (before the block is configured).
  static Capability kind(StepKind k) => switch (k) {
        StepKind.whatsapp => const Capability(CapabilitySupport.both,
            cloudNote: 'In Cloud: automatic sending with the official WhatsApp Business API only.',
            deviceNote: 'Prepare a message you send with one tap, or send with the WhatsApp Business API.'),
        StepKind.notification || StepKind.http || StepKind.webhook || StepKind.delay || StepKind.condition =>
          const Capability(CapabilitySupport.both),
        StepKind.ai => const Capability(CapabilitySupport.onDevice, cloudNote: 'Runs on this device for now.'),
        StepKind.clipboard => const Capability(CapabilitySupport.onDevice, cloudNote: 'The clipboard exists only on your phone.'),
        StepKind.openUrl => const Capability(CapabilitySupport.onDevice, cloudNote: 'Opening a link needs your phone.'),
        StepKind.setVariable => const Capability(CapabilitySupport.onDevice, cloudNote: 'Runs on this device for now.'),
        StepKind.gmailSend => const Capability(CapabilitySupport.cloud, cloudNote: 'Sends from your Gmail connected to Autometa Cloud.', deviceNote: _gmailDevice),
        StepKind.telegramSend => const Capability(CapabilitySupport.cloud, cloudNote: 'Sends from your Telegram bot connected to Autometa Cloud.', deviceNote: _telegramDevice),
      };

  static Capability triggerType(TriggerType t) => switch (t) {
        TriggerType.schedule => const Capability(CapabilitySupport.both, deviceNote: _osNote),
        TriggerType.manual => const Capability(CapabilitySupport.both),
        TriggerType.dateTime => const Capability(CapabilitySupport.onDevice, cloudNote: 'One-off dates run only on this device for now.'),
        TriggerType.appEvent => const Capability(CapabilitySupport.onDevice, cloudNote: 'Phone events only happen on the phone.'),
        TriggerType.webhook => const Capability(CapabilitySupport.cloud, deviceNote: 'A phone can\'t receive webhooks. Use Cloud.'),
        TriggerType.gmailNewEmail => const Capability(CapabilitySupport.cloud, cloudNote: 'Checked by Autometa Cloud about every minute.', deviceNote: _gmailDevice),
      };

  static String stepTitle(WorkflowStep s) => s.label?.trim().isNotEmpty == true ? s.label!.trim() : switch (s) {
        WhatsAppStep(:final WhatsAppMode mode) => mode == WhatsAppMode.send ? 'WhatsApp Business: send message' : 'Personal WhatsApp: prepare message (you tap Send)',
        _ => s.kind.label,
      };

  /// Every reason [workflow] can't run in [mode]. Empty = compatible.
  static List<CapabilityIssue> check(Workflow workflow, ExecutionMode mode) {
    final List<CapabilityIssue> out = <CapabilityIssue>[];
    final Capability t = trigger(workflow.trigger);
    if (!t.supports(mode)) {
      out.add(CapabilityIssue(label: 'Trigger: ${workflow.trigger.type.label}', reason: t.noteFor(mode) ?? 'Not available here.'));
    }
    _steps(workflow.steps, mode, out, topLevel: true);
    return out;
  }

  static void _steps(List<WorkflowStep> steps, ExecutionMode mode, List<CapabilityIssue> out, {required bool topLevel}) {
    for (int i = 0; i < steps.length; i++) {
      final WorkflowStep s = steps[i];
      final Capability c = step(s);
      if (!c.supports(mode)) {
        out.add(CapabilityIssue(stepId: s.id, label: stepTitle(s), reason: c.noteFor(mode) ?? 'Not available here.'));
      }
      if (s is ConditionStep) {
        if (mode == ExecutionMode.cloud) {
          // The cloud engine evaluates a condition as "continue only if true".
          // That equals IF/THEN only when nothing follows the block and there's no ELSE.
          if (s.elseSteps.isNotEmpty) {
            out.add(CapabilityIssue(stepId: s.id, label: 'Condition', reason: 'ELSE branches run only on this device for now. Remove the ELSE blocks to use Cloud.'));
          }
          if (!topLevel || i != steps.length - 1) {
            out.add(CapabilityIssue(stepId: s.id, label: 'Condition', reason: 'In Cloud a condition must be the last block (its THEN blocks run after it). Move other blocks above it.'));
          }
          for (final Condition c in s.conditions) {
            if (!cloudOperators.containsKey(c.operator)) {
              out.add(CapabilityIssue(stepId: s.id, label: 'Condition', reason: '"${c.operator.label}" isn\'t available in Cloud yet.'));
            }
            if (cloudField.firstMatch(c.left) == null) {
              out.add(CapabilityIssue(stepId: s.id, label: 'Condition', reason: 'In Cloud the left side must be a single variable such as {{payload.status}}.'));
            }
          }
        }
        _steps(s.thenSteps, mode, out, topLevel: false);
        _steps(s.elseSteps, mode, out, topLevel: false);
      }
    }
  }

  /// The mode a new automation should get: the user's preference when it's
  /// compatible, otherwise the other mode if that works.
  static ExecutionMode bestModeFor(Workflow w, ExecutionMode preferred) {
    if (check(w, preferred).isEmpty) return preferred;
    final ExecutionMode other = preferred.isCloud ? ExecutionMode.onDevice : ExecutionMode.cloud;
    return check(w, other).isEmpty ? other : preferred;
  }
}
