import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../data/repositories/recipient.dart';
import '../../domain/models/workflow.dart';
import '../../domain/onboarding/onboarding_state.dart';
import '../../services/settings/settings_service.dart';
import '../../services/templates/dad_reminders.dart';
import '../../services/templates/template_gallery.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';

/// First-run flow (onboarding v2). Three primary screens before Home:
///
///   Welcome → How Autometa works (WHEN / IF / DO) → Choose your first path
///
/// Optional follow-ups only when chosen: the template picker, and the Dad
/// reminders setup (one use case among several). Nothing here creates fake
/// data, asks for permissions, or requires an account. Every path ends in the
/// real app (create flow, real builder, Connections or Home).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Page { welcome, concept, path, templates, dad }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Page _page = _Page.welcome;
  bool _busy = false;

  void _go(_Page p) => setState(() => _page = p);

  void _back() => _go(switch (_page) {
        _Page.welcome || _Page.concept => _Page.welcome,
        _Page.path => _Page.concept,
        _Page.templates => _Page.path,
        _Page.dad => _Page.templates,
      });

  Future<void> _finish(OnboardingOutcome outcome, OnboardingIntent intent) async {
    setState(() => _busy = true);
    await context.read<SettingsService>().finishOnboarding(outcome, intent: intent);
    // The app root swaps this screen for the shell, which opens [intent].
  }

  /// Integrations are connected progressively: explain the need at the moment
  /// it arises and let the user connect now or later. Nothing is faked.
  static const Map<String, String> _needs = <String, String>{
    'email_alert': 'Gmail',
    'scheduled_message': 'Telegram',
  };

  Future<void> _pickTemplate(String id) async {
    final String? service = _needs[id];
    if (service == null) {
      return _finish(OnboardingOutcome.completed, OnboardingIntent.template(id));
    }
    final bool? connectNow = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AutometaSpacing.lg, 0, AutometaSpacing.lg, AutometaSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('You\'ll need to connect $service to use this automation.',
                  key: const Key('onboarding.needs.title'), style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: AutometaSpacing.sm),
              Text('You can open the template now and connect $service before you activate it. '
                  'Nothing runs until you review and activate.', style: Theme.of(ctx).textTheme.bodyMedium),
              const SizedBox(height: AutometaSpacing.lg),
              FilledButton(
                key: const Key('onboarding.needs.connect'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text('Connect $service'),
              ),
              const SizedBox(height: AutometaSpacing.sm),
              TextButton(
                key: const Key('onboarding.needs.later'),
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Do this later'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || connectNow == null) return; // dismissed: stay on the list
    await _finish(
      OnboardingOutcome.completed,
      connectNow ? const OnboardingIntent.connectApp() : OnboardingIntent.template(id),
    );
  }

  Future<void> _skip() => _finish(OnboardingOutcome.skipped, const OnboardingIntent.explore());

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (_page) {
      _Page.welcome => _Welcome(onContinue: () => _go(_Page.concept), onSkip: _skip),
      _Page.concept => _Concept(onContinue: () => _go(_Page.path), onSkip: _skip),
      _Page.path => _PathChoice(
          busy: _busy,
          onCreate: () => _finish(OnboardingOutcome.completed, const OnboardingIntent.createAutomation()),
          onTemplates: () => _go(_Page.templates),
          onConnect: () => _finish(OnboardingOutcome.completed, const OnboardingIntent.connectApp()),
          onExplore: () => _finish(OnboardingOutcome.completed, const OnboardingIntent.explore()),
        ),
      _Page.templates => _TemplatePicker(
          busy: _busy,
          onPick: _pickTemplate,
          onDad: () => _go(_Page.dad),
        ),
      _Page.dad => _DadSetup(
          onDone: () => _finish(OnboardingOutcome.completed, const OnboardingIntent.reviewAutomations()),
        ),
    };
    final int step = _Page.values.indexOf(_page).clamp(0, 2);
    return PopScope(
      canPop: _page == _Page.welcome,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.9, -1.1),
              radius: 1.3,
              colors: <Color>[AutometaColors.secondary.withValues(alpha: 0.16), Colors.transparent],
            ),
          ),
          child: SafeArea(
            child: Column(children: <Widget>[
              _TopBar(
                step: step,
                showBack: _page != _Page.welcome,
                onBack: _back,
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (Widget child, Animation<double> a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero).animate(a),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(key: ValueKey<_Page>(_page), child: body),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- chrome

class _TopBar extends StatelessWidget {
  const _TopBar({required this.step, required this.showBack, required this.onBack});
  final int step;
  final bool showBack;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: Row(children: <Widget>[
          SizedBox(
            width: 52,
            child: showBack
                ? IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: onBack)
                : null,
          ),
          const Spacer(),
          Semantics(
            label: 'Step ${step + 1} of 3',
            child: Row(children: <Widget>[
              for (int i = 0; i < 3; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == step ? 22 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: i <= step ? AutometaColors.accent : AutometaColors.darkBorderStrong,
                  ),
                ),
            ]),
          ),
          const Spacer(),
          const SizedBox(width: 52),
        ]),
      );
}

/// Scrollable content with the call-to-action pinned to the bottom.
class _Frame extends StatelessWidget {
  const _Frame({required this.children, this.primary, this.secondary});
  final List<Widget> children;
  final Widget? primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    final double pad = AutometaSpacing.page(context) + 8;
    return ResponsiveWidth(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Expanded(child: ListView(padding: EdgeInsets.fromLTRB(pad, 8, pad, 16), children: children)),
        if (primary != null || secondary != null)
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              if (primary != null) primary!,
              if (secondary != null) ...<Widget>[const SizedBox(height: 4), secondary!],
            ]),
          ),
      ]),
    );
  }
}

