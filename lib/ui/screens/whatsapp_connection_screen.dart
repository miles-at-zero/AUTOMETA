import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../services/connections/connection_manager.dart';
import '../../services/connections/connection_state.dart';
import '../../services/integrations/whatsapp/whatsapp_models.dart';
import 'package:whatsapp_auto_send/whatsapp_auto_send.dart';
import '../widgets/autometa_widgets.dart';
import 'connections_screen.dart';

/// WhatsApp connection (spec §3, §4).
class WhatsAppConnectionScreen extends StatefulWidget {
  const WhatsAppConnectionScreen({super.key});

  @override
  State<WhatsAppConnectionScreen> createState() => _WhatsAppConnectionScreenState();
}

class _WhatsAppConnectionScreenState extends State<WhatsAppConnectionScreen> with WidgetsBindingObserver {
  WhatsAppAccountType? _choice;
  AutoSendServiceStatus? _auto;
  final TextEditingController _phoneId = TextEditingController();
  final TextEditingController _token = TextEditingController();
  final TextEditingController _version = TextEditingController(text: WhatsAppBusinessConfig.defaultApiVersion);
  bool _busy = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Android's Accessibility settings: re-check.
    if (state == AppLifecycleState.resumed) _refreshAuto();
  }

  Future<void> _refreshAuto() async {
    final AppServices s = context.read<AppServices>();
    final AutoSendServiceStatus st = await s.whatsapp.personalAdapter.autoSendStatus();
    if (!mounted) return;
    setState(() => _auto = st);
    await s.connections.refresh(IntegrationIds.whatsapp);
  }

  Future<void> _enableAutoSend() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Turn on WhatsApp auto-send?'),
        content: const SingleChildScrollView(
          child: Text(
            'AUTOMETA will open the chat and press Send for you when an automation runs.\n\n'
            '• It only works inside WhatsApp and only while an automation is sending.\n'
            '• It does not read, store or upload your chats.\n'
            '• The phone must be unlocked, or have no screen lock (it can wake the screen).\n'
            '• WhatsApp does not officially support automation. Sending a few personal messages '
            'is low risk, but bulk or spam-like sending can get an account banned.\n\n'
            'Next: in Accessibility settings, open "Installed apps" (or "Downloaded apps"), tap '
            '"AUTOMETA WhatsApp auto-send" and switch it on. On Android 13+ you may first need to '
            'open App info → ⋮ → "Allow restricted settings".',
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open settings')),
        ],
      ),
    );
    if (ok == true) await const WhatsAppAutoSend().openSettings();
  }

  Widget _autoSendPanel(BuildContext context) {
    final AutoSendServiceStatus? a = _auto;
    final bool ready = a?.ready ?? false;
    final String state = a == null
        ? 'Checking…'
        : a.whatsappPackage == null
            ? 'WhatsApp is not installed'
            : ready
                ? 'On: automations set to "Send message" send by themselves'
                : a.enabled
                    ? 'Switched on but not running yet. Toggle it off and on in Accessibility settings.'
                    : 'Off: you approve and tap Send for each message';
    return Panel(
      glow: ready ? AutometaColors.success : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          StatusDot(ready ? AutometaColors.success : AutometaColors.warning),
          const SizedBox(width: 8),
          Expanded(child: Text('Auto-send from this phone', style: Theme.of(context).textTheme.titleMedium)),
        ]),
        const SizedBox(height: 6),
        Text(state),
        const SizedBox(height: 10),
        if (!ready)
          FilledButton.icon(
            onPressed: a?.whatsappPackage == null ? null : _enableAutoSend,
            icon: const Icon(Icons.bolt),
            label: const Text('Turn on auto-send'),
          )
        else
          OutlinedButton(
            onPressed: () => const WhatsAppAutoSend().openSettings(),
            child: const Text('Manage in Accessibility settings'),
          ),
      ]),
    );
  }

  static const List<String> _businessGuide = <String>[
    'Go to developers.facebook.com, log in with Facebook and create an app (type: Business).',
    'Add the "WhatsApp" product. Meta gives you a free test number, or add your own number. It must be a number NOT already on the WhatsApp app (e.g. a new SIM).',
    'In WhatsApp → API Setup, copy the "Phone number ID" into the field below.',
    'In Business Settings → System users, create a system user, give it your app and WhatsApp account, and generate a permanent token with whatsapp_business_messaging. Paste it below.',
    'Add each recipient (e.g. Dad) to Settings → Contacts in AUTOMETA with their full international number.',
    'Recipients who haven\'t messaged your business number in the last 24 hours can only get approved templates. Create one in WhatsApp Manager → Message templates and put its name in the WhatsApp block. Easiest: ask Dad to send your business number a message once a day.',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAuto();
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
    WidgetsBinding.instance.removeObserver(this);
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
                Text(
                  (_auto?.ready ?? false) ? 'On (from this phone)' : 'Off: turn on auto-send below',
                  style: TextStyle(color: (_auto?.ready ?? false) ? AutometaColors.success : AutometaColors.warning),
                ),
                const SizedBox(height: 6),
                StatusPill(
                  label: (_auto?.ready ?? false) ? 'Personal Account · Auto-send' : 'Personal Account · Approval required',
                  color: AutometaColors.secondary,
                ),
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
            body: 'Uses your normal WhatsApp on this phone. By default AUTOMETA opens the chat with the '
                'message ready and you tap Send. Turn on auto-send and AUTOMETA presses Send itself, as long as '
                'the phone is unlocked. No WhatsApp Web, no unofficial servers; your chats never leave the phone.',
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
          if (_choice == WhatsAppAccountType.personal) ...<Widget>[
            const SizedBox(height: AutometaSpacing.lg),
            _autoSendPanel(context),
          ],
          if (business) ...<Widget>[
            const SizedBox(height: AutometaSpacing.lg),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Setup guide (about 15 minutes, free)'),
              children: <Widget>[
                for (int i = 0; i < _businessGuide.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                    title: Text(_businessGuide[i]),
                  ),
              ],
            ),
            const SizedBox(height: AutometaSpacing.md),
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
