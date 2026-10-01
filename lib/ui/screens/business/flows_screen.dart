import 'package:flutter/material.dart';

import '../../../business/business_api.dart';
import '../../../core/theme/design_tokens.dart';
import '../../widgets/autometa_widgets.dart';
import 'business_common.dart';
import 'flow_editor_screen.dart';
import 'more_screen.dart';

class FlowsScreen extends StatefulWidget {
  const FlowsScreen({super.key});

  @override
  State<FlowsScreen> createState() => _FlowsScreenState();
}

class _FlowsScreenState extends State<FlowsScreen> {
  final GlobalKey<LoaderState<List<Json>>> _key = GlobalKey<LoaderState<List<Json>>>();

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await _key.currentState?.reload();
  }

  Future<void> _new() async {
    final bool ai = sessionOf(context).can('ai');
    final String? pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          ListTile(leading: const Icon(Icons.dashboard_customize_outlined), title: const Text('Start from a template'), subtitle: const Text('Food orders, bookings, welcome, away hours…'), onTap: () => Navigator.pop(c, 'tpl')),
          ListTile(leading: const Icon(Icons.edit_note), title: const Text('Build from scratch'), onTap: () => Navigator.pop(c, 'blank')),
          ListTile(
            leading: const Icon(Icons.auto_awesome, color: AutometaColors.secondary),
            title: const Text('Describe it, AI builds it'),
            subtitle: Text(ai ? 'You review every step before saving' : 'Business plan'),
            onTap: () => Navigator.pop(c, 'ai'),
          ),
        ]),
      ),
    );
    if (!mounted || pick == null) return;
    if (pick == 'tpl') return _open(const TemplatesScreen());
    if (pick == 'blank') return _open(const FlowEditorScreen());
    final String? text = await promptText(context, 'Describe your workflow', lines: 4, hint: 'When someone says "price list", send our prices, ask what they want to buy and how many, then hand to staff.');
    if (!mounted || text == null || text.trim().isEmpty) return;
    try {
      final Json r = await apiOf(context).post('/businesses/${sessionOf(context).bid}/ai/flow', <String, dynamic>{'description': text});
      if (!mounted) return;
      final List<String> errs = asStrings(asMap(r['validation'])['errors']);
      if (errs.isNotEmpty) toast(context, 'Needs a fix before saving: ${errs.first}');
      await _open(FlowEditorScreen(draft: asMap(r['flow'])));
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String bid = sessionOf(context).bid;
    final bool canEdit = sessionOf(context).allowed('flows.write');
    return Scaffold(
      floatingActionButton: canEdit ? FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.add), label: const Text('New workflow')) : null,
      body: Loader<List<Json>>(
        key: _key,
        load: () => apiOf(context).list('/businesses/$bid/flows'),
        builder: (BuildContext context, List<Json> flows, Future<void> Function() reload) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: <Widget>[
            Row(children: <Widget>[
              Expanded(child: OutlinedButton.icon(onPressed: () => _open(const RunsScreen()), icon: const Icon(Icons.bug_report_outlined), label: const Text('Activity log'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: () => _open(const FaqScreen()), icon: const Icon(Icons.quiz_outlined), label: const Text('FAQs'))),
            ]),
            const SizedBox(height: 12),
            if (flows.isEmpty)
              const EmptyState(icon: Icons.account_tree_outlined, title: 'No workflows yet', message: 'Start with a template. The food-order and welcome workflows take a minute to set up.'),
            for (final Json f in flows) ...<Widget>[
              Panel(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
                accentLeft: f['enabled'] == true && f['pausedByPlan'] != true,
                onTap: () => _open(FlowEditorScreen(flowId: str(f['id']))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Row(children: <Widget>[
                    Expanded(child: Text(str(f['name']), style: Theme.of(context).textTheme.titleMedium)),
                    Switch(
                      value: f['enabled'] == true,
                      onChanged: !canEdit ? null : (bool v) async {
                        try {
                          await apiOf(context).put('/flows/${f['id']}', <String, dynamic>{'enabled': v});
                          await reload();
                        } catch (e) {
                          if (context.mounted) await showBusinessError(context, e);
                        }
                      },
                    ),
                  ]),
                  Text(triggerLabel(asMap(f['trigger'])), style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
                    StatusPill(label: '${asList(f['nodes']).length} steps', color: AutometaColors.neutral),
                    StatusPill(label: '${intOf(asMap(f['stats'])['runs'])} runs', color: AutometaColors.info),
                    if (intOf(asMap(f['stats'])['failed']) > 0) StatusPill(label: '${intOf(asMap(f['stats'])['failed'])} failed', color: AutometaColors.danger),
                    if (f['pausedByPlan'] == true) const StatusPill(label: 'Paused by plan', color: AutometaColors.warning),
                  ]),
                ]),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

String triggerLabel(Json t) => switch (str(t['type'])) {
      'keyword' => 'When a message contains: ${asStrings(t['keywords']).join(', ')}',
      'button' => 'When a button is tapped: ${asStrings(t['keywords']).join(', ')}',
      'greeting' => 'When a new customer writes for the first time',
      'away_hours' => 'When someone writes outside business hours',
      'fallback' => 'When nothing else matches',
      _ => 'Unknown trigger',
    };

class TemplatesScreen extends StatelessWidget {
  const TemplatesScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Templates')),
        body: Loader<List<Json>>(
          load: () => apiOf(context).list('/templates'),
          builder: (BuildContext context, List<Json> tpls, _) => ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              for (final Json t in tpls) ...<Widget>[
                Panel(
                  onTap: () async {
                    try {
                      final Json f = await apiOf(context).post('/businesses/${sessionOf(context).bid}/templates/${t['id']}');
                      if (!context.mounted) return;
                      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => FlowEditorScreen(flowId: str(f['id']))));
                    } catch (e) {
                      if (context.mounted) await showBusinessError(context, e);
                    }
                  },
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Row(children: <Widget>[
                      Expanded(child: Text(str(t['name']), style: Theme.of(context).textTheme.titleMedium)),
                      if (t['locked'] == true) const Icon(Icons.lock_outline, size: 18, color: AutometaColors.secondary),
                    ]),
                    const SizedBox(height: 4),
                    Text(str(t['description'])),
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, children: <Widget>[
                      StatusPill(label: str(t['category']), color: AutometaColors.info),
                      StatusPill(label: '${intOf(t['steps'])} steps', color: AutometaColors.neutral),
                    ]),
                  ]),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      );
}

