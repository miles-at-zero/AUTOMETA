import 'package:autometa/domain/engine/condition_evaluator.dart';
import 'package:autometa/domain/engine/idempotency.dart';
import 'package:autometa/domain/engine/retry_policy.dart';
import 'package:autometa/domain/engine/variable_resolver.dart';
import 'package:autometa/domain/models/condition.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('variables', () {
    final VariableResolver r = VariableResolver(const <String, String>{'name': 'Dad', 'day': 'Sunday'});
    test('expands tokens', () => expect(r.resolve('Good morning {{name}}. Have a great {{day}}!'), 'Good morning Dad. Have a great Sunday!'));
    test('fallback syntax', () => expect(r.resolve('Hi {{nick|friend}}'), 'Hi friend'));
    test('unknown tokens become empty and are reported', () {
      final VariableResolver v = VariableResolver(const <String, String>{});
      expect(v.resolve('x{{nope}}y'), 'xy');
      expect(v.missingVariables, contains('nope'));
    });
    test('built-ins include date/time/day', () {
      final Map<String, String> b = VariableResolver.builtIns(DateTime(2026, 10, 4, 18), defaultName: 'Dad');
      expect(b['day'], 'Sunday');
      expect(b['time'], '18:00');
      expect(b['date'], '2026-10-04');
      expect(b['name'], 'Dad');
    });
  });

  group('conditions', () {
    const ConditionEvaluator e = ConditionEvaluator();
    final VariableResolver v = VariableResolver(const <String, String>{'day': 'Sunday', 'n': '10', 'flag': 'true', 'text': 'Hello world'});
    bool check(String l, ConditionOperator op, [String r = '']) => e.evaluate(Condition(left: l, operator: op, right: r), v).result;

    test('equals is case-insensitive', () => expect(check('{{day}}', ConditionOperator.equals, 'sunday'), isTrue));
    test('not equals', () => expect(check('{{day}}', ConditionOperator.notEquals, 'Monday'), isTrue));
    test('contains', () => expect(check('{{text}}', ConditionOperator.contains, 'world'), isTrue));
    test('numeric greater/less', () {
      expect(check('{{n}}', ConditionOperator.greaterThan, '9'), isTrue);
      expect(check('{{n}}', ConditionOperator.lessThan, '9'), isFalse);
      expect(check('{{n}}', ConditionOperator.greaterThan, '100'), isFalse, reason: 'numeric, not lexicographic');
    });
    test('boolean', () {
      expect(check('{{flag}}', ConditionOperator.isTrue), isTrue);
      expect(check('{{missing}}', ConditionOperator.isEmpty), isTrue);
    });
    test('date comparisons', () {
      expect(check('2026-01-01', ConditionOperator.before, '2026-06-01'), isTrue);
      expect(check('2026-01-01T10:00:00', ConditionOperator.sameDay, '2026-01-01T23:00:00'), isTrue);
      expect(check('not a date', ConditionOperator.after, '2026-01-01'), isFalse);
    });
  });

  group('idempotency', () {
    test('key is deterministic for the same slot and differs across slots', () {
      final DateTime t = DateTime.utc(2026, 10, 1, 6);
      final String a = IdempotencyKeys.forScheduledRun(workflow: dadWorkflow(), scheduledFor: t);
      final String b = IdempotencyKeys.forScheduledRun(workflow: dadWorkflow(), scheduledFor: t);
      final String c = IdempotencyKeys.forScheduledRun(workflow: dadWorkflow(), scheduledFor: t.add(const Duration(days: 1)));
      expect(a, b);
      expect(a, isNot(c));
    });
    test('different target → different key', () {
      final DateTime t = DateTime.utc(2026, 10, 1, 6);
      expect(
        IdempotencyKeys.forScheduledRun(workflow: dadWorkflow(), scheduledFor: t),
        isNot(IdempotencyKeys.forScheduledRun(workflow: dadWorkflow(), scheduledFor: t, overrideTarget: 'wa:Mum')),
      );
    });
    test('in-memory guard: execute then skip', () {
      final InMemoryIdempotencyGuard g = InMemoryIdempotencyGuard();
      expect(g.claim('k'), isTrue);
      expect(g.claim('k'), isFalse);
    });
  });

  group('retry policy', () {
    test('finite and capped', () {
      final RetryPolicy p = RetryPolicy.fromMaxRetries(99);
      expect(p.maxAttempts, 6);
      expect(p.shouldRetry(attempt: 6, retriable: true), isFalse);
    });
    test('non-retriable never retries', () => expect(RetryPolicy.fromMaxRetries(3).shouldRetry(attempt: 1, retriable: false), isFalse));
    test('backoff grows', () {
      const RetryPolicy p = RetryPolicy(jitter: false);
      expect(p.backoffFor(2), greaterThan(p.backoffFor(1)));
      expect(p.backoffFor(20), lessThanOrEqualTo(const Duration(hours: 1)));
    });
  });
}