TextButton _skipButton(VoidCallback onSkip) =>
    TextButton(key: const Key('onboarding.skip'), onPressed: onSkip, child: const Text('Skip setup'));

// ---------------------------------------------------------------- 1. welcome

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onContinue, required this.onSkip});
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return _Frame(
      primary: PrimaryAction(key: const Key('onboarding.continue'), label: 'Continue', onPressed: onContinue),
      secondary: _skipButton(onSkip),
      children: <Widget>[
        const SizedBox(height: 48),
        Center(
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: <Color>[
                AutometaColors.accent.withValues(alpha: 0.18),
                AutometaColors.secondary.withValues(alpha: 0.18),
              ]),
              boxShadow: <BoxShadow>[BoxShadow(color: AutometaColors.accent.withValues(alpha: 0.22), blurRadius: 40)],
            ),
            child: const AutometaGlyph(size: 84),
          ),
        ),
        const SizedBox(height: AutometaSpacing.xl),
        Text('Welcome to Autometa', style: t.headlineLarge?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
        const SizedBox(height: AutometaSpacing.md),
        Text('Automate repetitive tasks across the apps and services you use.',
            style: t.bodyLarge, textAlign: TextAlign.center),
        const SizedBox(height: AutometaSpacing.xl),
        const Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _Chip(Icons.schedule, 'Schedules'),
            _Chip(Icons.mail_outline, 'Gmail'),
            _Chip(Icons.send_outlined, 'Telegram'),
            _Chip(Icons.webhook_outlined, 'Webhooks'),
            _Chip(Icons.chat_outlined, 'WhatsApp'),
          ],
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AutometaColors.darkBorderStrong),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Icon(icon, size: 16, color: AutometaColors.accent),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ]),
      );
}

// ---------------------------------------------------------------- 2. concept

class _Concept extends StatelessWidget {
  const _Concept({required this.onContinue, required this.onSkip});
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return _Frame(
      primary: PrimaryAction(key: const Key('onboarding.continue'), label: 'Continue', onPressed: onContinue),
      secondary: _skipButton(onSkip),
      children: <Widget>[
        Text('How Autometa works', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AutometaSpacing.sm),
        Text('Every automation is three simple parts.', style: t.bodyMedium),
        const SizedBox(height: AutometaSpacing.lg),
        const _Stage(word: 'WHEN', text: 'something happens', example: 'Every day at 09:00 · a new email · a webhook', color: AutometaColors.accent, icon: Icons.bolt),
        const _Arrow(),
        const _Stage(word: 'IF', text: 'a condition is true', example: 'Subject contains "invoice" · it\'s a weekday', color: AutometaColors.secondary, icon: Icons.call_split, optional: true),
        const _Arrow(),
        const _Stage(word: 'DO', text: 'something automatically', example: 'Notify you · send an email or Telegram message', color: AutometaColors.success, icon: Icons.play_arrow_rounded),
        const SizedBox(height: AutometaSpacing.xl),
        Text('For example', style: t.labelLarge),
        const SizedBox(height: AutometaSpacing.sm),
        const _Example(Icons.alarm, 'Schedule a reminder'),
        const _Example(Icons.mail_outline, 'Send an email when something happens'),
        const _Example(Icons.send_outlined, 'Send a Telegram message'),
        const _Example(Icons.webhook_outlined, 'Trigger a webhook'),
        const _Example(Icons.chat_outlined, 'Prepare a WhatsApp message for you to send'),
      ],
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage({required this.word, required this.text, required this.example, required this.color, required this.icon, this.optional = false});
  final String word;
  final String text;
  final String example;
  final Color color;
  final IconData icon;
  final bool optional;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return Panel(
      glow: color,
      child: Row(children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: color.withValues(alpha: 0.14)),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text.rich(TextSpan(children: <InlineSpan>[
              TextSpan(text: '$word ', style: t.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w800, letterSpacing: 1)),
              TextSpan(text: text, style: t.titleMedium),
              if (optional) TextSpan(text: '  optional', style: t.labelSmall),
            ])),
            const SizedBox(height: 2),
            Text(example, style: t.bodySmall),
          ]),
        ),
      ]),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Icon(Icons.arrow_downward_rounded, size: 18, color: AutometaColors.darkBorderStrong),
      );
}

