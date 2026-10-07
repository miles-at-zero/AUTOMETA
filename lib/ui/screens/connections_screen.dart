import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../services/connections/connection_manager.dart';
import '../../services/connections/connection_state.dart';
import '../../services/integrations/integration.dart';
import '../widgets/autometa_widgets.dart';
import 'ai_settings_screen.dart';
import 'whatsapp_connection_screen.dart';

Color connectionColor(ConnectionStatus s) => switch (s) {
      ConnectionStatus.connected => AutometaColors.success,
      ConnectionStatus.degraded => AutometaColors.accent,
      ConnectionStatus.error => AutometaColors.danger,
      ConnectionStatus.needsConfiguration || ConnectionStatus.pendingVerification => AutometaColors.warning,
      _ => AutometaColors.neutral,
    };

/// CONNECTIONS (spec §30).
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ConnectionManager m = context.watch<ConnectionManager>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('CONNECTIONS'),
        actions: <Widget>[
          IconButton(icon: const Icon(Icons.refresh), onPressed: m.isRefreshing ? null : m.refreshAll),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          for (final Integration i in m.registry.all) ...<Widget>[
            _Card(integration: i, record: m.recordFor(i.id)),
            const SizedBox(height: AutometaSpacing.md),
          ],
          const SizedBox(height: AutometaSpacing.lg),
          const SectionLabel('Cloud only'),
          for (final PlannedIntegration p in m.planned.where((PlannedIntegration p) => p.availableInCloud))
            _PlannedTile(p),
          const SizedBox(height: AutometaSpacing.md),
          const SectionLabel('Coming soon'),
          for (final PlannedIntegration p in m.planned.where((PlannedIntegration p) => !p.availableInCloud))
            _PlannedTile(p),
        ],
      ),
    );
  }
}

/// Not clickable: there is nothing to open on this device yet.
class _PlannedTile extends StatelessWidget {
  const _PlannedTile(this.p);
  final PlannedIntegration p;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final bool cloud = p.availableInCloud;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AutometaSpacing.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(cloud ? Icons.cloud_outlined : Icons.schedule, size: 18,
              color: cloud ? AutometaColors.accent : AutometaColors.neutral),
        ),
        const SizedBox(width: AutometaSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(p.displayName, style: t.titleSmall),
            Text(cloud ? p.cloudNote! : p.blurb, style: t.bodySmall),
          ]),
        ),
        const SizedBox(width: AutometaSpacing.sm),
        StatusPill(
          label: cloud ? 'CLOUD ONLY' : 'COMING SOON',
          color: cloud ? AutometaColors.accent : AutometaColors.neutral,
        ),
      ]),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.integration, required this.record});
  final Integration integration;
  final ConnectionRecord? record;

  @override
  Widget build(BuildContext context) {
    final ConnectionStatus status = record?.status ?? ConnectionStatus.notConnected;
    final Color c = connectionColor(status);
    return Panel(
      onTap: () {
        final Widget? target = switch (integration.id) {
          IntegrationIds.whatsapp => const WhatsAppConnectionScreen(),
          IntegrationIds.ai => const AiSettingsScreen(),
          _ => null,
        };
        if (target != null) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => target));
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(integration.displayName, style: Theme.of(context).textTheme.titleMedium)),
          StatusDot(c),
          const SizedBox(width: 6),
          Text(status.label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: c)),
        ]),
        if ((record?.label ?? '').isNotEmpty) Text(record!.label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        for (final String cap in record?.capabilities ?? const <String>[])
          Row(children: <Widget>[
            const Icon(Icons.check, size: 14, color: AutometaColors.success),
            const SizedBox(width: 6),
            Expanded(child: Text(cap, style: Theme.of(context).textTheme.bodySmall)),
          ]),
        for (final String l in record?.limitations ?? const <String>[])
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Icon(Icons.info_outline, size: 14, color: AutometaColors.neutral),
            const SizedBox(width: 6),
            Expanded(child: Text(l, style: Theme.of(context).textTheme.bodySmall)),
          ]),
      ]),
    );
  }
}
