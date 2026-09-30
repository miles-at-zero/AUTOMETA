import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/trigger.dart';
import '../models/workflow.dart';

/// All wall-clock reasoning about triggers lives here (spec §27, §38).
///
/// Rules this class enforces:
///  * A schedule is evaluated in the workflow's IANA time zone, so "every day
///    at 07:00" means 07:00 in Lagos even if the phone is in London.
///  * Results are returned as plain [DateTime] (UTC-normalised) so the caller
///    can hand them straight to AlarmManager, which works in epoch millis.
///  * A trigger that can never fire again returns `null` — never "now", never
///    a silent fallback to a different day.
class ScheduleCalculator {
  ScheduleCalculator({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static bool _tzReady = false;

  /// Loads the IANA database. Safe to call repeatedly.
  static void ensureTimeZonesLoaded() {
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    _tzReady = true;
  }

  DateTime now() => _clock();

  /// Resolves an IANA id to a [tz.Location], falling back to the device zone
  /// and finally to UTC. Never throws.
  tz.Location locationFor(String ianaId) {
    ensureTimeZonesLoaded();
    try {
      return tz.getLocation(ianaId);
    } catch (_) {
      try {
        return tz.local;
      } catch (_) {
        return tz.UTC;
      }
    }
  }

  /// Sets the process-local zone; called at startup with the device's real
  /// IANA name (from `flutter_timezone`) so relative displays are correct.
  static void setDeviceLocation(String ianaId) {
    ensureTimeZonesLoaded();
    try {
      tz.setLocalLocation(tz.getLocation(ianaId));
    } catch (_) {
      // Keep the default; the app still works, only labels degrade.
    }
  }

  /// Next firing of [workflow] strictly after [after] (defaults to now),
  /// returned in UTC. `null` when it will never fire again.
  DateTime? nextOccurrence(Workflow workflow, {DateTime? after}) =>
      nextOccurrenceForTrigger(workflow.trigger, timeZone: workflow.timeZone, after: after);

  DateTime? nextOccurrenceForTrigger(
    WorkflowTrigger trigger, {
    required String timeZone,
    DateTime? after,
  }) {
    if (!trigger.isSchedulable) return null;
    ensureTimeZonesLoaded();
    final tz.Location location = locationFor(timeZone);
    final DateTime reference = (after ?? _clock()).toUtc();
    final tz.TZDateTime anchor = tz.TZDateTime.from(reference, location);
    final tz.TZDateTime? next = trigger.nextOccurrence(anchor, location);
    return next?.toUtc();
  }

  /// Every firing inside `[from, to]`, inclusive of `from`, exclusive of `to`.
  /// Used by the dashboard "TODAY" list.
  List<DateTime> occurrencesBetween(
    Workflow workflow, {
    required DateTime from,
    required DateTime to,
    int limit = 64,
  }) {
    final List<DateTime> results = <DateTime>[];
    if (!workflow.trigger.isSchedulable) return results;
    DateTime cursor = from.toUtc();
    final DateTime end = to.toUtc();
    while (results.length < limit) {
      final DateTime? next = nextOccurrence(workflow, after: cursor);
      if (next == null || !next.isBefore(end)) break;
      results.add(next);
      cursor = next;
    }
    return results;
  }

  /// True when [workflow] fires at least once on the local calendar day of [day].
  bool runsOnDay(Workflow workflow, DateTime day) {
    final DateTime start = DateTime(day.year, day.month, day.day);
    final DateTime end = start.add(const Duration(days: 1));
    return occurrencesBetween(workflow, from: start, to: end, limit: 1).isNotEmpty;
  }

  /// The soonest pending run across [workflows], ignoring disabled ones.
  WorkflowRun? nextRunAcross(Iterable<Workflow> workflows, {DateTime? after}) {
    WorkflowRun? best;
    for (final Workflow workflow in workflows) {
      if (!workflow.enabled || !workflow.isScheduled) continue;
      final DateTime? next = nextOccurrence(workflow, after: after);
      if (next == null) continue;
      if (best == null || next.isBefore(best.at)) {
        best = WorkflowRun(workflow: workflow, at: next);
      }
    }
    return best;
  }

  /// Ordered list of upcoming runs across all workflows (dashboard feed).
  List<WorkflowRun> upcomingRuns(
    Iterable<Workflow> workflows, {
    int limit = 10,
    DateTime? after,
    Duration horizon = const Duration(days: 7),
  }) {
    final DateTime start = (after ?? _clock()).toUtc();
    final DateTime end = start.add(horizon);
    final List<WorkflowRun> runs = <WorkflowRun>[];
    final Map<String, DateTime> cursors = <String, DateTime>{
      for (final Workflow workflow in workflows) workflow.id: start,
    };

    while (runs.length < limit) {
      WorkflowRun? best;
      for (final Workflow workflow in workflows) {
        if (!workflow.enabled || !workflow.isScheduled) continue;
        final DateTime? next = nextOccurrence(workflow, after: cursors[workflow.id]);
        if (next == null || next.isAfter(end)) continue;
        if (best == null || next.isBefore(best.at)) {
          best = WorkflowRun(workflow: workflow, at: next);
        }
      }
      if (best == null) break;
      runs.add(best);
      cursors[best.workflow.id] = best.at;
    }
    return runs;
  }

  /// Detects whether the device clock or time zone moved between two runs —
  /// surfaced to the user rather than silently rescheduling.
  bool didTimeZoneChange(String? recordedIanaId) {
    if (recordedIanaId == null || recordedIanaId.isEmpty) return false;
    try {
      return tz.local.name != recordedIanaId;
    } catch (_) {
      return false;
    }
  }
}

/// A workflow paired with the moment it will next fire.
@immutable
class WorkflowRun {
  const WorkflowRun({required this.workflow, required this.at});

  final Workflow workflow;
  final DateTime at;

  @override
  String toString() => '${workflow.name} @ $at';
}
