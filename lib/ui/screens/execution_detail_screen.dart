import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_status.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';
import 'home_screen.dart';

/// "Execution details" (spec §19).
class ExecutionDetailScreen extends StatefulWidget {
  const ExecutionDetailScreen({required this.record, super.key});
  final ExecutionRecord record;

  @override
  State<ExecutionDetailScreen> createState() => _ExecutionDetailScreenState();
}

class _ExecutionDetailScreenState extends State<ExecutionDetailScreen> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    final ExecutionRecord? r = await context.read<AppState>().retry(widget.record.id);
    if (!mounted) return;
    setState(() => _retrying = false);
    if (r != null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ExecutionDetailScreen(record: r)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ExecutionRecord r = widget.record;
    return Scaffold(
      appBar: AppBar(title: const Text('Execution details')),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          Panel(
            glow: statusColor(r.status),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              LabeledValue(label: 'Workflow', value: r.workflowName),
              LabeledValue(label: 'Scheduled', value: Formatters.stamp(r.scheduledFor.toLocal())),
              if (r.startedAt != null) LabeledValue(label: 'Started', value: Formatters.stamp(r.startedAt!.toLocal())),
              LabeledValue(label: 'Source', value: r.source.label),
              LabeledValue(label: 'Status', value: honestStatusLabel(r).toUpperCase()),
              if (r.failureReason != null) LabeledValue(label: 'Reason', value: r.failureReason!),
              LabeledValue(label: 'Attempts', value: '${r.attempt} of ${r.maxAttempts}'),
            ]),
          ),
          const SizedBox(height: AutometaSpacing.xl),
          const SectionLabel('Steps'),
          for (final StepExecution s in r.stepResults)
            Padding(
              padding: const EdgeInsets.only(bottom: AutometaSpacing.sm),
              child: Panel(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Icon(stepIcon(s.kind), size: 20),
                  const SizedBox(width: AutometaSpacing.md),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text(s.title, style: Theme.of(context).textTheme.titleSmall),
                      if (s.detail != null) Text(s.detail!, style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                  StatusPill(
                    label: s.simulated ? 'SIMULATED' : s.outcome.label,
                    color: s.outcome == StepOutcome.failed
                        ? AutometaColors.danger
                        : s.outcome == StepOutcome.success
                            ? AutometaColors.success
                            : AutometaColors.neutral,
                  ),
                ]),
              ),
            ),
          if (r.stepResults.isEmpty) const Text('No steps ran.'),
          if (r.status == ExecutionStatus.failed && !r.dryRun) ...<Widget>[
            const SizedBox(height: AutometaSpacing.xl),
            PrimaryAction(label: 'Retry', icon: Icons.refresh, busy: _retrying, onPressed: _retry),
          ],
        ],
      ),
    );
  }
}
