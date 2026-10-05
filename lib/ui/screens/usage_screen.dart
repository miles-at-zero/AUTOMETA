import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../business/business_api.dart';
import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../widgets/autometa_widgets.dart';
import 'cloud_account_screen.dart';

/// Autometa Cloud usage for the current month, read from `/v1/usage`. Limits
/// come from the server's plan definition; nothing here is hardcoded.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key});

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  Json? _u;
  String? _error;

  static const List<(String, String)> _rows = <(String, String)>[
    ('executions', 'Runs this month'),
    ('actions', 'Actions this month'),
    ('webhookEvents', 'Webhook requests this month'),
    ('automations', 'Automations'),
    ('webhooks', 'Webhooks'),
    ('connections', 'Connections'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final CloudSession cloud = context.read<CloudSession>();
    if (!cloud.signedIn) return;
    try {
      final Json u = await cloud.usage();
      if (mounted) setState(() {
        _u = u;
        _error = null;
      });
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final CloudSession cloud = context.watch<CloudSession>();
    final TextTheme t = Theme.of(context).textTheme;
    final Json? u = _u;
    return Scaffold(
      appBar: AppBar(title: const Text('USAGE')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.all(AutometaSpacing.page(context)), children: <Widget>[
          if (!cloud.signedIn)
            EmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Sign in to Autometa Cloud',
              message: 'Usage is counted for Cloud automations. On-device runs are not metered.',
              action: PrimaryAction(
                label: 'Cloud account',
                icon: Icons.cloud_outlined,
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CloudAccountScreen())),
              ),
            )
          else if (_error != null)
            EmptyState(icon: Icons.error_outline, title: 'Could not load usage', message: _error!)
          else if (u == null)
            const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
          else ...<Widget>[
            Text('${str(u['planName'])} plan · ${str(u['month'])}', style: t.titleMedium),
            const SizedBox(height: 12),
            for (final (String key, String label) in _rows) _meter(context, label, asMap(u[key])),
            if (asMap(u['logRows'])['historyDays'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Run history is kept for ${asMap(u['logRows'])['historyDays']} days.', style: t.bodySmall),
              ),
          ],
        ]),
      ),
    );
  }

  Widget _meter(BuildContext context, String label, Json m) {
    final num used = (m['used'] as num?) ?? 0;
    final num? limit = m['limit'] as num?;
    final double? frac = limit == null || limit <= 0 ? null : (used / limit).clamp(0, 1).toDouble();
    final Color color = frac == null || frac < 0.8
        ? AutometaColors.accent
        : frac < 1
            ? AutometaColors.warning
            : AutometaColors.danger;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Expanded(child: Text(label)),
            Text(limit == null ? '$used' : '$used / $limit', style: Theme.of(context).textTheme.titleSmall),
          ]),
          if (frac != null) ...<Widget>[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: frac, color: color, minHeight: 6, borderRadius: BorderRadius.circular(3)),
          ],
        ]),
      ),
    );
  }
}
