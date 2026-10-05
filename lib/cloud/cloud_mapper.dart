import '../domain/capabilities/execution_capabilities.dart';
import '../domain/models/condition.dart';
import '../domain/models/execution_mode.dart';
import '../domain/models/step.dart';
import '../domain/models/trigger.dart';
import '../domain/models/workflow.dart';

/// Translates a shared [Workflow] definition into the Autometa Cloud API
/// automation shape (server/src/cloud). Pure and synchronous so it is unit
/// tested; anything it can't translate faithfully becomes an issue instead
/// of a silently different automation.
class CloudMapping {
  const CloudMapping(this.body, this.issues);

  final Map<String, dynamic> body;
  final List<CapabilityIssue> issues;

  bool get ok => issues.isEmpty;
}

class CloudMapper {
  const CloudMapper({
    required this.phoneFor,
    this.whatsappConnectionId,
    this.webhookId,
    this.gmailConnectionId,
  });

  /// Cloud Gmail connection used by the Gmail trigger and send blocks.
  final String? gmailConnectionId;

  void _needGmail(List<CapabilityIssue> issues, {String? stepId}) {
    if (gmailConnectionId == null && !issues.any((CapabilityIssue i) => i.label == 'Gmail')) {
      issues.add(CapabilityIssue(stepId: stepId, label: 'Gmail',
          reason: 'Connect Gmail in Autometa Cloud first (Settings → Cloud account → Cloud connections).'));
    }
  }

  /// Contact alias → dialable digits (definitions store aliases, not numbers).
  final String? Function(String alias) phoneFor;

  /// Cloud WhatsApp Business connection used by "send" steps.
  final String? whatsappConnectionId;

  /// Cloud webhook used by a webhook trigger.
  final String? webhookId;

  CloudMapping map(Workflow w) {
    final List<CapabilityIssue> issues = <CapabilityIssue>[...ExecutionCapabilities.check(w, ExecutionMode.cloud)];
    final Map<String, dynamic>? trigger = _trigger(w.trigger, issues);
    final List<Map<String, dynamic>> steps = <Map<String, dynamic>>[];
    _steps(w, w.steps, steps, issues);
    return CloudMapping(<String, dynamic>{
      'name': w.name,
      'description': w.description,
      'timezone': w.timeZone,
      'trigger': trigger ?? <String, dynamic>{},
      'steps': steps,
      'retry': <String, dynamic>{'policy': w.maxRetries <= 0 ? 'none' : (w.maxRetries == 1 ? 'once' : 'three')},
      'onFailure': 'pause_after_3',
    }, issues);
  }

  Map<String, dynamic>? _trigger(WorkflowTrigger t, List<CapabilityIssue> issues) {
    switch (t) {
      case ScheduleTrigger(:final ScheduleRepeat repeat):
        final String time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
        final Map<String, dynamic> schedule = switch (repeat) {
          ScheduleRepeat.daily => <String, dynamic>{'times': <String>[time]},
          ScheduleRepeat.monthly => <String, dynamic>{'cron': '${t.minute} ${t.hour} ${t.dayOfMonth.clamp(1, 31)} * *'},
          ScheduleRepeat.interval => <String, dynamic>{'everyMinutes': t.intervalMinutes <= 0 ? 60 : t.intervalMinutes},
          _ => <String, dynamic>{
              'times': <String>[time],
              // ISO weekday (1=Mon…7=Sun) → cron (0=Sun…6=Sat).
              'days': (t.effectiveWeekdays.map((int d) => d % 7).toList()..sort()),
            },
        };
        return <String, dynamic>{'integration': 'autometa', 'key': 'schedule', 'schedule': schedule};
      case ManualTrigger():
        return <String, dynamic>{'integration': 'autometa', 'key': 'manual'};
      case WebhookTrigger():
        if (webhookId == null) {
          issues.add(const CapabilityIssue(label: 'Webhook trigger', reason: 'Create a Cloud webhook for this automation first.'));
        }
        return <String, dynamic>{
          'integration': 'webhook',
          'key': 'received',
          'config': <String, dynamic>{'webhookId': webhookId ?? ''},
        };
      case GmailTrigger(:final String query):
        _needGmail(issues);
        return <String, dynamic>{
          'integration': 'gmail',
          'key': 'new_email',
          'connectionId': gmailConnectionId ?? '',
          'config': <String, dynamic>{'query': query},
        };
      default:
        return null; // Already reported by the capability check.
    }
  }

