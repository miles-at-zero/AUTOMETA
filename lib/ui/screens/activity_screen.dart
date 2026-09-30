import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_status.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';
import 'execution_detail_screen.dart';
import 'home_screen.dart';

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  static String _bucket(DateTime d) {
    final DateTime now = DateTime.now();
    final DateTime day = DateTime(d.year, d.month, d.day);
    final DateTime today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return Formatters.fullDate(d);
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final List<ExecutionRecord> items = state.recentExecutions;
    final List<Widget> children = <Widget>[];
    String? last;
    for (final ExecutionRecord r in items) {
      final DateTime local = r.scheduledFor.toLocal();
      final String b = _bucket(local);
      if (b != last) {
        children.add(Padding(padding: const EdgeInsets.only(top: AutometaSpacing.lg), child: SectionLabel(b)));
        last = b;
      }
      final IconData icon = switch (r.status) {
        ExecutionStatus.success => Icons.check_circle,
        ExecutionStatus.failed => Icons.warning_amber_rounded,
        ExecutionStatus.waitingApproval => Icons.verified_user_outlined,
        ExecutionStatus.skipped => Icons.skip_next_outlined,
        _ => Icons.schedule,
      };
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: AutometaSpacing.sm),
        child: Panel(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExecutionDetailScreen(record: r))),
          child: Row(children: <Widget>[
            Icon(icon, color: statusColor(r.status)),
            const SizedBox(width: AutometaSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(r.workflowName, style: Theme.of(context).textTheme.titleSmall),
                Text(honestStatusLabel(r), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: statusColor(r.status))),
                if (r.failureReason != null && r.status != ExecutionStatus.success)
                  Text(r.failureReason!, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
            Text(Formatters.time24(local), style: Theme.of(context).textTheme.labelLarge),
          ]),
        ),
      ));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('ACTIVITY')),
      body: items.isEmpty
          ? const EmptyState(icon: Icons.history, title: 'No activity yet', message: 'Runs, skips and failures will appear here.')
          : RefreshIndicator(
              onRefresh: state.refresh,
              child: ListView(padding: EdgeInsets.symmetric(horizontal: AutometaSpacing.page(context)), children: children),
            ),
    );
  }
}
