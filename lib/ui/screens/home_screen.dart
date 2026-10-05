import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/autometa_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/engine/approval_request.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_status.dart';
import '../../domain/models/step.dart';
import '../../services/connections/connection_manager.dart';
import '../../services/connections/connection_state.dart';
import '../../state/app_state.dart';
import '../app.dart';
import '../widgets/autometa_widgets.dart';
import 'approval_sheet.dart';
import 'business/business_shell.dart';
import '../widgets/message_ready_card.dart';
import 'execution_detail_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final ConnectionManager connections = context.watch<ConnectionManager>();
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    final DateTime now = DateTime.now();

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: state.refresh,
        child: ListView(
          padding: EdgeInsets.symmetric(horizontal: AutometaSpacing.page(context), vertical: AutometaSpacing.lg),
          children: <Widget>[
            ResponsiveWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const BrandMark(),
                  const SizedBox(height: AutometaSpacing.lg),
                  Text(Formatters.greeting(now), style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: AutometaSpacing.xs),
                  _EngineStatusLine(paused: state.isPaused),
                  const SizedBox(height: AutometaSpacing.xl),
                  if (state.isPaused) ...<Widget>[
                    Panel(
                      glow: AutometaColors.warning,
                      borderColor: AutometaColors.warning.withValues(alpha: 0.5),
                      child: Row(children: <Widget>[
                        const Icon(Icons.pause_circle_outline, color: AutometaColors.warning),
                        const SizedBox(width: AutometaSpacing.md),
                        const Expanded(child: Text('AUTOMETA PAUSED\nNo automated actions will execute.')),
                        TextButton(onPressed: () => state.setPaused(false), child: const Text('Resume')),
                      ]),
                    ),
                    const SizedBox(height: AutometaSpacing.lg),
                  ],
                  for (final ApprovalTicket t in state.pendingApprovals.where(isWhatsAppHandoff)) ...<Widget>[
                    MessageReadyCard(
                      ticket: t,
                      onSend: () async {
                        final ExecutionRecord? r = await state.resolveApproval(t.id, approved: true);
                        if (context.mounted) showToast(context, r == null ? 'Could not open WhatsApp' : honestStatusLabel(r));
                      },
                      onSkip: () => state.resolveApproval(t.id, approved: false),
                    ),
                    const SizedBox(height: AutometaSpacing.md),
                  ],
                  for (final ApprovalTicket t in state.pendingApprovals.where((ApprovalTicket t) => !isWhatsAppHandoff(t))) ...<Widget>[
                    Panel(
                      glow: AutometaColors.secondary,
                      accentLeft: true,
                      onTap: () => showApprovalSheet(context, t),
                      child: Row(children: <Widget>[
                        const Icon(Icons.verified_user_outlined, color: AutometaColors.secondary),
                        const SizedBox(width: AutometaSpacing.md),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                            Text('WAITING FOR APPROVAL', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AutometaColors.secondary)),
                            Text(t.title, style: Theme.of(context).textTheme.titleSmall),
                          ]),
                        ),
                        const Icon(Icons.chevron_right),
                      ]),
                    ),
                    const SizedBox(height: AutometaSpacing.md),
                  ],
                  _NextPanel(state: state),
                  const SizedBox(height: AutometaSpacing.md),
                  Row(children: <Widget>[
                    Expanded(child: _Metric(label: 'Active', value: '${state.activeCount}', color: AutometaColors.accent)),
                    const SizedBox(width: AutometaSpacing.md),
                    Expanded(child: _Metric(label: 'Failures', value: '${state.failureCount}', color: state.failureCount > 0 ? AutometaColors.danger : colors.textTertiary)),
                  ]),
                  const SizedBox(height: AutometaSpacing.xl),
                  const SectionLabel('Connections'),
                  Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
                    _connectionPill('WhatsApp', connections.whatsapp),
                    _connectionPill('AI', connections.ai),
                  ]),
                  const SizedBox(height: AutometaSpacing.xl),
                  const SectionLabel('Today'),
                  if (state.todaySlots.isEmpty)
                    Panel(child: Text('Nothing scheduled today.', style: Theme.of(context).textTheme.bodyMedium))
                  else
                    Panel(
                      padding: const EdgeInsets.symmetric(vertical: AutometaSpacing.sm),
                      child: Column(children: <Widget>[
                        for (final ScheduledSlot s in state.todaySlots) _SlotRow(slot: s),
                      ]),
                    ),
                  const SizedBox(height: AutometaSpacing.xl),
                  const SectionLabel('Recent'),
                  if (state.lastExecution == null)
                    Panel(child: Text('No runs yet.', style: Theme.of(context).textTheme.bodyMedium))
                  else
                    Panel(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ExecutionDetailScreen(record: state.lastExecution!),
                      )),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        Text('Last execution', style: Theme.of(context).textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Text(state.lastExecution!.workflowName, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        StatusPill(label: honestStatusLabel(state.lastExecution!), color: statusColor(state.lastExecution!.status)),
                      ]),
                    ),
                  const SizedBox(height: AutometaSpacing.xl),
                  PrimaryAction(label: 'Create Automation', icon: Icons.add, onPressed: () => AppShell.newAutomation(context)),
                  const SizedBox(height: AutometaSpacing.lg),
                  Panel(
                    glow: AutometaColors.secondary,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BusinessGate())),
                    child: const Row(children: <Widget>[
                      Icon(Icons.storefront_outlined, color: AutometaColors.secondary),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text('Business mode', style: TextStyle(fontWeight: FontWeight.w600)),
                          Text('Auto-reply to customers, take orders, capture leads and share the inbox with staff, using the official WhatsApp Business Platform.'),
                        ]),
                      ),
                      Icon(Icons.chevron_right),
                    ]),
                  ),
                  const SizedBox(height: AutometaSpacing.xl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectionPill(String name, ConnectionRecord? r) {
    final ConnectionStatus status = r?.status ?? ConnectionStatus.notConnected;
    final Color color = status == ConnectionStatus.connected
        ? AutometaColors.success
        : status == ConnectionStatus.degraded
            ? AutometaColors.accent
            : status == ConnectionStatus.error
                ? AutometaColors.danger
                : AutometaColors.neutral;
    final String label = r?.accountType == 'personal' && status.isUsable ? '$name · Personal · approval' : '$name · ${status.label}';
    return StatusPill(label: label, color: color, icon: Icons.circle, filled: status.isUsable);
  }
}