class _Example extends StatelessWidget {
  const _Example(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: <Widget>[
          Icon(icon, size: 18, color: AutometaColors.accent),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ]),
      );
}

// ---------------------------------------------------------------- 3. path

class _PathChoice extends StatelessWidget {
  const _PathChoice({required this.busy, required this.onCreate, required this.onTemplates, required this.onConnect, required this.onExplore});
  final bool busy;
  final VoidCallback onCreate;
  final VoidCallback onTemplates;
  final VoidCallback onConnect;
  final VoidCallback onExplore;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return _Frame(children: <Widget>[
      Text('Choose your first step', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: AutometaSpacing.sm),
      Text('You can do any of these later from the app.', style: t.bodyMedium),
      const SizedBox(height: AutometaSpacing.lg),
      _ChoiceCard(key: const Key('onboarding.path.create'), icon: Icons.add_circle_outline, color: AutometaColors.accent,
          title: 'Create an automation', text: 'Build a workflow from scratch.', onTap: busy ? null : onCreate),
      _ChoiceCard(key: const Key('onboarding.path.templates'), icon: Icons.dashboard_customize_outlined, color: AutometaColors.secondary,
          title: 'Start from a template', text: 'Use a ready-made automation and customize it.', onTap: busy ? null : onTemplates),
      _ChoiceCard(key: const Key('onboarding.path.connect'), icon: Icons.hub_outlined, color: AutometaColors.success,
          title: 'Connect an app', text: 'Connect a service you want Autometa to work with.', onTap: busy ? null : onConnect),
      _ChoiceCard(key: const Key('onboarding.path.explore'), icon: Icons.explore_outlined, color: AutometaColors.neutral,
          title: 'Explore first', text: 'Go straight to Autometa and set things up later.', onTap: busy ? null : onExplore),
    ]);
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.icon, required this.color, required this.title, required this.text, required this.onTap, this.badge, super.key});
  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final VoidCallback? onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AutometaSpacing.md),
      child: Panel(
        onTap: onTap,
        child: Row(children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: color.withValues(alpha: 0.14)),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(title, style: t.titleMedium),
              const SizedBox(height: 2),
              Text(text, style: t.bodySmall),
              if (badge != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(badge!, style: t.labelSmall?.copyWith(color: AutometaColors.warning)),
              ],
            ]),
          ),
          const Icon(Icons.chevron_right),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- templates

class _TemplatePicker extends StatelessWidget {
  const _TemplatePicker({required this.busy, required this.onPick, required this.onDad});
  final bool busy;
  final ValueChanged<String> onPick;
  final VoidCallback onDad;

  /// Curated V1 starting points; the full gallery is in New automation.
  static const List<(String, IconData, String?)> picks = <(String, IconData, String?)>[
    ('daily_reminder', Icons.alarm, null),
    ('email_alert', Icons.mail_outline, 'Needs Gmail'),
    ('scheduled_message', Icons.send_outlined, 'Needs your Telegram bot'),
  ];

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return _Frame(children: <Widget>[
      Text('Start from a template', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: AutometaSpacing.sm),
      Text('Pick one to open it in the builder. Nothing runs until you review and activate it.', style: t.bodyMedium),
      const SizedBox(height: AutometaSpacing.lg),
      for (final (String id, IconData icon, String? needs) in picks)
        _ChoiceCard(
          key: Key('onboarding.template.$id'),
          icon: icon,
          color: AutometaColors.accent,
          title: TemplateGallery.byId(id)!.name,
          text: TemplateGallery.byId(id)!.blurb,
          badge: needs,
          onTap: busy ? null : () => onPick(id),
        ),
      const SizedBox(height: AutometaSpacing.sm),
      const SectionLabel('FAMILY & PERSONAL'),
      _ChoiceCard(
        key: const Key('onboarding.template.dad'),
        icon: Icons.favorite_outline,
        color: AutometaColors.secondary,
        title: 'Dad reminders',
        text: 'Morning, evening and night messages for someone you care about.',
        onTap: busy ? null : onDad,
      ),
    ]);
  }
}