  /// Custom variables are resolved locally; Cloud gets the final text.
  String _vars(Workflow w, String text) {
    String out = text;
    w.variables.forEach((String k, String v) => out = out.replaceAll(RegExp('\\{\\{\\s*${RegExp.escape(k)}\\s*\\}\\}'), v));
    return out;
  }

  void _steps(Workflow w, List<WorkflowStep> input, List<Map<String, dynamic>> out, List<CapabilityIssue> issues) {
    for (final WorkflowStep s in input) {
      final Map<String, dynamic> base = <String, dynamic>{'id': s.id, if (s.label != null) 'label': s.label};
      switch (s) {
        case NotificationStep(:final String title, :final String body):
          out.add(<String, dynamic>{...base, 'type': 'action', 'integration': 'autometa', 'action': 'notify',
            'config': <String, dynamic>{'title': _vars(w, title.isEmpty ? w.name : title), 'body': _vars(w, body.isEmpty ? title : body)}});
        case HttpStep(:final String method, :final String url, :final Map<String, String> headers, :final String body):
          out.add(<String, dynamic>{...base, 'type': 'action', 'integration': 'http', 'action': 'request',
            'config': <String, dynamic>{'method': method.toUpperCase(), 'url': _vars(w, url), if (headers.isNotEmpty) 'headers': headers, if (body.isNotEmpty) 'body': _vars(w, body)}});
        case WebhookStep(:final String url, :final String payload, :final Map<String, String> headers):
          out.add(<String, dynamic>{...base, 'type': 'action', 'integration': 'http', 'action': 'request',
            'config': <String, dynamic>{'method': 'POST', 'url': _vars(w, url), if (headers.isNotEmpty) 'headers': headers, if (payload.isNotEmpty) 'body': _vars(w, payload)}});
        case DelayStep(:final int seconds):
          out.add(<String, dynamic>{...base, 'type': 'delay', 'minutes': (seconds / 60).ceil().clamp(1, 60 * 24 * 7)});
        case WhatsAppStep(:final WhatsAppMode mode, :final String recipient, :final String message, :final String? templateName):
          if (mode != WhatsAppMode.send) break; // Reported by the capability check.
          final String? phone = phoneFor(recipient);
          if (phone == null || phone.isEmpty) {
            issues.add(CapabilityIssue(stepId: s.id, label: 'WhatsApp Business message', reason: 'No phone number saved for "$recipient". Add it in Contacts.'));
          }
          if (whatsappConnectionId == null) {
            issues.add(CapabilityIssue(stepId: s.id, label: 'WhatsApp Business message',
                reason: 'Connect WhatsApp Business to Autometa Cloud (Settings → Cloud account → Cloud connections).'));
          }
          out.add(<String, dynamic>{...base, 'type': 'action', 'integration': 'whatsapp',
            'action': templateName == null ? 'send_text' : 'send_template', 'connectionId': whatsappConnectionId,
            'config': templateName == null
                ? <String, dynamic>{'to': phone ?? '', 'text': _vars(w, message)}
                : <String, dynamic>{'to': phone ?? '', 'template': templateName, 'language': 'en_US'}});
        case ConditionStep(:final List<WorkflowStep> thenSteps):
          out.add(<String, dynamic>{...base, 'type': 'condition', 'mode': s.matchAny ? 'any' : 'all', 'rules': <Map<String, dynamic>>[
            for (final Condition c in s.conditions)
              <String, dynamic>{
                'field': ExecutionCapabilities.cloudField.firstMatch(c.left)?.group(1) ?? '',
                'op': ExecutionCapabilities.cloudOperators[c.operator] ?? 'eq',
                'value': _vars(w, c.right),
              },
          ]});
          _steps(w, thenSteps, out, issues);
        case GmailSendStep(:final String to, :final String subject, :final String body):
          _needGmail(issues, stepId: s.id);
          out.add(<String, dynamic>{...base, 'type': 'action', 'integration': 'gmail', 'action': 'send_email',
            'connectionId': gmailConnectionId,
            'config': <String, dynamic>{'to': _vars(w, to), 'subject': _vars(w, subject), 'body': _vars(w, body)}});
        default:
          break; // Device-only blocks: reported by the capability check.
      }
    }
  }
}
