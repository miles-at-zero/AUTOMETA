import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../business/business_api.dart';
import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_status.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';
import 'cloud_execution_screen.dart';
import 'execution_detail_screen.dart';
import 'home_screen.dart';

/// One row in Activity: a run on this device or in Cloud.
class _Item {
  _Item.local(ExecutionRecord this.record)
      : cloud = null,
        at = record.scheduledFor.toLocal();
  _Item.cloud(Json this.cloud)
      : record = null,
        at = DateTime.fromMillisecondsSinceEpoch(intOf(cloud['startedAt']));

  final ExecutionRecord? record;
  final Json? cloud;
  final DateTime at;
}

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<Json> _cloud = <Json>[];
  String? _cloudNote;

  @override
  void initState() {
    super.initState();
    _loadCloud();
  }

  Future<void> _loadCloud() async {
    final CloudSession c = context.read<CloudSession>();
    if (!c.signedIn) return;
    try {
      final List<Json> list = await c.executions();
      if (mounted) setState(() {
        _cloud = list;
        _cloudNote = null;
      });
    } on CloudException catch (e) {
      if (mounted) {
        setState(() => _cloudNote = e.offline
            ? 'Offline: Cloud automations keep running on the server. New Cloud results appear when you reconnect.'
            : e.message);
      }
    }
  }

  static String _bucket(DateTime d) {
    final DateTime now = DateTime.now();
    final DateTime day = DateTime(d.year, d.month, d.day);
    final DateTime today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return Formatters.fullDate(d);
  }

  Future<void> _refresh() async {
    await context.read<AppState>().refresh();
    await _loadCloud();
  }

  Widget _row(BuildContext context, _Item it) {
    final TextTheme t = Theme.of(context).textTheme;
    if (it.record != null) {
      final ExecutionRecord r = it.record!;
      final IconData icon = switch (r.status) {
        ExecutionStatus.success => Icons.check_circle,
        ExecutionStatus.failed => Icons.warning_amber_rounded,
        ExecutionStatus.waitingApproval => Icons.verified_user_outlined,
        ExecutionStatus.skipped => Icons.skip_next_outlined,
        _ => Icons.schedule,
      };
      return Panel(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExecutionDetailScreen(record: r))),
        child: Row(children: <Widget>[
          Icon(icon, color: statusColor(r.status)),
          const SizedBox(width: AutometaSpacing.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(r.workflowName, style: t.titleSmall),
              Text('📱 On this device · ${honestStatusLabel(r)}', style: t.bodySmall?.copyWith(color: statusColor(r.status))),
              if (r.failureReason != null && r.status != ExecutionStatus.success)
                Text(r.failureReason!, style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            ]),
          ),
          Text(Formatters.time24(it.at), style: t.labelLarge),
        ]),
      );
    }
    final Json e = it.cloud!;
    final String status = str(e['status']);
    final Color color = switch (status) {
      'success' => AutometaColors.success,
      'failed' || 'partial' => AutometaColors.danger,
      'running' => AutometaColors.accent,
      _ => AutometaColors.neutral,
    };
    return Panel(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CloudExecutionScreen(executionId: str(e['id'])))),
      child: Row(children: <Widget>[
        Icon(status == 'success' ? Icons.check_circle : (status == 'failed' || status == 'partial' ? Icons.warning_amber_rounded : Icons.cloud_outlined), color: color),
        const SizedBox(width: AutometaSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(str(e['automationName']), style: t.titleSmall),
            Text('☁️ Cloud · ${status[0].toUpperCase()}${status.substring(1)}${e['isTest'] == true ? ' · test' : ''}', style: t.bodySmall?.copyWith(color: color)),
            if (e['error'] != null) Text(str(e['error']), style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
        Text(Formatters.time24(it.at), style: t.labelLarge),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final List<_Item> items = <_Item>[
      ...state.recentExecutions.map(_Item.local),
      ..._cloud.map(_Item.cloud),
    ]..sort((_Item a, _Item b) => b.at.compareTo(a.at));
    final List<Widget> children = <Widget>[
      if (_cloudNote != null) Padding(padding: const EdgeInsets.only(top: AutometaSpacing.md), child: Panel(child: Text(_cloudNote!))),
    ];
    String? last;
    for (final _Item it in items) {
      final String b = _bucket(it.at);
      if (b != last) {
        children.add(Padding(padding: const EdgeInsets.only(top: AutometaSpacing.lg), child: SectionLabel(b)));
        last = b;
      }
      children.add(Padding(padding: const EdgeInsets.only(bottom: AutometaSpacing.sm), child: _row(context, it)));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('ACTIVITY')),
      body: items.isEmpty && _cloudNote == null
          ? const EmptyState(icon: Icons.history, title: 'No activity yet', message: 'Runs in Cloud and on this device will appear here.')
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(padding: EdgeInsets.symmetric(horizontal: AutometaSpacing.page(context)), children: children),
            ),
    );
  }
}
