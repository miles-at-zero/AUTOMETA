import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../domain/engine/approval_request.dart';
import 'autometa_widgets.dart';

/// Emoji + label for the part of day a run belongs to.
(String, String) partOfDay(DateTime at) {
  final int h = at.toLocal().hour;
  if (h >= 5 && h < 12) return ('🌅', 'MORNING');
  if (h >= 12 && h < 17) return ('☀️', 'AFTERNOON');
  if (h >= 17 && h < 21) return ('🌆', 'EVENING');
  return ('🌙', 'NIGHT');
}

bool isWhatsAppHandoff(ApprovalTicket t) =>
    t.integrationId == IntegrationIds.whatsapp && t.action != 'open_conversation';

/// The pending personal-WhatsApp message, presented as a deliberate
/// "ready to send" step rather than a blocked automation.
class MessageReadyCard extends StatelessWidget {
  const MessageReadyCard({
    super.key,
    required this.ticket,
    required this.onSend,
    required this.onSkip,
    this.busy = false,
  });

  final ApprovalTicket ticket;
  final VoidCallback onSend;
  final VoidCallback onSkip;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final (String emoji, String part) = partOfDay(ticket.createdAt);
    final String time = DateFormat.jm().format(ticket.createdAt.toLocal());
    final String recipient = ticket.fields['Recipient'] ?? '';
    final String account = ticket.fields['Account'] ?? 'WhatsApp';
    return Panel(
      glow: AutometaColors.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Text('$emoji  ${ticket.workflowName.toUpperCase()}',
            style: text.labelLarge?.copyWith(color: AutometaColors.accent, letterSpacing: 1.2)),
        if (!ticket.workflowName.toUpperCase().contains(part))
          Text('$part AUTOMATION', style: text.labelSmall?.copyWith(letterSpacing: 1.2)),
        const SizedBox(height: AutometaSpacing.md),
        Text(ticket.body.isEmpty ? ticket.title : ticket.body, style: text.titleLarge),
        const SizedBox(height: AutometaSpacing.md),
        Row(children: <Widget>[
          const Icon(Icons.schedule, size: 16),
          const SizedBox(width: 6),
          Text('Scheduled for $time'),
        ]),
        const SizedBox(height: 4),
        Row(children: <Widget>[
          const Icon(Icons.chat_outlined, size: 16),
          const SizedBox(width: 6),
          Expanded(child: Text(recipient.isEmpty ? account : '$account · $recipient', overflow: TextOverflow.ellipsis)),
        ]),
        if (ticket.simulated) ...<Widget>[
          const SizedBox(height: AutometaSpacing.sm),
          const StatusPill(label: 'SIMULATION: nothing will be sent', color: AutometaColors.warning),
        ],
        const SizedBox(height: AutometaSpacing.lg),
        PrimaryAction(label: 'Open WhatsApp & Send', icon: Icons.send, busy: busy, onPressed: onSend),
        const SizedBox(height: AutometaSpacing.sm),
        Text(
          'This message will be ready to send in WhatsApp. Just tap Send.',
          textAlign: TextAlign.center,
          style: text.bodySmall,
        ),
        TextButton(onPressed: busy ? null : onSkip, child: const Text('Skip this time')),
      ]),
    );
  }
}
