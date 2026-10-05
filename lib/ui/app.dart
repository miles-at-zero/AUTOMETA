import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../cloud/cloud_session.dart';
import '../cloud/push_routing.dart';
import '../core/theme/autometa_theme.dart';
import '../core/theme/design_tokens.dart';
import '../services/settings/settings_service.dart';
import '../state/app_state.dart';
import '../domain/capabilities/execution_capabilities.dart';
import '../domain/models/workflow.dart';
import '../domain/onboarding/onboarding_state.dart';
import '../services/templates/template_gallery.dart';
import 'screens/activity_screen.dart';
import 'screens/builder_screen.dart';
import 'screens/automations_screen.dart';
import 'screens/cloud_account_screen.dart';
import 'screens/cloud_execution_screen.dart';
import 'screens/connections_hub_screen.dart';
import 'screens/create_screen.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';

/// Root widget.
class AutometaApp extends StatefulWidget {
  const AutometaApp({required this.services, super.key});

  final AppServices services;

  @override
  State<AutometaApp> createState() => _AutometaAppState();
}

class _AutometaAppState extends State<AutometaApp> {
  ThemeMode _mode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    widget.services.settings.repository.get('ui.theme_mode').then((String? v) {
      if (!mounted || v == null) return;
      setState(() => _mode = v == 'light' ? ThemeMode.light : ThemeMode.dark);
    });
  }

  void _setMode(ThemeMode mode) {
    setState(() => _mode = mode);
    widget.services.settings.repository.set('ui.theme_mode', mode == ThemeMode.light ? 'light' : 'dark');
  }

  @override
  Widget build(BuildContext context) {
    final SettingsService settings = context.watch<SettingsService>();
    return Provider<AppServices>.value(
      value: widget.services,
      child: ThemeController(
        mode: _mode,
        onChanged: _setMode,
        child: MaterialApp(
          title: 'AUTOMETA',
          debugShowCheckedModeBanner: false,
          theme: AutometaTheme.light,
          darkTheme: AutometaTheme.dark,
          themeMode: _mode,
          home: settings.onboardingComplete ? const AppShell() : const OnboardingScreen(),
        ),
      ),
    );
  }
}

/// Exposes the theme toggle to the settings screen.
class ThemeController extends InheritedWidget {
  const ThemeController({required this.mode, required this.onChanged, required super.child, super.key});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  static ThemeController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeController>()!;

  @override
  bool updateShouldNotify(ThemeController oldWidget) => oldWidget.mode != mode;
}

