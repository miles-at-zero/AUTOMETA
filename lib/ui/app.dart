import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../cloud/cloud_session.dart';
import '../cloud/push_routing.dart';
import '../core/theme/autometa_theme.dart';
import '../services/settings/settings_service.dart';
import '../state/app_state.dart';
import '../domain/capabilities/execution_capabilities.dart';
import '../domain/models/workflow.dart';
import '../domain/notifications/notification_center.dart';
import '../domain/onboarding/onboarding_state.dart';
import '../services/templates/template_gallery.dart';
import 'guardian_scope.dart';
import 'screens/activity_screen.dart';
import 'screens/builder_screen.dart';
import 'screens/automations_screen.dart';
import 'screens/cloud_account_screen.dart';
import 'screens/cloud_execution_screen.dart';
import 'screens/connections_hub_screen.dart';
import 'screens/control_room_screen.dart';
import 'screens/create_screen.dart';
import 'screens/notification_center_screen.dart';
import 'screens/onboarding_screen.dart';
import 'widgets/floating_nav_dock.dart';

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

/// Navigation shell: Control Room · Automations · Activity · Connections.
///
/// The destinations live in a floating capsule dock; the Guardian Notification
/// Center opens from the bell at the end of the same capsule. A "New
/// automation" FAB sits on the Control Room and Automations. Settings opens
/// from the Connections app bar.
///
/// One Guardian pass runs here ([GuardianInboxController]) and is shared with
/// everything below through [GuardianScope], so the dock badge, the dashboard
/// panel and the inbox can never disagree.
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

  /// The single Guardian pass shared by the dock badge, the Control Room and
  /// the Notification Center.
  final GuardianInboxController _inbox = GuardianInboxController();

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

  /// True once the first Guardian pass has been kicked off.
  bool _inboxRequested = false;

  /// Runs the first pass only after the app has finished its own initial
  /// database load. Competing with that load for the SQLite lock makes
  /// sqflite's busy-wait arm a Timer, which a widget test can then catch as a
  /// pending timer it never got to run.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppState state = context.watch<AppState>();
    if (!_inboxRequested && !state.isLoading) {
      _inboxRequested = true;
      unawaited(_loadInbox());
    }
  }

  /// Runs the shared Guardian pass and folds it into the inbox.
  Future<void> _loadInbox() async {
    final SettingsService settings = context.read<SettingsService>();
    await _inbox.load(context, settings);
    if (mounted) setState(() {});
  }

  /// Applies a user action (read / dismiss) from anywhere below the shell.
  void _updateInbox(NotificationCenter next) {
    setState(() => _inbox.center = next);
    unawaited(_inbox.persist(context.read<SettingsService>()));
  }

  Future<void> _openNotifications() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const NotificationCenterScreen()),
    );
    if (mounted) await _loadInbox();
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
        unawaited(_openNotifications());
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
      unawaited(_loadInbox());
    }
  }

  void select(int index) => setState(() => _index = index);

  static const List<Widget> _pages = <Widget>[
    ControlRoomScreen(),
    AutomationsScreen(),
    ActivityScreen(),
    ConnectionsHubScreen(),
  ];

  /// The floating capsule dock's destinations.
  static const List<NavDockDestination> _destinations = <NavDockDestination>[
    NavDockDestination(
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard,
      label: 'Control Room',
      semanticLabel: 'Control Room, dashboard',
    ),
    NavDockDestination(
      icon: Icons.account_tree_outlined,
      selectedIcon: Icons.account_tree,
      label: 'Automations',
    ),
    NavDockDestination(icon: Icons.history, selectedIcon: Icons.history, label: 'Activity'),
    NavDockDestination(icon: Icons.hub_outlined, selectedIcon: Icons.hub, label: 'Connections'),
  ];

  @override
  Widget build(BuildContext context) => GuardianScope(
        controller: _inbox,
        onChanged: _updateInbox,
        onRefresh: _loadInbox,
        child: Scaffold(
          body: IndexedStack(index: _index, children: _pages),
          floatingActionButton: _index <= 1
              ? FloatingActionButton.extended(
                  heroTag: 'new-automation',
                  onPressed: () => AppShell.newAutomation(context),
                  icon: const Icon(Icons.add),
                  label: const Text('New automation'),
                )
              : null,
          bottomNavigationBar: FloatingNavDock(
            index: _index,
            onSelect: select,
            destinations: _destinations,
            unreadCount: _inbox.center.unreadCount,
            onOpenNotifications: _openNotifications,
          ),
        ),
      );
}