class RunsScreen extends StatelessWidget {
  const RunsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Activity log')),
        body: Loader<List<Json>>(
          load: () => apiOf(context).list('/businesses/${sessionOf(context).bid}/runs'),
          builder: (BuildContext context, List<Json> runs, _) => runs.isEmpty
              ? ListView(children: const <Widget>[SizedBox(height: 80), EmptyState(icon: Icons.history, title: 'No runs yet', message: 'Every time a workflow runs for a customer, it shows here step by step.')])
              : ListView.separated(
                  itemCount: runs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (BuildContext context, int i) {
                    final Json r = runs[i];
                    return ListTile(
                      leading: Icon(runIcon(str(r['status'])), color: runColor(str(r['status']))),
                      title: Text(str(r['flow']).isEmpty ? 'Deleted workflow' : str(r['flow'])),
                      subtitle: Text('${str(r['customer']).isEmpty ? '+${r['waId']}' : r['customer']} · ${str(r['status'])}${str(r['error']).isEmpty ? '' : ' · ${r['error']}'}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: Text(ago(r['startedAt'])),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RunDetailScreen(runId: str(r['id'])))),
                    );
                  },
                ),
        ),
      );
}

IconData runIcon(String s) => switch (s) {
      'completed' => Icons.check_circle_outline,
      'failed' => Icons.error_outline,
      'handoff' => Icons.support_agent,
      'waiting' => Icons.hourglass_bottom,
      _ => Icons.play_circle_outline,
    };
Color runColor(String s) => switch (s) {
      'completed' => AutometaColors.success,
      'failed' => AutometaColors.danger,
      'handoff' => AutometaColors.warning,
      _ => AutometaColors.info,
    };

class RunDetailScreen extends StatelessWidget {
  const RunDetailScreen({required this.runId, super.key});

  final String runId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Run details')),
        body: Loader<Json>(
          load: () => apiOf(context).get('/runs/$runId'),
          builder: (BuildContext context, Json r, _) => ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              Panel(child: Row(children: <Widget>[
                Icon(runIcon(str(r['status'])), color: runColor(str(r['status']))),
                const SizedBox(width: 12),
                Expanded(child: Text(str(r['error']).isEmpty ? str(r['status']) : '${r['status']}: ${r['error']}')),
              ])),
              const SizedBox(height: 12),
              TraceList(trace: asList(r['trace'])),
            ],
          ),
        ),
      );
}

/// Step-by-step trace from the engine: what ran, what the customer answered,
/// which branch was taken, and why something failed.
class TraceList extends StatelessWidget {
  const TraceList({required this.trace, super.key});

  final List<Json> trace;

  @override
  Widget build(BuildContext context) => Column(children: <Widget>[
        for (int i = 0; i < trace.length; i++)
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 11))),
            title: Text('${str(trace[i]['node'])} · ${str(trace[i]['type'])}'),
            subtitle: Text(
              <String>[str(trace[i]['outcome']), str(trace[i]['detail']), if (trace[i]['answer'] != null) 'answer: ${trace[i]['answer']}', str(trace[i]['error'])].where((String e) => e.isNotEmpty).join(' · '),
            ),
            iconColor: trace[i]['error'] != null ? AutometaColors.danger : null,
          ),
      ]);
}
