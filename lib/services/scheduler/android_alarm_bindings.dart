import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

import '../../app_services.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import 'alarm_platform.dart';

/// Live AlarmManager binding.
///
/// Why AlarmManager and not a Dart `Timer` (spec §27):
///  * A `Timer` dies with the isolate. Android routinely kills background
///    processes, so a UI-process timer is not a scheduler.
///  * `AndroidAlarmManager.oneShotAt(..., exact: true, alarmClock: true)`
///    registers a `setAlarmClock` wake, the strongest guarantee Android offers
///    a third-party app. It survives process death and, thanks to the plugin's
///    own boot receiver, is restored after a device restart.
///  * Even that is not a promise. Doze and OEM battery managers can still
///    defer a wake, which is why [SchedulerService] reports battery state and
///    why the maintenance wake exists to catch up.
class AndroidAlarmBindings {
  const AndroidAlarmBindings._();

  static final Logger _log = Logger.withTag(LogTags.scheduler);

  /// Ids armed during this process lifetime, so `cancelAll` can reach them.
  static final Set<int> _armed = <int>{};

  static bool _initialised = false;

  static Future<bool> initialize() async {
    if (_initialised) return true;
    try {
      _initialised = await AndroidAlarmManager.initialize();
      _log.info('AlarmManager initialise -> $_initialised');
      return _initialised;
    } catch (error) {
      _log.error('AlarmManager could not initialise', error);
      return false;
    }
  }

  /// Builds the platform implementation used in a running app.
  static AlarmPlatform create() => AndroidAlarmPlatform(
        availableImpl: initialize,
        scheduleOnceImpl: ({
          required int id,
          required DateTime when,
          Map<String, String>? payload,
        }) async {
          if (!await initialize()) return;
          await AndroidAlarmManager.oneShotAt(
            when,
            id,
            automationAlarmCallback,
            alarmClock: true,
            allowWhileIdle: true,
            exact: true,
            wakeup: true,
            rescheduleOnReboot: true,
            params: <String, String>{...?payload},
          );
          _armed.add(id);
        },
        scheduleRepeatingImpl: ({
          required int id,
          required DateTime first,
          required Duration period,
          Map<String, String>? payload,
        }) async {
          if (!await initialize()) return;
          await AndroidAlarmManager.periodic(
            period,
            id,
            maintenanceAlarmCallback,
            startAt: first,
            allowWhileIdle: true,
            exact: false,
            wakeup: true,
            rescheduleOnReboot: true,
            params: <String, String>{...?payload},
          );
          _armed.add(id);
        },
        cancelImpl: (int id) async {
          await AndroidAlarmManager.cancel(id);
          _armed.remove(id);
        },
        cancelAllImpl: () async {
          for (final int id in Set<int>.of(_armed)) {
            await AndroidAlarmManager.cancel(id);
          }
          _armed.clear();
        },
      );
}

/// Entry point for a scheduled automation alarm.
///
/// Must be a top-level function: the plugin invokes it in a fresh background
/// isolate with no access to the UI isolate's objects. Everything it needs is
/// rebuilt from the database.
@pragma('vm:entry-point')
Future<void> automationAlarmCallback(int alarmId, Map<String, dynamic> params) async {
  final Logger log = Logger.withTag(LogTags.scheduler);
  if (params['reason'] == 'resume') {
    final AppServices services = await AppServices.bootstrapForBackground();
    try {
      await services.execution.resumeDeferredRuns();
    } catch (error, stackTrace) {
      log.error('Resume wake failed', error, stackTrace);
    } finally {
      await services.shutdown();
    }
    return;
  }
  final String workflowId = '${params['workflow_id'] ?? ''}';
  final String scheduledFor = '${params['scheduled_for'] ?? ''}';
  if (workflowId.isEmpty) {
    log.warn('Alarm fired with no workflow id');
    return;
  }

  final DateTime when =
      DateTime.tryParse(scheduledFor) ?? DateTime.now();
  log.info('Alarm fired for $workflowId scheduled $scheduledFor');

  final AppServices services = await AppServices.bootstrapForBackground();
  try {
    await services.execution.runScheduled(workflowId: workflowId, scheduledFor: when);
  } catch (error, stackTrace) {
    log.error('Scheduled run failed for $workflowId', error, stackTrace);
  } finally {
    await services.shutdown();
  }
}

/// Entry point for the periodic maintenance wake.
@pragma('vm:entry-point')
Future<void> maintenanceAlarmCallback(int alarmId, Map<String, dynamic> params) async {
  final Logger log = Logger.withTag(LogTags.scheduler);
  log.info('Maintenance wake');
  final AppServices services = await AppServices.bootstrapForBackground();
  try {
    await services.execution.expireStaleApprovals();
    await services.execution.resumeDeferredRuns();
    await services.execution.catchUpMissedRuns();
    await services.scheduler.syncAll();
  } catch (error, stackTrace) {
    log.error('Maintenance wake failed', error, stackTrace);
  } finally {
    await services.shutdown();
  }
}
