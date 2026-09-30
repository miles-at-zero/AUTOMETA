import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../../data/repositories/workflow_repository.dart';
import '../../domain/models/workflow.dart';
import '../../domain/schedule/schedule_calculator.dart';
import 'alarm_platform.dart';

/// One workflow's arming outcome.
@immutable
class ArmResult {
  const ArmResult({
    required this.workflowId,
    required this.name,
    this.nextRunAt,
    this.alarmId,
    this.error,
  });

  final String workflowId;
  final String name;
  final DateTime? nextRunAt;
  final int? alarmId;
  final String? error;

  bool get armed => nextRunAt != null && error == null;
}

/// Outcome of a full scheduler sync, surfaced on the Settings page.
@immutable
class ScheduleSyncReport {
  const ScheduleSyncReport({
    required this.armed,
    required this.disarmed,
    required this.results,
    required this.platformAvailable,
    required this.batteryOptimized,
    required this.syncedAt,
  });

  final int armed;
  final int disarmed;
  final List<ArmResult> results;
  final bool platformAvailable;

  /// True when Android may defer our alarms (battery optimisation is on).
  final bool batteryOptimized;
  final DateTime syncedAt;

  List<String> get warnings {
    final List<String> warnings = <String>[];
    if (!platformAvailable) {
      warnings.add('The OS scheduler is not available — automations will only run '
          'while AUTOMETA is open.');
    }
    if (batteryOptimized) {
      warnings.add('Battery optimisation is on. Android may delay runs by minutes '
          'or skip them during Doze. Turn it off for AUTOMETA in system settings.');
    }
    for (final ArmResult result in results) {
      if (result.error != null) warnings.add('${result.name}: ${result.error}');
    }
    return warnings;
  }

  bool get healthy => platformAvailable && !batteryOptimized && armed > 0;
}

/// Arms and disarms OS alarms (spec §27).
///
/// Design constraints this respects:
///  * A `Timer` inside the UI isolate is never used for automation. Every
///    scheduled run goes to AlarmManager, which survives process death.
///  * Alarms are one-shot and re-armed after each run. Repeating alarms drift
///    and cannot express "07:00 in the workflow's time zone across DST".
///  * Nothing here claims guaranteed execution. Android can still defer or
///    drop an exact alarm under Doze, so the report says exactly what is armed
///    and what the platform may do to it.
class SchedulerService {
  SchedulerService({
    required this.platform,
    required this.calculator,
    required this.workflows,
    this.logSink,
  });

  final AlarmPlatform platform;
  final ScheduleCalculator calculator;
  final WorkflowRepository workflows;
  final void Function(String message)? logSink;

  final Logger _log = Logger.withTag(LogTags.scheduler);

  static const Duration maintenancePeriod = Duration(hours: 3);

  void _emit(String message) {
    _log.info(message);
    logSink?.call(message);
  }

  /// Re-arms every workflow to match its stored definition.
  Future<ScheduleSyncReport> syncAll() async {
    final bool available = await platform.isAvailable;
    final bool batteryOptimized = !(await platform.isIgnoringBatteryOptimizations);
    final List<Workflow> all = await workflows.getAll();
    final List<ArmResult> results = <ArmResult>[];
    int armed = 0;
    int disarmed = 0;

    for (final Workflow workflow in all) {
      if (!workflow.enabled || !workflow.isScheduled) {
        await disarmWorkflow(workflow.id, persist: true);
        disarmed++;
        results.add(ArmResult(workflowId: workflow.id, name: workflow.name));
        continue;
      }
      final ArmResult result = await armWorkflow(workflow, checkAvailable: available);
      results.add(result);
      if (result.armed) {
        armed++;
      } else {
        disarmed++;
      }
    }

    if (available) await startMaintenance();

    final ScheduleSyncReport report = ScheduleSyncReport(
      armed: armed,
      disarmed: disarmed,
      results: results,
      platformAvailable: available,
      batteryOptimized: batteryOptimized,
      syncedAt: DateTime.now(),
    );
    _emit('Scheduler sync: $armed armed, $disarmed inactive, '
        'platform ${available ? 'available' : 'UNAVAILABLE'}, '
        'battery optimisation ${batteryOptimized ? 'ON' : 'off'}');
    return report;
  }

