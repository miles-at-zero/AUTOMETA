import 'package:flutter/material.dart';

import '../../../business/business_api.dart';
import '../../../core/theme/design_tokens.dart';
import '../../widgets/autometa_widgets.dart';
import 'business_common.dart';
import 'plans_screen.dart';

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  int _days = 7;
  final GlobalKey<LoaderState<Json>> _key = GlobalKey<LoaderState<Json>>();

  @override
  Widget build(BuildContext context) {
    final bool allowed = sessionOf(context).can('analytics');
    if (!allowed) {
      return ListView(padding: const EdgeInsets.all(16), children: <Widget>[
        const SizedBox(height: 40),
        EmptyState(
          icon: Icons.insights_outlined,
          title: 'See what your automations achieve',
          message: 'Conversations, orders, leads, handoffs, response times and your best workflows. Included in Pro.',
          action: FilledButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlansScreen())), child: const Text('See plans')),
        ),
      ]);
    }
    return Loader<Json>(
      key: _key,
      load: () => apiOf(context).get('/businesses/${sessionOf(context).bid}/analytics?days=$_days'),
      builder: (BuildContext context, Json a, _) {
        final Json t = asMap(a['totals']);
        final Json rt = asMap(a['responseTimes']);
        final List<Json> daily = asList(a['daily']);
        String dur(Object? ms) {
          final int v = intOf(ms);
          if (v == 0) return '-';
          if (v < 60000) return '${(v / 1000).toStringAsFixed(1)}s';
          if (v < 3600000) return '${v ~/ 60000}m';
          return '${(v / 3600000).toStringAsFixed(1)}h';
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            SegmentedButton<int>(
              segments: const <ButtonSegment<int>>[ButtonSegment<int>(value: 1, label: Text('Today')), ButtonSegment<int>(value: 7, label: Text('7 days')), ButtonSegment<int>(value: 30, label: Text('30 days'))],
              selected: <int>{_days},
              onSelectionChanged: (Set<int> v) {
                setState(() => _days = v.first);
                _key.currentState?.reload();
              },
            ),
            const SizedBox(height: 12),
            if (intOf(a['waitingForStaff']) > 0)
              Panel(glow: AutometaColors.warning, accentLeft: true, child: Text('${intOf(a['waitingForStaff'])} customer(s) waiting for a person. Open Inbox → Needs you.')),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.9,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: <Widget>[
                _Kpi('Conversations', '${intOf(t['conversations'])}', Icons.forum_outlined, AutometaColors.accent),
                _Kpi('Automated replies', '${intOf(t['automatedReplies']) + intOf(t['faqAnswers'])}', Icons.bolt, AutometaColors.secondary),
                _Kpi('Leads captured', '${intOf(t['leadsCaptured'])}', Icons.person_add_alt, AutometaColors.success),
                _Kpi('Orders', '${intOf(t['ordersCompleted'])} / ${intOf(t['ordersStarted'])}', Icons.receipt_long, AutometaColors.info, sub: a['orderConversion'] == null ? 'completed / started' : '${intOf(a['orderConversion'])}% completed'),
                _Kpi('Handoffs to staff', '${intOf(t['handoffs'])}', Icons.support_agent, AutometaColors.warning),
                _Kpi('Automation rate', '${intOf(a['automationRate'])}%', Icons.auto_mode, AutometaColors.accent, sub: 'messages answered automatically'),
                _Kpi('Bot reply time', dur(rt['automatedMs']), Icons.timer_outlined, AutometaColors.secondary),
                _Kpi('Staff first reply', dur(rt['staffFirstReplyMs']), Icons.timer, AutometaColors.warning),
              ],
            ),
            const SizedBox(height: 16),
            const SectionLabel('Activity'),
            Panel(child: SizedBox(height: 120, child: _Bars(values: daily.map((Json d) => intOf(d['incoming'])).toList(), auto: daily.map((Json d) => intOf(d['auto_reply'])).toList()))),
            const SizedBox(height: 4),
            Text('  ■ incoming   ■ automated', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            const SectionLabel('Workflow health'),
            Panel(
              child: Column(children: <Widget>[
                LabeledValue(label: 'Runs', value: '${intOf(t['flowRuns'])}'),
                LabeledValue(label: 'Completed', value: '${intOf(t['flowCompleted'])}'),
                LabeledValue(label: 'Failed', value: '${intOf(t['flowFailed'])}'),
                LabeledValue(label: 'WhatsApp send failures', value: '${intOf(t['sendFailures'])}'),
                LabeledValue(label: 'Follow-ups sent', value: '${intOf(t['followupsSent'])}'),
              ]),
            ),
            const SizedBox(height: 16),
            const SectionLabel('Top automations'),
            if (asList(a['topFlows']).isEmpty) const Text('No workflow runs in this period.'),
            for (final Json f in asList(a['topFlows']))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(str(f['name'])),
                subtitle: Text('${intOf(f['completed'])} completed · ${intOf(f['handoffs'])} handed off · ${intOf(f['failed'])} failed'),
                trailing: Text('${intOf(f['runs'])}', style: Theme.of(context).textTheme.titleMedium),
              ),
            if (asList(a['categories']).isNotEmpty) ...<Widget>[
              const SectionLabel('What customers want'),
              Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
                for (final Json c in asList(a['categories'])) StatusPill(label: '${str(c['category'])} · ${intOf(c['n'])}', color: AutometaColors.info),
              ]),
            ],
            if (asList(a['recentErrors']).isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              const SectionLabel('Recent errors'),
              for (final Json e in asList(a['recentErrors']))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.error_outline, color: AutometaColors.danger),
                  title: Text(str(e['type']).replaceAll('_', ' ')),
                  subtitle: Text(str(asMap(e['data'])['error']).isEmpty ? str(e['data']) : str(asMap(e['data'])['error'])),
                  trailing: Text(ago(e['ts'])),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.icon, this.color, {this.sub});

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? sub;

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
          Row(children: <Widget>[Icon(icon, size: 16, color: color), const SizedBox(width: 6), Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall))]),
          const SizedBox(height: 4),
          FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
          if (sub != null) Text(sub!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
        ]),
      );
}

class _Bars extends StatelessWidget {
  const _Bars({required this.values, required this.auto});

  final List<int> values;
  final List<int> auto;

  @override
  Widget build(BuildContext context) {
    final int max = values.fold<int>(1, (int m, int v) => v > m ? v : m);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        for (int i = 0; i < values.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Stack(alignment: Alignment.bottomCenter, children: <Widget>[
                FractionallySizedBox(heightFactor: values[i] / max, child: Container(decoration: BoxDecoration(color: AutometaColors.accent.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(3)))),
                FractionallySizedBox(heightFactor: (i < auto.length ? auto[i] : 0).clamp(0, values[i]) / max, child: Container(decoration: BoxDecoration(color: AutometaColors.secondary, borderRadius: BorderRadius.circular(3)))),
              ]),
            ),
          ),
      ],
    );
  }
}
