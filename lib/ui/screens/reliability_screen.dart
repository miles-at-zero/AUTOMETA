import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/theme/design_tokens.dart';
import '../../services/diagnostics/diagnostics_service.dart';
import '../../services/scheduler/android_alarm_bindings.dart' show formatLateness;
import '../../services/scheduler/scheduler_service.dart';
import '../../services/settings/settings_service.dart';
import '../widgets/autometa_widgets.dart';

/// Background reliability: live device checks, a real AlarmManager self-test,
/// and a log of how late every alarm was actually delivered.
class ReliabilityScreen extends StatefulWidget {
  const ReliabilityScreen({super.key});

  @override
  State<ReliabilityScreen> createState() => _ReliabilityScreenState();
}

class _ReliabilityScreenState extends State<ReliabilityScreen> with WidgetsBindingObserver {
  DeviceReliability? _device;
  ScheduleSyncReport? _report;
  List<AlarmFire> _log = <AlarmFire>[];
  (String, DateTime)? _pending;

  DiagnosticsService get _diag => context.read<AppServices>().diagnostics;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh(sync: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh({bool sync = false}) async {
    final AppServices s = context.read<AppServices>();
    final ScheduleSyncReport? r = sync ? await s.scheduler.syncAll() : _report;
    final DeviceReliability d = await _diag.device();
    final List<AlarmFire> log = await _diag.history();
    final (String, DateTime)? p = await _diag.pendingTest();
    if (!mounted) return;
    await context.read<SettingsService>().refreshPlatformState();
    setState(() {
      _report = r;
      _device = d;
      _log = log;
      _pending = p;
    });
  }

  Future<void> _test(Duration d, String label) async {
    final DateTime at = await _diag.scheduleTest(d, label: label);
    await _refresh();
    if (mounted) {
      showToast(context, 'Test alarm set for ${DateFormat.jm().format(at)}. You can close the app now.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final DeviceReliability? d = _device;
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Background reliability')),
      body: RefreshIndicator(
        onRefresh: () => _refresh(sync: true),
        child: ListView(padding: EdgeInsets.all(AutometaSpacing.page(context)), children: <Widget>[
          if (d != null && d.manufacturer.isNotEmpty)
            Text('${d.manufacturer} ${d.model} · Android API ${d.sdk}', style: text.bodySmall),
          const SizedBox(height: AutometaSpacing.sm),
          const SectionLabel('Checks'),
          _check(
            ok: d?.exactAlarmsAllowed ?? true,
            title: 'Exact alarms allowed',
            bad: 'Without this, Android may run automations many minutes late.',
            action: 'Allow',
            onFix: () => _diag.openExactAlarmSettings(),
          ),
          _check(
            ok: !(d?.batteryOptimized ?? false),
            title: 'Battery optimisation off for AUTOMETA',
            bad: 'Battery optimisation can delay or drop alarms, especially overnight.',
            action: 'Exempt',
            onFix: () => context.read<AppServices>().platform.requestIgnoreBatteryOptimizations(),
          ),
          _check(
            ok: d?.notificationsAllowed ?? true,
            title: 'Notifications allowed',
            bad: 'You won\'t see results, failures or messages waiting for you.',
            action: 'Allow',
            onFix: () => context.read<AppServices>().platform.requestNotificationPermission(),
          ),
          if (d?.hasAggressiveOem ?? false)
            Panel(
              glow: AutometaColors.warning,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(d!.isTranssion ? 'Infinix / Tecno / itel (XOS) extra steps' : '${d.manufacturer} extra steps',
                    style: text.titleSmall),
                const SizedBox(height: 6),
                Text(d.isTranssion
                    ? '1. Phone Master → App management → Auto-start → turn ON for AUTOMETA.\n'
                        '2. Settings → Battery → App power saving (or "Power management") → AUTOMETA → No restrictions.\n'
                        '3. Open recent apps, press and hold AUTOMETA, tap the lock icon so "Clear all" doesn\'t kill it.\n'
                        '4. Never "Force stop" AUTOMETA: that cancels every alarm until you open it again.'
                    : 'Allow auto-start / background activity for AUTOMETA, set battery to "No restrictions", '
                        'and lock it in recent apps. Never force-stop it.'),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: <Widget>[
                  OutlinedButton(onPressed: () => _diag.openAutostartSettings(), child: const Text('Open auto-start')),
                  TextButton(onPressed: () => _diag.openAppDetails(), child: const Text('App info')),
                ]),
              ]),
            ),
          const SizedBox(height: AutometaSpacing.xl),
          const SectionLabel('Test on this phone'),
          Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text(
              'Sets a real alarm through the same path your automations use. When it fires you get a '
              'notification saying how late it was. Try each situation:',
            ),
            const SizedBox(height: 8),
            const Text('• App closed: set 2 min, swipe AUTOMETA away from recents\n'
                '• Screen locked: set 2 min, lock the phone\n'
                '• Idle overnight: set 8 h before bed\n'
                '• Battery optimisation ON vs OFF: run both\n'
                '• Restart: set 15 min, then reboot the phone'),
            const SizedBox(height: 10),
            if (_pending != null)
              Row(children: <Widget>[
                const Icon(Icons.alarm, size: 18, color: AutometaColors.accent),
                const SizedBox(width: 6),
                Expanded(child: Text('Waiting: ${_pending!.$1} at ${DateFormat.jm().format(_pending!.$2.toLocal())}')),
                TextButton(onPressed: () async {
                  await _diag.cancelTest();
                  await _refresh();
                }, child: const Text('Cancel')),
              ]),
            Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
              FilledButton(onPressed: () => _test(const Duration(minutes: 2), '2-minute test'), child: const Text('In 2 min')),
              OutlinedButton(onPressed: () => _test(const Duration(minutes: 15), 'Reboot test (15 min)'), child: const Text('In 15 min')),
              OutlinedButton(onPressed: () => _test(const Duration(hours: 8), 'Overnight test (8 h)'), child: const Text('In 8 h')),
            ]),
          ])),
          const SizedBox(height: AutometaSpacing.xl),
          Row(children: <Widget>[
            const Expanded(child: SectionLabel('Alarm delivery log')),
            if (_log.isNotEmpty)
              TextButton(onPressed: () async {
                await _diag.clear();
                await _refresh();
              }, child: const Text('Clear')),
          ]),
          if (_log.isEmpty)
            Text('No alarms delivered yet. Run a test above, or wait for an automation.', style: text.bodySmall),
          for (final AlarmFire f in _log) _logRow(f),
          const SizedBox(height: AutometaSpacing.xl),
          if (_report != null)
            Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Scheduler: ${_report!.armed} armed, ${_report!.disarmed} inactive'),
              for (final String w in _report!.warnings) Text('• $w', style: text.bodySmall),
            ])),
          const SizedBox(height: AutometaSpacing.md),
          OutlinedButton(onPressed: () => _refresh(sync: true), child: const Text('Re-sync schedules')),
          const SizedBox(height: AutometaSpacing.md),
          Text(
            'Overdue alarms (after a reboot or deep sleep) run if they are under 2 hours late, otherwise '
            'they are recorded as Skipped instead of sending a late message. A maintenance wake every 3 hours '
            're-arms anything Android dropped.',
            style: text.bodySmall,
          ),
        ]),
      ),
    );
  }

  Widget _check({required bool ok, required String title, required String bad, required String action, required VoidCallback onFix}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: AutometaSpacing.sm),
        child: Panel(
          child: Row(children: <Widget>[
            Icon(ok ? Icons.check_circle : Icons.error_outline, color: ok ? AutometaColors.success : AutometaColors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(title),
                if (!ok) Text(bad, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            if (!ok) TextButton(onPressed: onFix, child: Text(action)),
          ]),
        ),
      );

  Widget _logRow(AlarmFire f) {
    final int secs = f.late.inSeconds;
    final Color c = secs <= 60
        ? AutometaColors.success
        : secs <= 600
            ? AutometaColors.warning
            : AutometaColors.danger;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(f.test ? Icons.science_outlined : Icons.alarm, color: c),
      title: Text(f.label),
      subtitle: Text('Due ${DateFormat('EEE d MMM, h:mm a').format(f.scheduledFor.toLocal())}'),
      trailing: Text(secs <= 60 ? 'on time' : '${formatLateness(f.late)} late', style: TextStyle(color: c)),
    );
  }
}
