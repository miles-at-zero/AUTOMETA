import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/design_tokens.dart';
import '../../domain/engine/approval_request.dart';
import '../../domain/models/execution.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';
import 'home_screen.dart';
import '../widgets/message_ready_card.dart';

/// "AUTOMETA NEEDS APPROVAL" (spec §23).
Future<void> showApprovalSheet(BuildContext context, ApprovalTicket ticket) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheet) => _ApprovalSheet(ticket: ticket),
    );

class _ApprovalSheet extends StatefulWidget {
  const _ApprovalSheet({required this.ticket});
  final ApprovalTicket ticket;

  @override
  State<_ApprovalSheet> createState() => _ApprovalSheetState();
}

class _ApprovalSheetState extends State<_ApprovalSheet> {
  bool _busy = false;

  Future<void> _decide(bool approved) async {
    setState(() => _busy = true);
    final AppState state = context.read<AppState>();
    final ExecutionRecord? result = await state.resolveApproval(widget.ticket.id, approved: approved);
    if (!mounted) return;
    Navigator.of(context).pop();
    showToast(context, result == null ? 'Approval could not be applied' : honestStatusLabel(result));
  }

  @override
  Widget build(BuildContext context) {
    final ApprovalTicket t = widget.ticket;
    if (isWhatsAppHandoff(t)) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AutometaSpacing.lg, 0, AutometaSpacing.lg, AutometaSpacing.lg),
          child: MessageReadyCard(
            ticket: t,
            busy: _busy,
            onSend: () => _decide(true),
            onSkip: () => _decide(false),
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AutometaSpacing.xl, 0, AutometaSpacing.xl, AutometaSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('AUTOMETA NEEDS APPROVAL',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AutometaColors.secondary, letterSpacing: 1.6)),
            const SizedBox(height: AutometaSpacing.sm),
            Text(t.title, style: Theme.of(context).textTheme.headlineSmall),
            Text(t.workflowName, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AutometaSpacing.lg),
            for (final MapEntry<String, String> f in t.fields.entries) LabeledValue(label: f.key, value: f.value),
            if (t.simulated) ...<Widget>[
              const SizedBox(height: AutometaSpacing.sm),
              const StatusPill(label: 'SIMULATION — nothing will be sent', color: AutometaColors.warning),
            ],
            const SizedBox(height: AutometaSpacing.xl),
            PrimaryAction(label: 'Approve', icon: Icons.check, busy: _busy, onPressed: () => _decide(true)),
            const SizedBox(height: AutometaSpacing.sm),
            OutlinedButton(onPressed: _busy ? null : () => _decide(false), child: const Text('Reject')),
          ],
        ),
      ),
    );
  }
}
