import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../cloud/cloud_session.dart';
import '../core/theme/autometa_theme.dart';
import '../core/theme/design_tokens.dart';
import '../services/settings/settings_service.dart';
import '../state/app_state.dart';
import 'screens/activity_screen.dart';
import 'screens/automations_screen.dart';
import 'screens/cloud_account_screen.dart';
import 'screens/cloud_execution_screen.dart';
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
    context.read<AppServices>().notifications.onTap = _openPayload;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<CloudSession>().checkAlerts();
    });
  }

  /// Deep links from Cloud alerts: open the failed run or the reconnect screen.
  void _openPayload(String? payload) {
    if (!mounted || payload == null) return;
    final NavigatorState nav = Navigator.of(context);
    if (payload.startsWith('cloudexec:')) {
      nav.push(MaterialPageRoute<void>(builder: (_) => CloudExecutionScreen(executionId: payload.substring(10))));
    } else if (payload.startsWith('cloudreconnect:')) {
      nav.push(MaterialPageRoute<void>(builder: (_) => const CloudAccountScreen()));
    } else if (payload.startsWith('cloud:')) {
      select(3);
    }
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
      context.read<CloudSession>().checkAlerts();
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
    (Icons.add, Icons.add, 'Create'),
    (Icons.history, Icons.history, 'Activity'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
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
    final bool isCreate = i == 2;
    final Color color = selected || isCreate ? AutometaColors.accent : Theme.of(context).colorScheme.onSurfaceVariant;
    final Widget glyph = isCreate
        ? Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AutometaColors.accentDeep,
              border: Border.all(color: AutometaColors.accent.withValues(alpha: 0.5)),
              boxShadow: <BoxShadow>[
                BoxShadow(color: AutometaColors.accent.withValues(alpha: 0.25), blurRadius: 12),
              ],
            ),
            child: Icon(Icons.add, size: 20, color: color),
          )
        : AnimatedContainer(
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