  /// Arms the next occurrence of one workflow.
  Future<ArmResult> armWorkflow(Workflow workflow, {bool? checkAvailable}) async {
    final bool available = checkAvailable ?? await platform.isAvailable;
    final int alarmId = alarmIdFor(workflow.id);

    if (!workflow.enabled) {
      await platform.cancel(alarmId);
      await workflows.setNextRun(workflow.id, null);
      return ArmResult(workflowId: workflow.id, name: workflow.name);
    }

    if (!workflow.isScheduled) {
      await platform.cancel(alarmId);
      await workflows.setNextRun(workflow.id, null);
      return ArmResult(
        workflowId: workflow.id,
        name: workflow.name,
        error: '${workflow.trigger.type.label} triggers do not need an alarm',
      );
    }

    final DateTime? next = calculator.nextOccurrence(workflow);
    if (next == null) {
      await platform.cancel(alarmId);
      await workflows.setNextRun(workflow.id, null);
      return ArmResult(
        workflowId: workflow.id,
        name: workflow.name,
        error: 'This trigger will not fire again',
      );
    }

    if (!available) {
      await workflows.setNextRun(workflow.id, next);
      return ArmResult(
        workflowId: workflow.id,
        name: workflow.name,
        nextRunAt: next,
        alarmId: alarmId,
        error: 'OS scheduler unavailable',
      );
    }

    try {
      await platform.scheduleOnce(
        id: alarmId,
        when: next,
        payload: <String, String>{
          'workflow_id': workflow.id,
          'scheduled_for': next.toUtc().toIso8601String(),
          'reason': 'schedule',
        },
      );
      await workflows.setNextRun(workflow.id, next);
      _emit('Armed ${workflow.name} for ${next.toIso8601String()} (alarm $alarmId)');
      return ArmResult(
        workflowId: workflow.id,
        name: workflow.name,
        nextRunAt: next,
        alarmId: alarmId,
      );
    } catch (error) {
      _log.error('Failed to arm ${workflow.name}', error);
      await workflows.setNextRun(workflow.id, next);
      return ArmResult(
        workflowId: workflow.id,
        name: workflow.name,
        nextRunAt: next,
        alarmId: alarmId,
        error: 'Could not register the alarm: $error',
      );
    }
  }

  /// Arms a one-shot wake for a run parked on a long `WAIT`.
  Future<void> armResume({required String executionId, required DateTime at}) async {
    if (!await platform.isAvailable) return;
    await platform.scheduleOnce(
      id: alarmIdFor('resume:$executionId'),
      when: at,
      payload: <String, String>{'reason': 'resume', 'execution_id': executionId},
    );
    _emit('Armed resume for $executionId at ${at.toIso8601String()}');
  }

  Future<void> disarmWorkflow(String workflowId, {bool persist = true}) async {
    await platform.cancel(alarmIdFor(workflowId));
    if (persist) await workflows.setNextRun(workflowId, null);
    _emit('Disarmed $workflowId');
  }

  Future<void> disarmAll() async {
    await platform.cancelAll();
    await workflows.clearAllNextRuns();
    _emit('Disarmed every workflow');
  }

  /// Arms the recurring maintenance wake.
  ///
  /// This is the recovery path: it re-arms alarms the OS dropped, catches up
  /// runs that Doze deferred, and re-checks connection health.
  Future<void> startMaintenance() async {
    try {
      await platform.scheduleRepeating(
        id: AlarmIds.maintenance,
        first: DateTime.now().add(maintenancePeriod),
        period: maintenancePeriod,
        payload: const <String, String>{'reason': 'maintenance'},
      );
      _emit('Maintenance wake armed every ${maintenancePeriod.inHours}h');
    } catch (error) {
      _log.warn('Could not arm the maintenance wake', error);
    }
  }
}