/// Status text that never claims more than the app knows (spec §40).
String honestStatusLabel(ExecutionRecord r) {
  if (r.dryRun) return 'SIMULATION';
  if (r.status == ExecutionStatus.success &&
      r.stepResults.any((StepExecution s) => s.code == 'whatsapp.handed_to_user')) {
    return 'Handed to WhatsApp — you tap Send';
  }
  if (r.status == ExecutionStatus.waitingApproval) return 'WAITING FOR APPROVAL';
  return r.status.label;
}

class _EngineStatusLine extends StatelessWidget {
  const _EngineStatusLine({required this.paused});
  final bool paused;

  @override
  Widget build(BuildContext context) => Row(children: <Widget>[
        StatusDot(paused ? AutometaColors.warning : AutometaColors.success, pulse: !paused),
        const SizedBox(width: 8),
        Text(paused ? 'Automation engine paused' : 'Automation engine ready', style: Theme.of(context).textTheme.bodyMedium),
      ]);
}

class _NextPanel extends StatelessWidget {
  const _NextPanel({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final run = state.nextRun;
    String preview = '';
    if (run != null) {
      for (final WorkflowStep s in run.workflow.steps) {
        if (s is WhatsAppStep) { preview = s.message; break; }
        if (s is NotificationStep) { preview = s.body; break; }
      }
    }
    return Panel(
      glow: AutometaColors.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const SectionLabel('Next automation'),
        if (run == null)
          Text('No scheduled automations', style: Theme.of(context).textTheme.titleMedium)
        else ...<Widget>[
          Text(Formatters.time(run.at.toLocal()), style: Theme.of(context).textTheme.displaySmall?.copyWith(color: AutometaColors.accent)),
          const SizedBox(height: 4),
          Text(preview.isEmpty ? run.workflow.name : Formatters.preview(preview), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('${run.workflow.name} · ${Formatters.relative(run.at.toLocal())}', style: Theme.of(context).textTheme.bodySmall),
        ],
      ]),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          Text(value, style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: color)),
        ]),
      );
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.slot});
  final ScheduledSlot slot;

  @override
  Widget build(BuildContext context) {
    final ExecutionRecord? e = slot.execution;
    final IconData icon;
    final Color color;
    if (e == null) {
      icon = Icons.radio_button_unchecked;
      color = AutometaColors.neutral;
    } else if (e.status == ExecutionStatus.success) {
      icon = Icons.check_circle;
      color = AutometaColors.success;
    } else if (e.status == ExecutionStatus.failed) {
      icon = Icons.error_outline;
      color = AutometaColors.danger;
    } else {
      icon = Icons.schedule;
      color = statusColor(e.status);
    }
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(slot.workflow.name),
      subtitle: e == null ? null : Text(honestStatusLabel(e)),
      trailing: Text(Formatters.time24(slot.at.toLocal()), style: Theme.of(context).textTheme.labelLarge),
      onTap: e == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExecutionDetailScreen(record: e))),
    );
  }
}
