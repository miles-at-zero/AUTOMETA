import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../data/repositories/recipient.dart';
import '../../services/integrations/whatsapp/whatsapp_models.dart';
import '../../services/settings/settings_service.dart';
import '../../services/templates/template_gallery.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';

/// First-run flow: Welcome → connect → WhatsApp type → Morning Dad → others.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _page = 0;
  bool _wantWhatsApp = true;
  bool _wantAi = true;
  WhatsAppAccountType _type = WhatsAppAccountType.personal;
  final TextEditingController _recipient = TextEditingController(text: 'Dad');
  final TextEditingController _phone = TextEditingController();
  final Set<String> _enabled = <String>{};
  bool _busy = false;

  @override
  void dispose() {
    _recipient.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _next() => setState(() => _page++);

  Future<void> _enableStarter(String templateId) async {
    final AppState state = context.read<AppState>();
    final SettingsService settings = context.read<SettingsService>();
    final AutomationTemplate t = TemplateGallery.byId(templateId)!;
    setState(() => _busy = true);
    await state.instantiateTemplate(t,
        timeZone: settings.timeZone ?? 'UTC', recipient: _recipient.text.trim(), enable: true);
    setState(() {
      _enabled.add(templateId);
      _busy = false;
    });
  }

  Future<void> _saveRecipientAndType() async {
    final AppServices s = context.read<AppServices>();
    final String name = _recipient.text.trim().isEmpty ? 'Dad' : _recipient.text.trim();
    await s.settings.setDefaultRecipient(name);
    await s.contacts.save(Recipient(
      id: 'contact-${name.toLowerCase()}',
      alias: name,
      displayName: name,
      phoneE164: _phone.text.trim(),
    ));
    if (_wantWhatsApp && _type == WhatsAppAccountType.personal) {
      await s.whatsapp.selectType(WhatsAppAccountType.personal);
    }
    await s.notifications.ensurePermission();
  }

  Future<void> _finish() async {
    final AppServices s = context.read<AppServices>();
    await s.settings.setOnboardingComplete(true);
    await s.connections.refreshAll();
    await s.scheduler.syncAll();
  }

  Widget _frame({required List<Widget> children, required String cta, required VoidCallback? onCta, Widget? secondary}) =>
      SafeArea(
        child: Padding(
          padding: EdgeInsets.all(AutometaSpacing.page(context) + 8),
          child: ResponsiveWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              Expanded(child: ListView(children: children)),
              PrimaryAction(label: cta, onPressed: onCta, busy: _busy),
              if (secondary != null) secondary,
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Widget body = switch (_page) {
      0 => _frame(
          cta: 'Get Started',
          onCta: _next,
          children: <Widget>[
            const SizedBox(height: 80),
            const Center(child: AutometaGlyph(size: 96)),
            const SizedBox(height: AutometaSpacing.xl),
            Text('Welcome to AUTOMETA', style: text.displaySmall, textAlign: TextAlign.center),
            const SizedBox(height: AutometaSpacing.md),
            Text('Your personal automation command center.', style: text.bodyLarge, textAlign: TextAlign.center),
            const SizedBox(height: AutometaSpacing.sm),
            Text(AppInfo.tagline, style: text.labelMedium?.copyWith(color: AutometaColors.accent), textAlign: TextAlign.center),
          ],
        ),
      1 => _frame(
          cta: 'Continue',
          onCta: _next,
          children: <Widget>[
            Text('What do you want to connect?', style: text.headlineMedium),
            const SizedBox(height: AutometaSpacing.xl),
            CheckboxListTile(value: _wantWhatsApp, onChanged: (bool? v) => setState(() => _wantWhatsApp = v ?? false), title: const Text('WhatsApp')),
            CheckboxListTile(value: _wantAi, onChanged: (bool? v) => setState(() => _wantAi = v ?? false), title: const Text('AI'),
                subtitle: const Text('Starts with on-device templates; add an API key later in Settings.')),
          ],
        ),
      2 => _frame(
          cta: 'Continue',
          onCta: () async {
            setState(() => _busy = true);
            await _saveRecipientAndType();
            setState(() => _busy = false);
            _next();
          },
          children: <Widget>[
            Text('WhatsApp account type', style: text.headlineMedium),
            const SizedBox(height: AutometaSpacing.lg),
            RadioListTile<WhatsAppAccountType>(
              value: WhatsAppAccountType.personal,
              groupValue: _type,
              onChanged: (WhatsAppAccountType? v) => setState(() => _type = v!),
              title: const Text('Personal'),
              subtitle: const Text('AUTOMETA prepares the message and opens WhatsApp. You tap Send. Approval required.'),
            ),
            RadioListTile<WhatsAppAccountType>(
              value: WhatsAppAccountType.business,
              groupValue: _type,
              onChanged: (WhatsAppAccountType? v) => setState(() => _type = v!),
              title: const Text('Business'),
              subtitle: const Text('Official Cloud API. Configure the token later under Connections.'),
            ),
            const SizedBox(height: AutometaSpacing.xl),
            TextField(controller: _recipient, decoration: const InputDecoration(labelText: 'Recipient name')),
            const SizedBox(height: AutometaSpacing.md),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Their WhatsApp number (optional)', helperText: 'With country code. You can add it later.'),
            ),
          ],
        ),
      _ => _frame(
          cta: 'Finish',
          onCta: _finish,
          children: <Widget>[
            Text('Your first automations', style: text.headlineMedium),
            const SizedBox(height: AutometaSpacing.lg),
            for (final String id in <String>['morning_dad', 'evening_dad', 'night_dad'])
              if (id == 'morning_dad' || _enabled.contains('morning_dad'))
                Padding(
                  padding: const EdgeInsets.only(bottom: AutometaSpacing.md),
                  child: _StarterCard(
                    template: TemplateGallery.byId(id)!,
                    recipient: _recipient.text.trim(),
                    enabled: _enabled.contains(id),
                    onEnable: _busy ? null : () => _enableStarter(id),
                  ),
                ),
          ],
        ),
    };
    return Scaffold(body: AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: KeyedSubtree(key: ValueKey<int>(_page), child: body)));
  }
}

class _StarterCard extends StatelessWidget {
  const _StarterCard({required this.template, required this.recipient, required this.enabled, required this.onEnable});
  final AutomationTemplate template;
  final String recipient;
  final bool enabled;
  final VoidCallback? onEnable;

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> trigger = template.definition['trigger'] as Map<String, dynamic>;
    final List<dynamic> steps = template.definition['steps'] as List<dynamic>;
    final String message = '${(steps.first as Map<String, dynamic>)['message']}'.replaceAll('Dad', recipient.isEmpty ? 'Dad' : recipient);
    return Panel(
      glow: enabled ? AutometaColors.success : AutometaColors.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(template.name.replaceAll('Dad', recipient.isEmpty ? 'Dad' : recipient), style: Theme.of(context).textTheme.titleMedium),
        Text('${trigger['time']}', style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: AutometaColors.accent)),
        Text(message),
        const SizedBox(height: AutometaSpacing.md),
        enabled
            ? const StatusPill(label: 'Enabled', color: AutometaColors.success, icon: Icons.check, filled: true)
            : OutlinedButton(onPressed: onEnable, child: const Text('Enable')),
      ]),
    );
  }
}
