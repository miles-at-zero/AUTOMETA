import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../widgets/autometa_widgets.dart';
import 'cloud_account_screen.dart';
import 'connections_screen.dart';
import 'contacts_screen.dart';
import 'settings_screen.dart';
import 'usage_screen.dart';
import 'webhooks_screen.dart';
import 'whatsapp_connection_screen.dart';

/// The Connections tab: one place for everything an automation connects to.
/// Cloud connections (Gmail, Telegram, WhatsApp Business) live on the server;
/// device integrations and contacts live on the phone. Settings is reachable
/// from the app bar.
class ConnectionsHubScreen extends StatelessWidget {
  const ConnectionsHubScreen({super.key});

  void _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final CloudSession cloud = context.watch<CloudSession>();
    final TextTheme t = Theme.of(context).textTheme;
    Widget tile(IconData icon, String title, String subtitle, Widget screen) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Panel(
            onTap: () => _push(context, screen),
            child: Row(children: <Widget>[
              Icon(icon, color: AutometaColors.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(title, style: t.titleMedium),
                  Text(subtitle, style: t.bodySmall),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: const Text('CONNECTIONS'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _push(context, const SettingsScreen()),
          ),
        ],
      ),
      body: ListView(padding: EdgeInsets.all(AutometaSpacing.page(context)), children: <Widget>[
        const SectionLabel('AUTOMETA CLOUD'),
        tile(
          Icons.cloud_outlined,
          'Cloud connections',
          cloud.signedIn
              ? 'Signed in as ${cloud.email}. Gmail, Telegram and WhatsApp Business.'
              : 'Not signed in. Sign in to connect Gmail, Telegram and WhatsApp Business.',
          const CloudAccountScreen(),
        ),
        tile(Icons.webhook_outlined, 'Webhooks', 'Incoming webhook URLs, secrets and request history.', const WebhooksScreen()),
        tile(Icons.bar_chart_outlined, 'Usage', 'Cloud runs, actions and limits this month.', const UsageScreen()),
        const SizedBox(height: 8),
        const SectionLabel('ON THIS DEVICE'),
        tile(Icons.chat_outlined, 'WhatsApp', 'Personal WhatsApp (you tap Send) and WhatsApp Business on this phone.',
            const WhatsAppConnectionScreen()),
        tile(Icons.extension_outlined, 'Device integrations', 'Notifications, HTTP, AI and other on-device blocks.',
            const ConnectionsScreen()),
        tile(Icons.contacts_outlined, 'Contacts', 'Names your automations send to. Numbers stay on this phone.',
            const ContactsScreen()),
      ]),
    );
  }
}