// ---------------------------------------------------------------- dad setup

class _DadSetup extends StatefulWidget {
  const _DadSetup({required this.onDone});
  final Future<void> Function() onDone;

  @override
  State<_DadSetup> createState() => _DadSetupState();
}

class _DadSetupState extends State<_DadSetup> {
  final TextEditingController _name = TextEditingController(text: 'Dad');
  final TextEditingController _phone = TextEditingController();
  bool _business = false;
  bool _busy = false;
  final Map<String, String?> _times = <String, String?>{
    for (final String id in DadReminders.templateIds) id: DadReminders.defaultTime(id),
  };

  static const Map<String, String> _labels = <String, String>{
    'morning_dad': 'Morning',
    'evening_dad': 'Evening',
    'night_dad': 'Night',
  };

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _pickTime(String id) async {
    final List<String> hm = (_times[id] ?? DadReminders.defaultTime(id)).split(':');
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(hm[0]), minute: int.parse(hm[1])),
    );
    if (picked != null) {
      setState(() => _times[id] = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    final AppServices s = context.read<AppServices>();
    final AppState state = context.read<AppState>();
    final String name = _name.text.trim().isEmpty ? 'Dad' : _name.text.trim();
    await s.settings.setDefaultRecipient(name);
    if (_phone.text.trim().isNotEmpty) {
      await s.contacts.save(Recipient(id: 'contact-${name.toLowerCase()}', alias: name, displayName: name, phoneE164: _phone.text.trim()));
    }
    final List<Workflow> drafts = DadReminders.buildDrafts(
      times: <String, String>{
        for (final MapEntry<String, String?> e in _times.entries)
          if (e.value != null) e.key: e.value!,
      },
      recipient: name,
      business: _business,
      timeZone: s.settings.timeZone ?? 'UTC',
      defaultMode: s.settings.defaultExecution,
    );
    for (final Workflow w in drafts) {
      await state.save(w);
    }
    await widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final bool any = _times.values.any((String? v) => v != null);
    return _Frame(
      primary: PrimaryAction(
        key: const Key('onboarding.dad.create'),
        label: 'Create drafts',
        busy: _busy,
        onPressed: any && !_busy ? _create : null,
      ),
      children: <Widget>[
        Text('Dad reminders', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AutometaSpacing.sm),
        Text('Created as drafts. You review each one before it goes live.', style: t.bodyMedium),
        const SizedBox(height: AutometaSpacing.lg),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Who are they for?')),
        const SizedBox(height: AutometaSpacing.md),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Their WhatsApp number (optional)',
            helperText: 'With country code. Stored only on this phone under Contacts.',
          ),
        ),
        const SizedBox(height: AutometaSpacing.lg),
        const SectionLabel('HOW SHOULD MESSAGES BE SENT?'),
        RadioListTile<bool>(
          key: const Key('onboarding.dad.personal'),
          contentPadding: EdgeInsets.zero,
          value: false,
          groupValue: _business,
          onChanged: (bool? v) => setState(() => _business = v ?? false),
          title: const Text('Personal WhatsApp: you tap Send'),
          subtitle: const Text('Autometa prepares the message and opens WhatsApp at the right time. You press Send yourself. '
              'Autometa never sends from your personal WhatsApp. Runs on this device.'),
        ),
        RadioListTile<bool>(
          key: const Key('onboarding.dad.business'),
          contentPadding: EdgeInsets.zero,
          value: true,
          groupValue: _business,
          onChanged: (bool? v) => setState(() => _business = v ?? false),
          title: const Text('WhatsApp Business (official API)'),
          subtitle: const Text('Sends automatically through the official WhatsApp Business Platform. '
              'Needs a WhatsApp Business connection before you can activate. Cloud ⭐ recommended.'),
        ),
        const SizedBox(height: AutometaSpacing.md),
        const SectionLabel('REMINDERS'),
        for (final String id in DadReminders.templateIds)
          CheckboxListTile(
            key: Key('onboarding.dad.$id'),
            contentPadding: EdgeInsets.zero,
            value: _times[id] != null,
            onChanged: (bool? v) => setState(() => _times[id] = v == true ? DadReminders.defaultTime(id) : null),
            title: Text(_labels[id]!),
            subtitle: Text(_times[id] == null ? 'Off' : Formatters.humanize24(_times[id]!)),
            secondary: IconButton(
              tooltip: 'Change time',
              icon: const Icon(Icons.schedule),
              onPressed: _times[id] == null ? null : () => _pickTime(id),
            ),
          ),
        const SizedBox(height: AutometaSpacing.sm),
        Text('You can edit the messages, times and where they run in the builder.', style: t.bodySmall),
      ],
    );
  }
}
