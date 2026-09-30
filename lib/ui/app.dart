import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/theme/autometa_theme.dart';
import '../core/theme/design_tokens.dart';
import '../services/settings/settings_service.dart';
import '../state/app_state.dart';
import 'screens/activity_screen.dart';
import 'screens/automations_screen.dart';
import 'screens/create_screen.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/settings_screen.dart';

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

/// Bottom-navigation shell: Home · Automations · Create · Activity · Settings.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  static void goTo(BuildContext context, int index) =>
      context.findAncestorStateOfType<_AppShellState>()?.select(index);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
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
    }
  }

  void select(int index) => setState(() => _index = index);

  static const List<Widget> _pages = <Widget>[
    HomeScreen(),
    AutomationsScreen(),
    CreateScreen(),
    ActivityScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: _index, children: _pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: select,
          destinations: <Widget>[
            const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
            const NavigationDestination(icon: Icon(Icons.account_tree_outlined), selectedIcon: Icon(Icons.account_tree), label: 'Automations'),
            NavigationDestination(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AutometaColors.accentDeep,
                  border: Border.all(color: AutometaColors.accent.withValues(alpha: 0.5)),
                  boxShadow: <BoxShadow>[
                    BoxShadow(color: AutometaColors.accent.withValues(alpha: 0.25), blurRadius: 14),
                  ],
                ),
                child: const Icon(Icons.add, color: AutometaColors.accent),
              ),
              label: 'Create',
            ),
            const NavigationDestination(icon: Icon(Icons.history), label: 'Activity'),
            const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      );
}
