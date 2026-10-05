import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../cloud/cloud_session.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/logger.dart';
import '../../domain/models/execution_mode.dart';
import '../../services/notifications/notification_service.dart';
import '../../services/scheduler/scheduler_service.dart';
import '../../services/settings/settings_service.dart';
import '../../state/app_state.dart';
import '../app.dart';
import '../widgets/autometa_widgets.dart';
import 'ai_settings_screen.dart';
import 'business/business_shell.dart';
import 'cloud_account_screen.dart';
import 'reliability_screen.dart';
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
              const SectionLabel('Automation defaults'),
              Panel(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  RadioListTile<ExecutionMode>(
                    value: ExecutionMode.cloud,
                    groupValue: settings.defaultExecution,
                    onChanged: (ExecutionMode? m) => settings.setDefaultExecution(m!),
                    title: const Text('☁️ Cloud · Recommended'),
                    subtitle: const Text(ExecutionCopy.cloudTagline),
                  ),
                  RadioListTile<ExecutionMode>(
                    value: ExecutionMode.onDevice,
                    groupValue: settings.defaultExecution,
                    onChanged: (ExecutionMode? m) => settings.setDefaultExecution(m!),
                    title: const Text('📱 On this device'),
                    subtitle: const Text(ExecutionCopy.deviceTagline),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Text('Default execution for new automations. Cloud is recommended for reliable background automation. '
                        'Existing automations keep the mode you chose for them.', style: Theme.of(context).textTheme.bodySmall),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_outlined, color: AutometaColors.accent),
                    title: const Text('Autometa Cloud account'),
                    subtitle: Text(context.watch<CloudSession>().signedIn
                        ? 'Signed in as ${context.watch<CloudSession>().email}'
                        : 'Not signed in. Needed to run automations in Cloud.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => push(const CloudAccountScreen()),
                  ),
                ]),
              ),
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Mode'),
              Panel(
                padding: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.storefront_outlined, color: AutometaColors.secondary),
                  title: const Text('Business mode'),
                  subtitle: const Text('Customer inbox, order and lead workflows, team, insights'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => push(const BusinessGate()),
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
