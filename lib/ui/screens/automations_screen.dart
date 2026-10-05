import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/engine/engine_ports.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/step.dart';
import '../../domain/models/workflow.dart';
import '../../state/app_state.dart';
import '../app.dart';
import '../widgets/autometa_widgets.dart';
import '../widgets/execution_widgets.dart';
import 'cloud_account_screen.dart';
import 'builder_screen.dart';
import 'dry_run_sheet.dart';
import 'home_screen.dart';
import 'workflow_history_screen.dart';

class AutomationsScreen extends StatelessWidget {
  const AutomationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('AUTOMATIONS'),
        actions: <Widget>[
          IconButton(
            tooltip: 'New in builder',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BuilderScreen())),
          ),
        ],
      ),
      body: state.workflows.isEmpty
          ? EmptyState(
              icon: Icons.account_tree_outlined,
              title: 'No automations yet',
              message: 'Describe one in plain language or start from a template.',
              action: PrimaryAction(label: 'Create Automation', icon: Icons.add, onPressed: () => AppShell.goTo(context, 2)),
            )
          : ListView.separated(
              padding: EdgeInsets.all(AutometaSpacing.page(context)),
              itemCount: state.workflows.length,
              separatorBuilder: (_, __) => const SizedBox(height: AutometaSpacing.md),
              itemBuilder: (BuildContext context, int i) => ResponsiveWidth(child: WorkflowCard(workflow: state.workflows[i])),
            ),
    );
  }
}

class WorkflowCard extends StatelessWidget {
  const WorkflowCard({required this.workflow, super.key});
  final Workflow workflow;

  String _summary() {
    for (final WorkflowStep s in workflow.steps) {
      if (s is WhatsAppStep) return 'WhatsApp · ${s.message.isEmpty ? s.mode.label : s.message}';
      if (s is NotificationStep) return 'Notification · ${s.body}';
      if (s is AiStep) return 'AI · ${s.task.label}';
    }
    return workflow.steps.isEmpty ? 'No blocks' : workflow.steps.first.kind.label;
  }

  Future<void> _menu(BuildContext context, String action) async {
    final AppState state = context.read<AppState>();
    switch (action) {
      case 'test':
        final DryRunReport report = await state.dryRun(workflow);
        if (context.mounted) await showDryRunSheet(context, report);
      case 'run':
        try {
          final ExecutionRecord? r = await state.runNow(workflow.id);
          if (context.mounted) {
            showToast(context, workflow.isCloud ? 'Started in Cloud. See the result in its history.' : (r == null ? 'Could not run' : honestStatusLabel(r)));
          }
        } on CloudException catch (e) {
          if (context.mounted) showToast(context, e.message, color: AutometaColors.danger.withValues(alpha: 0.3));
        }
      case 'open':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WorkflowHistoryScreen(workflow: workflow)));
      case 'duplicate':
        await state.duplicate(workflow);
        if (context.mounted) showToast(context, 'Duplicated (disabled)');
      case 'history':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WorkflowHistoryScreen(workflow: workflow)));
      case 'delete':
        final bool ok = await confirmDialog(context,
            title: 'Delete ${workflow.name}?', message: 'Its schedule is cancelled. History is kept.', confirmLabel: 'Delete', destructive: true);
        if (ok) await state.delete(workflow.id);
    }
  }

  Future<void> _toggle(BuildContext context, bool v) async {
    try {
      await context.read<AppState>().setEnabled(workflow.id, v);
    } on CloudException catch (e) {
      if (!context.mounted) return;
      if (e.needsAccount) {
        final bool go = await confirmDialog(context, title: 'Cloud needs an account', message: e.message, confirmLabel: 'Sign in');
        if (go && context.mounted) await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CloudAccountScreen()));
      } else {
        showToast(context, e.issues.isEmpty ? e.message : '${e.message} ${e.issues.first}', color: AutometaColors.danger.withValues(alpha: 0.3));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool on = workflow.enabled;
    return Panel(
      onTap: () => _menu(context, 'open'),
      glow: on ? AutometaColors.accent : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(workflow.name, style: Theme.of(context).textTheme.titleMedium)),
          Switch(value: on, onChanged: (bool v) => _toggle(context, v)),
        ]),
        Row(children: <Widget>[
          StatusDot(on ? AutometaColors.success : AutometaColors.neutral),
          const SizedBox(width: 6),
          Text(on ? 'Active' : 'Inactive', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 10),
          Flexible(child: AutometaExecutionBadge(mode: workflow.executionMode, compact: true)),
        ]),
        const SizedBox(height: AutometaSpacing.md),
        Text(workflow.trigger.describe(), style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 4),
        Text(_summary(), maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: AutometaSpacing.md),
        Row(children: <Widget>[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BuilderScreen(initial: workflow))),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(onPressed: () => _menu(context, 'test'), icon: const Icon(Icons.science_outlined, size: 18), label: const Text('Test')),
          const Spacer(),
          PopupMenuButton<String>(
            onSelected: (String a) => _menu(context, a),
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'run', child: Text('Run now')),
              PopupMenuItem<String>(value: 'duplicate', child: Text('Duplicate')),
              PopupMenuItem<String>(value: 'open', child: Text('Details & execution')),
              PopupMenuItem<String>(value: 'history', child: Text('View history')),
              PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
            ],
          ),
        ]),
      ]),
    );
  }
}
