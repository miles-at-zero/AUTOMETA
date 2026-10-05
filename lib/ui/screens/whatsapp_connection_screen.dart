import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../services/connections/connection_manager.dart';
import '../../services/connections/connection_state.dart';
import '../../services/integrations/integration.dart';
import '../../services/integrations/whatsapp/whatsapp_models.dart';
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
  final TextEditingController _phoneId = TextEditingController();
  final TextEditingController _token = TextEditingController();
  final TextEditingController _version = TextEditingController(text: WhatsAppBusinessConfig.defaultApiVersion);
  bool _busy = false;

  Future<void> _refreshAuto() async {
    await context.read<AppServices>().connections.refresh(IntegrationIds.whatsapp);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAuto();
  }

  Widget _personalPanel(BuildContext context) {
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('How personal WhatsApp works', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text(
          'When an automation runs, Autometa prepares the message and opens the chat in WhatsApp with it '
          'filled in. You tap Send. Autometa never sends from your personal WhatsApp by itself.\n\n'
          'Need fully automatic sending? Use the official WhatsApp Business API (below), on this phone or in Cloud.',
        ),
      ]),
    );
  }

  int _wizardStep = 0;
  String? _testResult;
  bool _businessOk = false;

  static const List<(String, String)> _wizard = <(String, String)>[
    (
      'Create a Meta app',
      'Meta (Facebook\'s parent company) runs the official WhatsApp Business Platform. On a computer, go to '
          'developers.facebook.com, log in with Facebook, tap "My Apps" → "Create app", choose "Business". '
          'It\'s free.'
    ),
    (
      'Add WhatsApp to the app',
      'In your new app\'s dashboard, find "WhatsApp" and tap "Set up". Meta creates a WhatsApp Business '
          'Account for you and gives you a free test number you can use straight away.'
    ),
    (
      'Verify your business (optional at first)',
      'With the test number you can message up to 5 numbers you add as testers (add Dad\'s number there). '
          'To message anyone, verify your business in Business Settings → Security Centre. You can skip this for now.'
    ),
    (
      'Choose the sending number',
      'Use the test number, or add your own under WhatsApp → API Setup → "Add phone number". Your own number '
          'must NOT be in use on the WhatsApp app. Use a spare SIM. Then copy its "Phone number ID" (a long number '
          'shown under the phone number on the API Setup page; it is NOT the phone number itself).'
    ),
    (
      'Add an access token',
      'The token is the password that lets AUTOMETA send on your behalf. Quick test: copy the "Temporary access '
          'token" from API Setup (expires in 24 h). Permanent: Business Settings → Users → System users → Add → '
          'Generate token, tick whatsapp_business_messaging. It\'s stored in Android secure storage, never in '
          'automations or logs.'
    ),
    (
      'Test the connection',
      'AUTOMETA asks Meta whether this number and token work. Nothing is sent. Note: people who haven\'t '
          'messaged your business number in the last 24 h can only receive approved templates (create them in '
          'WhatsApp Manager → Message templates, then put the template name in the WhatsApp block).'
    ),
  ];

  Widget _businessWizard(BuildContext context, ConnectionStatus status) {
    final TextTheme text = Theme.of(context).textTheme;
    Widget body(int i) {
      final List<Widget> extra = <Widget>[];
      if (i == 3) {
        extra.add(TextField(
          controller: _phoneId,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Phone number ID', helperText: 'Digits only, e.g. 1069…'),
        ));
      } else if (i == 4) {
        extra.addAll(<Widget>[
          TextField(
            controller: _token,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Access token',
              helperText: 'Starts with "EAA". Leave blank to keep the saved one.',
            ),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Advanced', style: text.bodySmall),
            children: <Widget>[
              TextField(
                controller: _version,
                decoration: const InputDecoration(labelText: 'Graph API version', helperText: 'Leave as is unless Meta retires it'),
              ),
            ],
          ),
        ]);
      } else if (i == 5) {
        extra.addAll(<Widget>[
          PrimaryAction(
            label: 'Test connection',
            icon: Icons.wifi_tethering,
            busy: _busy,
            onPressed: () async {
              final AppServices s = context.read<AppServices>();
              setState(() => _busy = true);
              try {
                await s.saveWhatsAppBusinessConfig(
                  phoneNumberId: _phoneId.text,
                  accessToken: _token.text,
                  apiVersion: _version.text,
                );
                _token.clear();
                final IntegrationAvailability av = await s.whatsapp.businessAdapter.check();
                if (!mounted) return;
                setState(() {
                  _businessOk = av.status.isUsable;
                  _testResult = av.status.isUsable
                      ? '✓ Connected. AUTOMETA can send from this number. Pick "WhatsApp Business API" in a WhatsApp block to use it.'
                      : '✗ ${av.status.label}: ${av.limitations.join('; ')}';
                });
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
          ),
          if (_testResult != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_testResult!, style: TextStyle(color: _businessOk ? AutometaColors.success : AutometaColors.danger)),
          ],
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(_wizard[i].$2),
        if (i == 0)
          TextButton.icon(
            onPressed: () => launcher.launchUrl(Uri.parse('https://developers.facebook.com/apps'), mode: launcher.LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open developers.facebook.com'),
          ),
        if (extra.isNotEmpty) const SizedBox(height: 8),
        ...extra,
      ]);
    }

    bool canContinue(int i) => switch (i) {
          3 => _phoneId.text.trim().isNotEmpty,
          _ => true,
        };

    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('WhatsApp Business setup', style: text.titleMedium),
        Text('About 15 minutes. You\'ll need a computer for steps 1–5.', style: text.bodySmall),
        Stepper(
          physics: const NeverScrollableScrollPhysics(),
          margin: EdgeInsets.zero,
          currentStep: _wizardStep,
          onStepTapped: (int i) => setState(() => _wizardStep = i),
          onStepContinue: _wizardStep < _wizard.length - 1 && canContinue(_wizardStep)
              ? () {
                  setState(() => _wizardStep++);
                  context.read<AppServices>().settings.repository.setInt('whatsapp.business.wizard_step', _wizardStep);
                }
              : null,
          onStepCancel: _wizardStep > 0 ? () => setState(() => _wizardStep--) : null,
          controlsBuilder: (BuildContext c, ControlsDetails d) => _wizardStep == _wizard.length - 1
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: <Widget>[
                    FilledButton(onPressed: d.onStepContinue, child: Text(_wizardStep == 2 ? 'Skip / Continue' : 'Continue')),
                    if (d.onStepCancel != null) TextButton(onPressed: d.onStepCancel, child: const Text('Back')),
                  ]),
                ),
          steps: <Step>[
            for (int i = 0; i < _wizard.length; i++)
              Step(
                title: Text(_wizard[i].$1),
                content: body(i),
                isActive: i <= _wizardStep,
                state: i < _wizardStep
                    ? StepState.complete
                    : (i == _wizard.length - 1 && _businessOk ? StepState.complete : StepState.indexed),
              ),
          ],
        ),
      ]),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    context.read<AppServices>().settings.repository.get('whatsapp.business.wizard_step').then((String? v) {
      final int? n = int.tryParse(v ?? '');
      if (n != null && mounted) setState(() => _wizardStep = n.clamp(0, _wizard.length - 1));
    });
    _phoneId.addListener(() {
      if (mounted) setState(() {});
    });
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
                const Text('Sending: you tap Send in WhatsApp'),
                const SizedBox(height: 6),
                StatusPill(
                  label: 'Personal Account · You tap Send',
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
            body: 'Uses your normal WhatsApp on this phone. Autometa prepares the message and opens the chat '
                'with it filled in; you tap Send. Autometa never sends from personal WhatsApp by itself. '
                'No WhatsApp Web, no unofficial servers; your chats never leave the phone.',
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
            _personalPanel(context),
          ],
          if (business) ...<Widget>[
            const SizedBox(height: AutometaSpacing.lg),
            _businessWizard(context, status),
          ],
          const SizedBox(height: AutometaSpacing.xl),
          if (!business)
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
