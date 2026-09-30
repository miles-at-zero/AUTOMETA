import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/logger.dart';
import '../../services/notifications/notification_service.dart';
import '../../services/scheduler/scheduler_service.dart';
import '../../services/settings/settings_service.dart';
import '../../state/app_state.dart';
import '../app.dart';
import '../widgets/autometa_widgets.dart';
import 'ai_settings_screen.dart';
import 'connections_screen.dart';
import 'contacts_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final SettingsService settings = context.watch<SettingsService>();
    final AppState state = context.read<AppState>();
    final NotificationPreferences prefs = settings.notificationPreferences;
    final ThemeController theme = ThemeController.of(context);

    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

    return Scaffold(
      appBar: AppBar(title: const Text('SETTINGS')),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          ResponsiveWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              Panel(
                glow: settings.isPaused ? AutometaColors.warning : null,
                borderColor: settings.isPaused ? AutometaColors.warning : null,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('PAUSE ALL AUTOMATIONS'),
                  subtitle: Text(settings.isPaused
                      ? 'AUTOMETA PAUSED — no automated actions will execute.'
                      : 'Stops every scheduled run until you resume.'),
                  value: settings.isPaused,
                  onChanged: (bool v) => state.setPaused(v),
                ),
              ),
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Setup'),
              Panel(
                padding: EdgeInsets.zero,
                child: Column(children: <Widget>[
                  ListTile(leading: const Icon(Icons.hub_outlined), title: const Text('Connections'), trailing: const Icon(Icons.chevron_right), onTap: () => push(const ConnectionsScreen())),
                  ListTile(leading: const Icon(Icons.auto_awesome_outlined), title: const Text('AI Provider'), trailing: const Icon(Icons.chevron_right), onTap: () => push(const AiSettingsScreen())),
                  ListTile(leading: const Icon(Icons.contacts_outlined), title: const Text('Contacts'), subtitle: Text('Default recipient: ${settings.defaultRecipientName}'), trailing: const Icon(Icons.chevron_right), onTap: () => push(const ContactsScreen())),
                  ListTile(leading: const Icon(Icons.battery_alert_outlined), title: const Text('Background reliability'), trailing: const Icon(Icons.chevron_right), onTap: () => push(const ReliabilityScreen())),
                ]),
              ),
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Notifications'),
              Panel(
                padding: EdgeInsets.zero,
                child: Column(children: <Widget>[
                  SwitchListTile(title: const Text('Workflow completed'), value: prefs.onCompleted, onChanged: (bool v) => settings.setNotificationPreferences(prefs.copyWith(onCompleted: v))),
                  SwitchListTile(title: const Text('Workflow failed'), value: prefs.onFailed, onChanged: (bool v) => settings.setNotificationPreferences(prefs.copyWith(onFailed: v))),
                  SwitchListTile(title: const Text('Approval required'), value: prefs.onApproval, onChanged: (bool v) => settings.setNotificationPreferences(prefs.copyWith(onApproval: v))),
                  SwitchListTile(title: const Text('Upcoming workflow'), value: prefs.onUpcoming, onChanged: (bool v) => settings.setNotificationPreferences(prefs.copyWith(onUpcoming: v))),
                  SwitchListTile(title: const Text('Connection failure'), value: prefs.onConnectionFailure, onChanged: (bool v) => settings.setNotificationPreferences(prefs.copyWith(onConnectionFailure: v))),
                  if (!settings.notificationsPermitted)
                    ListTile(
                      leading: const Icon(Icons.warning_amber, color: AutometaColors.warning),
                      title: const Text('Notifications are not permitted'),
                      trailing: TextButton(
                        onPressed: () async {
                          await context.read<AppServices>().notifications.ensurePermission();
                          await settings.refreshPlatformState();
                        },
                        child: const Text('Allow'),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Appearance'),
              Panel(
                padding: EdgeInsets.zero,
                child: SwitchListTile(
                  title: const Text('Dark theme'),
                  value: theme.mode == ThemeMode.dark,
                  onChanged: (bool v) => theme.onChanged(v ? ThemeMode.dark : ThemeMode.light),
                ),
              ),
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Advanced'),
              Panel(
                padding: EdgeInsets.zero,
                child: Column(children: <Widget>[
                  SwitchListTile(title: const Text('Developer mode'), subtitle: const Text('Engine log and workflow JSON'), value: settings.developerMode, onChanged: settings.setDeveloperMode),
                  if (settings.developerMode)
                    ListTile(leading: const Icon(Icons.terminal), title: const Text('Engine log'), trailing: const Icon(Icons.chevron_right), onTap: () => push(const DeveloperScreen())),
                ]),
              ),
              const SizedBox(height: AutometaSpacing.xl),
              Center(child: Text('${AppInfo.name} ${AppInfo.version} · ${AppInfo.tagline}', style: Theme.of(context).textTheme.bodySmall)),
              const SizedBox(height: AutometaSpacing.xl),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Honest explanation of Android background limits (spec §27).
class ReliabilityScreen extends StatefulWidget {
  const ReliabilityScreen({super.key});

  @override
  State<ReliabilityScreen> createState() => _ReliabilityScreenState();
}

class _ReliabilityScreenState extends State<ReliabilityScreen> {
  ScheduleSyncReport? _report;

  Future<void> _sync() async {
    final ScheduleSyncReport r = await context.read<AppServices>().scheduler.syncAll();
    if (!mounted) return;
    await context.read<SettingsService>().refreshPlatformState();
    setState(() => _report = r);
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsService s = context.watch<SettingsService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Background reliability')),
      body: ListView(padding: EdgeInsets.all(AutometaSpacing.page(context)), children: <Widget>[
        Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('How AUTOMETA runs in the background', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Each scheduled run is registered with Android\'s AlarmManager as an exact alarm, so it can fire '
            'even when the app is closed, and is restored after a reboot. A maintenance wake every few hours '
            're-arms anything the system dropped and catches up missed runs from the last 6 hours; older '
            'misses are recorded as Skipped rather than sent late.\n\n'
            'Android does not guarantee exact timing. Doze, battery saver and some manufacturers\' task killers '
            'can delay or cancel alarms. Force-stopping the app cancels all alarms until you open it again.',
          ),
        ])),
        const SizedBox(height: AutometaSpacing.lg),
        Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            StatusDot(s.batteryOptimized ? AutometaColors.warning : AutometaColors.success),
            const SizedBox(width: 8),
            Expanded(child: Text(s.batteryOptimized ? 'Battery optimisation is ON' : 'Battery optimisation is off')),
          ]),
          if (s.batteryOptimized) ...<Widget>[
            const SizedBox(height: 8),
            const Text('Runs may be delayed. Exempting AUTOMETA makes schedules much more punctual.'),
            TextButton(
              onPressed: () async {
                await context.read<AppServices>().platform.requestIgnoreBatteryOptimizations();
                await s.refreshPlatformState();
              },
              child: const Text('Open system setting'),
            ),
          ],
        ])),
        const SizedBox(height: AutometaSpacing.lg),
        if (_report != null)
          Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('Scheduler: ${_report!.armed} armed, ${_report!.disarmed} inactive'),
            for (final String w in _report!.warnings) Text('• $w', style: Theme.of(context).textTheme.bodySmall),
          ])),
        const SizedBox(height: AutometaSpacing.lg),
        OutlinedButton(onPressed: _sync, child: const Text('Re-sync schedules')),
      ]),
    );
  }
}

/// Developer mode (spec §41 M6): live engine log.
class DeveloperScreen extends StatelessWidget {
  const DeveloperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final List<LogRecord> logs = Logger.history.toList().reversed.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Engine log')),
      body: ListView.builder(
        padding: const EdgeInsets.all(AutometaSpacing.md),
        itemCount: logs.length,
        itemBuilder: (_, int i) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(logs[i].toString(), style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ),
      ),
    );
  }
}
