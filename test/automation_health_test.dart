import 'package:autometa/domain/health/automation_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final DateTime now = DateTime(2026, 10, 7, 12);
  RunSample run(int hoursAgo, RunOutcome o, [String? reason]) =>
      RunSample(at: now.subtract(Duration(hours: hoursAgo)), outcome: o, reason: reason);

  AutomationHealth eval(List<RunSample> runs, {bool enabled = true, List<String> issues = const <String>[]}) =>
      AutomationHealth.evaluate(enabled: enabled, runs: runs, now: now, configIssues: issues);

  group('AutomationHealth (real runs only, no invented score)', () {
    test('turned off -> INACTIVE regardless of history', () {
      final AutomationHealth h = eval(<RunSample>[run(1, RunOutcome.failed)], enabled: false);
      expect(h.state, HealthState.inactive);
      expect(h.failed, 1, reason: 'history is still reported honestly');
    });

    test('no runs -> UNKNOWN with an explanation, not HEALTHY', () {
      final AutomationHealth h = eval(<RunSample>[]);
      expect(h.state, HealthState.unknown);
      expect(h.sampleSize, 0);
      expect(h.reasons.single, contains('No runs yet'));
      expect(h.lastRun, isNull);
    });

    test('only skipped runs -> UNKNOWN; skips are never failures', () {
      final AutomationHealth h = eval(<RunSample>[run(1, RunOutcome.skipped), run(30, RunOutcome.skipped)]);
      expect(h.state, HealthState.unknown);
      expect(h.failed, 0);
      expect(h.skipped, 2);
    });

    test('recent successes -> HEALTHY with counts', () {
      final AutomationHealth h = eval(<RunSample>[run(1, RunOutcome.success), run(25, RunOutcome.success), run(49, RunOutcome.skipped)]);
      expect(h.state, HealthState.healthy);
      expect(h.succeeded, 2);
      expect(h.skipped, 1);
      expect(h.sampleSize, 3);
      expect(h.lastRun, now.subtract(const Duration(hours: 1)));
    });

    test('latest run failed -> ATTENTION with the reason', () {
      final AutomationHealth h = eval(<RunSample>[run(1, RunOutcome.failed, 'Token expired'), run(25, RunOutcome.success)]);
      expect(h.state, HealthState.attention);
      expect(h.reasons, contains('The latest run failed.'));
      expect(h.reasons.last, contains('Token expired'));
    });

    test('a failure within 7 days after a later success -> still ATTENTION', () {
      final AutomationHealth h = eval(<RunSample>[run(1, RunOutcome.success), run(48, RunOutcome.failed)]);
      expect(h.state, HealthState.attention);
      expect(h.reasons.first, contains('1 failed run in the last 7 days'));
    });

    test('an old failure (> 7 days) followed by successes -> HEALTHY', () {
      final AutomationHealth h = eval(<RunSample>[run(1, RunOutcome.success), run(24 * 10, RunOutcome.failed)]);
      expect(h.state, HealthState.healthy);
      expect(h.failed, 1);
    });

    test('3 consecutive failures -> CRITICAL; skips between them do not break the streak', () {
      final AutomationHealth h = eval(<RunSample>[
        run(1, RunOutcome.failed, 'HTTP 500'),
        run(2, RunOutcome.skipped),
        run(3, RunOutcome.failed, 'HTTP 500'),
        run(4, RunOutcome.failed, 'Timeout'),
        run(5, RunOutcome.success),
      ]);
      expect(h.state, HealthState.critical);
      expect(h.reasons.first, 'The last 3 runs failed.');
      expect(h.mostCommonFailure, 'HTTP 500');
    });

    test('most common failure needs at least two occurrences', () {
      final AutomationHealth h = eval(<RunSample>[run(1, RunOutcome.failed, 'A'), run(2, RunOutcome.success)]);
      expect(h.mostCommonFailure, isNull);
      expect(h.lastFailureReason, 'A');
    });

    test('capability/config problems -> ATTENTION even with clean history', () {
      final AutomationHealth h = eval(<RunSample>[run(1, RunOutcome.success)], issues: <String>['Trigger: Gmail: Cloud only']);
      expect(h.state, HealthState.attention);
      expect(h.reasons.single, contains('Cloud only'));
    });
  });

  group('RunSample normalisation', () {
    test('Cloud: test runs and running rows are excluded; partial counts as failed', () {
      expect(RunSample.fromCloud(<String, dynamic>{'status': 'success', 'startedAt': 1, 'isTest': true}), isNull);
      expect(RunSample.fromCloud(<String, dynamic>{'status': 'running', 'startedAt': 1}), isNull);
      expect(RunSample.fromCloud(<String, dynamic>{'status': 'partial', 'startedAt': 1})!.outcome, RunOutcome.failed);
      final RunSample s = RunSample.fromCloud(<String, dynamic>{'status': 'failed', 'startedAt': 1000, 'error': 'Bot blocked'})!;
      expect(s.reason, 'Bot blocked');
      expect(s.at, DateTime.fromMillisecondsSinceEpoch(1000));
    });
  });
}
