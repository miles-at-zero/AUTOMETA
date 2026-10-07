import 'package:flutter/foundation.dart';

import '../models/execution.dart';
import '../models/execution_status.dart';

/// Automation Health (foundation).
///
/// A deterministic, explainable state computed ONLY from real execution
/// records. There is deliberately no numeric score yet: with the data we have
/// (recent runs per automation) a number would look precise without being
/// trustworthy. Every state carries the plain-language reasons that produced it.
///
/// Rules, evaluated in order (documented in docs/AUTOMATION_HEALTH.md):
///  1. Automation is off                                 -> INACTIVE
///  2. Capability/config problem for its execution mode  -> ATTENTION
///  3. No real (non-test) finished runs yet              -> UNKNOWN
///  4. The last [criticalStreak] finished runs all failed -> CRITICAL
///  5. The latest run failed, or any failure within
///     [window] of [now]                                 -> ATTENTION
///  6. Otherwise                                         -> HEALTHY
/// Skipped runs (condition not met, duplicate, paused) are reported but never
/// count as failures: skipping is often the automation working correctly.
enum HealthState {
  healthy('Healthy', '🟢'),
  attention('Needs attention', '🟡'),
  critical('Critical', '🔴'),
  inactive('Inactive', '⚪'),
  unknown('Not enough history', '⚫');

  const HealthState(this.label, this.emoji);
  final String label;
  final String emoji;
}

enum RunOutcome { success, failed, skipped, other }

/// One run, normalised from either a device [ExecutionRecord] or a Cloud
/// execution row, so health logic is identical for both execution modes.
@immutable
class RunSample {
  const RunSample({required this.at, required this.outcome, this.reason});

  final DateTime at;
  final RunOutcome outcome;
  final String? reason;

  /// Device runs. Dry runs are tests, not history.
  static RunSample? fromRecord(ExecutionRecord r) {
    if (r.dryRun || !r.isTerminal) return null;
    return RunSample(
      at: r.startedAt ?? r.scheduledFor,
      outcome: switch (r.status) {
        ExecutionStatus.success => RunOutcome.success,
        ExecutionStatus.failed => RunOutcome.failed,
        ExecutionStatus.skipped => RunOutcome.skipped,
        _ => RunOutcome.other,
      },
      reason: r.failureReason,
    );
  }

  /// Cloud runs (`GET /v1/automations/:id` → `recent[]`). Test runs and
  /// still-running rows are excluded. `partial` counts as a failure: some
  /// step did not do its job.
  static RunSample? fromCloud(Map<String, dynamic> e) {
    if (e['isTest'] == true || e['isTest'] == 1) return null;
    final String status = '${e['status'] ?? ''}';
    final Object? started = e['startedAt'];
    if (started is! num) return null;
    final RunOutcome outcome = switch (status) {
      'success' => RunOutcome.success,
      'failed' || 'partial' => RunOutcome.failed,
      'skipped' => RunOutcome.skipped,
      'cancelled' => RunOutcome.other,
      _ => RunOutcome.other, // running / unknown: not finished
    };
    if (status == 'running' || status.isEmpty) return null;
    final Object? err = e['error'];
    return RunSample(
      at: DateTime.fromMillisecondsSinceEpoch(started.toInt()),
      outcome: outcome,
      reason: err == null ? null : '$err',
    );
  }
}

@immutable
class AutomationHealth {
  const AutomationHealth({
    required this.state,
    required this.reasons,
    required this.sampleSize,
    required this.succeeded,
    required this.failed,
    required this.skipped,
    this.lastRun,
    this.lastFailure,
    this.lastFailureReason,
    this.mostCommonFailure,
  });

  final HealthState state;

  /// Plain-language explanation, most important first. Never empty.
  final List<String> reasons;

  /// How many real finished runs the counts below are based on.
  final int sampleSize;
  final int succeeded;
  final int failed;
  final int skipped;
  final DateTime? lastRun;
  final DateTime? lastFailure;
  final String? lastFailureReason;

  /// Only set when the same reason occurred at least twice.
  final String? mostCommonFailure;

  static const int criticalStreak = 3;
  static const Duration window = Duration(days: 7);

  static AutomationHealth evaluate({
    required bool enabled,
    required Iterable<RunSample> runs,
    required DateTime now,
    List<String> configIssues = const <String>[],
  }) {
    final List<RunSample> all = runs.where((RunSample r) => r.outcome != RunOutcome.other).toList()
      ..sort((RunSample a, RunSample b) => b.at.compareTo(a.at)); // newest first
    final int ok = all.where((RunSample r) => r.outcome == RunOutcome.success).length;
    final List<RunSample> fails = all.where((RunSample r) => r.outcome == RunOutcome.failed).toList();
    final int skipped = all.where((RunSample r) => r.outcome == RunOutcome.skipped).length;
    final RunSample? lastFail = fails.isEmpty ? null : fails.first;

    String? common;
    final Map<String, int> byReason = <String, int>{};
    for (final RunSample f in fails) {
      final String key = (f.reason ?? '').trim();
      if (key.isNotEmpty) byReason[key] = (byReason[key] ?? 0) + 1;
    }
    if (byReason.isNotEmpty) {
      final MapEntry<String, int> top = byReason.entries.reduce((MapEntry<String, int> a, MapEntry<String, int> b) => b.value > a.value ? b : a);
      if (top.value >= 2) common = top.key;
    }

    AutomationHealth make(HealthState s, List<String> reasons) => AutomationHealth(
          state: s,
          reasons: reasons,
          sampleSize: all.length,
          succeeded: ok,
          failed: fails.length,
          skipped: skipped,
          lastRun: all.isEmpty ? null : all.first.at,
          lastFailure: lastFail?.at,
          lastFailureReason: lastFail?.reason,
          mostCommonFailure: common,
        );

    if (!enabled) return make(HealthState.inactive, <String>['This automation is turned off.']);
    if (configIssues.isNotEmpty) {
      return make(HealthState.attention, <String>[
        for (final String i in configIssues) i,
      ]);
    }
    final List<RunSample> finished = all.where((RunSample r) => r.outcome != RunOutcome.skipped).toList();
    if (finished.isEmpty) {
      return make(HealthState.unknown, <String>[
        if (all.isEmpty) 'No runs yet. Health appears after the first real run.'
        else 'Only skipped runs so far, so there is nothing to judge yet.',
      ]);
    }
    int streak = 0;
    for (final RunSample r in finished) {
      if (r.outcome != RunOutcome.failed) break;
      streak++;
    }
    if (streak >= criticalStreak) {
      return make(HealthState.critical, <String>[
        'The last $streak runs failed.',
        if (lastFail?.reason != null) 'Latest reason: ${lastFail!.reason}',
      ]);
    }
    final int recentFails = fails.where((RunSample f) => now.difference(f.at) <= window).length;
    if (streak > 0 || recentFails > 0) {
      return make(HealthState.attention, <String>[
        if (streak > 0) 'The latest run failed.',
        if (recentFails > 0) '$recentFails failed ${recentFails == 1 ? 'run' : 'runs'} in the last 7 days.',
        if (lastFail?.reason != null) 'Latest reason: ${lastFail!.reason}',
      ]);
    }
    return make(HealthState.healthy, <String>[
      'No failures in the last 7 days. The latest run succeeded.',
    ]);
  }
}