/// Bottom-navigation shell: Home · Automations · Activity · Connections, with
/// a "New automation" FAB on Home and Automations. Settings opens from the
/// Connections app bar.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  static void goTo(BuildContext context, int index) =>
      context.findAncestorStateOfType<_AppShellState>()?.select(index);

  /// Opens the create flow (templates, guided builder, blank automation).
  static Future<void> newAutomation(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CreateScreen()));

  static const int automationsTab = 1;
  static const int activityTab = 2;
  static const int connectionsTab = 3;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _navigation = _maybeNavigation();
    context.read<AppServices>().notifications.onTap =
        (String? payload) => (_navigation ?? (PendingNavigation()..attach(_open))).open(PushDestination.fromLocalPayload(payload));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The navigator now exists: consume a tap that launched the app.
      _navigation?.attach(_open);
      context.read<CloudSession>().checkAlerts();
      _openOnboardingIntent();
    });
  }

  /// Where the user chose to go at the end of onboarding: the real create
  /// flow, a template opened in the real builder, Connections or Automations.
  void _openOnboardingIntent() {
    final OnboardingIntent? intent = context.read<SettingsService>().takeOnboardingIntent();
    if (intent == null) return;
    switch (intent.kind) {
      case OnboardingIntentKind.explore:
        break;
      case OnboardingIntentKind.createAutomation:
        AppShell.newAutomation(context);
      case OnboardingIntentKind.connectApp:
        select(AppShell.connectionsTab);
      case OnboardingIntentKind.reviewAutomations:
        select(AppShell.automationsTab);
      case OnboardingIntentKind.template:
        final AutomationTemplate? t = TemplateGallery.byId(intent.templateId ?? '');
        if (t == null) return;
        final SettingsService settings = context.read<SettingsService>();
        Workflow w = t.instantiate(timeZone: settings.timeZone ?? 'UTC', recipient: settings.defaultRecipientName);
        // Same rule as every new automation: the user's default (Cloud) when
        // every block supports it, otherwise the mode that can run it.
        w = w.copyWith(executionMode: ExecutionCapabilities.bestModeFor(w, settings.defaultExecution));
        Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => BuilderScreen(initial: w, isPreview: true)));
    }
  }

  PendingNavigation? _navigation;

  PendingNavigation? _maybeNavigation() {
    try {
      return Provider.of<PendingNavigation>(context, listen: false);
    } on ProviderNotFoundException {
      return null; // Widget tests without push wiring.
    }
  }

  /// Deep links from Cloud alerts: open the run, or the reconnect screen.
  void _open(PushDestination d) {
    if (!mounted) return;
    final NavigatorState nav = Navigator.of(context);
    switch (d) {
      case OpenExecution(:final String executionId):
        nav.push(MaterialPageRoute<void>(builder: (_) => CloudExecutionScreen(executionId: executionId)));
      case OpenReconnect(:final String? connectionId):
        nav.push(MaterialPageRoute<void>(builder: (_) => CloudAccountScreen(reconnectConnectionId: connectionId)));
      case OpenNotifications():
        select(AppShell.activityTab);
    }
  }

  @override
  void dispose() {
    _navigation?.detach();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Background runs happen in a separate AlarmManager isolate, so the UI
  /// re-reads the database whenever it comes back to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<AppState>().refresh();
      context.read<SettingsService>().refreshPlatformState();
      context.read<CloudSession>().checkAlerts();
    }
  }

  void select(int index) => setState(() => _index = index);

  static const List<Widget> _pages = <Widget>[
    HomeScreen(),
    AutomationsScreen(),
    ActivityScreen(),
    ConnectionsHubScreen(),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: _index, children: _pages),
        floatingActionButton: _index <= 1
            ? FloatingActionButton.extended(
                heroTag: 'new-automation',
                onPressed: () => AppShell.newAutomation(context),
                icon: const Icon(Icons.add),
                label: const Text('New automation'),
              )
            : null,
        bottomNavigationBar: _AutometaNavBar(index: _index, onSelect: select),
      );
}


/// Bottom navigation whose labels always fit: each slot gets an equal share
/// of the width and its label scales down (never wraps or overflows), even
/// on narrow phones or with large system font sizes.
class _AutometaNavBar extends StatelessWidget {
  const _AutometaNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  static const List<(IconData, IconData, String)> _items = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.account_tree_outlined, Icons.account_tree, 'Automations'),
    (Icons.history, Icons.history, 'Activity'),
    (Icons.hub_outlined, Icons.hub, 'Connections'),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MediaQueryData mq = MediaQuery.of(context);
    return MediaQuery(
      // Cap text scaling inside the bar; content screens still honour it fully.
      data: mq.copyWith(textScaler: mq.textScaler.clamp(maxScaleFactor: 1.15)),
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 3,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 68,
            child: Row(
              children: <Widget>[
                for (int i = 0; i < _items.length; i++)
                  Expanded(child: _slot(context, i)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slot(BuildContext context, int i) {
    final (IconData icon, IconData selectedIcon, String label) = _items[i];
    final bool selected = i == index;
    final Color color = selected ? AutometaColors.accent : Theme.of(context).colorScheme.onSurfaceVariant;
    final Widget glyph = AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: selected ? AutometaColors.accent.withValues(alpha: 0.16) : Colors.transparent,
            ),
            child: Icon(selected ? selectedIcon : icon, size: 22, color: color),
          );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: () => onSelect(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              glyph,
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
