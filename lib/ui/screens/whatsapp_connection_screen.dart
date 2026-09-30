import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../services/connections/connection_manager.dart';
import '../../services/connections/connection_state.dart';
import '../../services/integrations/whatsapp/whatsapp_models.dart';
import '../widgets/autometa_widgets.dart';
import 'connections_screen.dart';

/// WhatsApp connection (spec §3, §4).
class WhatsAppConnectionScreen extends StatefulWidget {
  const WhatsAppConnectionScreen({super.key});

  @override
  State<WhatsAppConnectionScreen> createState() => _WhatsAppConnectionScreenState();
}

class _WhatsAppConnectionScreenState extends State<WhatsAppConnectionScreen> {
  WhatsAppAccountType? _choice;
  final TextEditingController _phoneId = TextEditingController();
  final TextEditingController _token = TextEditingController();
  final TextEditingController _version = TextEditingController(text: WhatsAppBusinessConfig.defaultApiVersion);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final AppServices s = context.read<AppServices>();
    s.whatsapp.activeType().then((WhatsAppAccountType? t) {
      if (mounted) setState(() => _choice = t);
    });
    s.settings.repository.get('whatsapp.business.phone_number_id').then((String? v) => _phoneId.text = v ?? '');
    s.settings.repository.get('whatsapp.business.api_version').then((String? v) {
      if (v != null && v.isNotEmpty) _version.text = v;
    });
  }

  @override
  void dispose() {
    _phoneId.dispose();
    _token.dispose();
    _version.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final AppServices s = context.read<AppServices>();
    setState(() => _busy = true);
    try {
      if (_choice == WhatsAppAccountType.personal) {
        await s.whatsapp.selectType(WhatsAppAccountType.personal);
        await s.connections.refresh(IntegrationIds.whatsapp);
      } else if (_choice == WhatsAppAccountType.business) {
        await s.saveWhatsAppBusinessConfig(
          phoneNumberId: _phoneId.text,
          accessToken: _token.text,
          apiVersion: _version.text,
        );
        _token.clear();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ConnectionRecord? r = context.watch<ConnectionManager>().whatsapp;
    final ConnectionStatus status = r?.status ?? ConnectionStatus.notConnected;
    final bool business = _choice == WhatsAppAccountType.business;
    return Scaffold(
      appBar: AppBar(title: Text(business ? 'WhatsApp Business' : 'WhatsApp')),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          Panel(
            glow: connectionColor(status),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Row(children: <Widget>[
                StatusDot(connectionColor(status)),
                const SizedBox(width: 8),
                Text(status.label, style: Theme.of(context).textTheme.titleMedium),
              ]),
              if (r?.accountType != null) LabeledValue(label: 'Account', value: r!.accountType == 'business' ? 'Business' : 'Personal'),
              if ((r?.capabilities ?? <String>[]).isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                const Text('Capabilities:'),
                for (final String c in r!.capabilities) Text('✓ $c'),
              ],
              if (r?.accountType == 'personal') ...<Widget>[
                const SizedBox(height: 8),
                const Text('Automatic sending:'),
                const Text('Not available for this account type', style: TextStyle(color: AutometaColors.warning)),
                const SizedBox(height: 6),
                const StatusPill(label: 'Personal Account · Approval required', color: AutometaColors.secondary),
              ],
              for (final String l in r?.limitations ?? <String>[])
                Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $l', style: Theme.of(context).textTheme.bodySmall)),
            ]),
          ),
          const SizedBox(height: AutometaSpacing.xl),
          const SectionLabel('Connection type'),
          _TypeOption(
            selected: _choice == WhatsAppAccountType.personal,
            title: 'Personal Account',
            body: 'Uses the WhatsApp app on this phone through the official click-to-chat link. AUTOMETA '
                'prepares the message and opens the conversation — you tap Send. No automatic sending, no '
                'WhatsApp Web automation, no unofficial APIs. AUTOMETA cannot confirm delivery.',
            onTap: () => setState(() => _choice = WhatsAppAccountType.personal),
          ),
          const SizedBox(height: AutometaSpacing.md),
          _TypeOption(
            selected: business,
            title: 'Business Account',
            body: 'Uses Meta\'s official WhatsApp Business Platform (Cloud API). Can send automatically and '
                'report acceptance. Requires a Meta developer app, business verification, a registered phone '
                'number, a system-user access token, and approved templates for messages sent outside the '
                '24-hour customer-service window.',
            onTap: () => setState(() => _choice = WhatsAppAccountType.business),
          ),
          if (business) ...<Widget>[
            const SizedBox(height: AutometaSpacing.lg),
            TextField(controller: _phoneId, decoration: const InputDecoration(labelText: 'Phone Number ID')),
            const SizedBox(height: AutometaSpacing.md),
            TextField(
              controller: _token,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'System user access token',
                helperText: 'Stored in Android secure storage. Leave blank to keep the saved token.',
              ),
            ),
            const SizedBox(height: AutometaSpacing.md),
            TextField(controller: _version, decoration: const InputDecoration(labelText: 'Graph API version', helperText: 'Meta retires versions ~2 years after release')),
          ],
          const SizedBox(height: AutometaSpacing.xl),
          PrimaryAction(
            label: status.isUsable ? 'Update connection' : 'Connect',
            busy: _busy,
            onPressed: _choice == null ? null : _connect,
          ),
          if (r != null && status != ConnectionStatus.notConnected)
            TextButton(
              onPressed: () async {
                await context.read<ConnectionManager>().disconnect(IntegrationIds.whatsapp);
                if (mounted) setState(() => _choice = null);
              },
              child: const Text('Disconnect'),
            ),
        ],
      ),
    );
  }
}

class _TypeOption extends StatelessWidget {
  const _TypeOption({required this.selected, required this.title, required this.body, required this.onTap});
  final bool selected;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Panel(
        onTap: onTap,
        borderColor: selected ? AutometaColors.accent : null,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: selected ? AutometaColors.accent : null),
          const SizedBox(width: AutometaSpacing.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(body, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      );
}
