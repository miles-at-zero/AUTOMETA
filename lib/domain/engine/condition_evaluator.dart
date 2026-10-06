import 'package:flutter/foundation.dart';

import '../models/condition.dart';
import 'variable_resolver.dart';

/// The result of evaluating a condition, including why it resolved the way it
/// did — the builder shows this in the dry-run output.
@immutable
class ConditionEvaluation {
  const ConditionEvaluation({required this.result, required this.left, required this.right});

  final bool result;
  final String left;
  final String right;

  String describe() => '$left ${result ? '→ true' : '→ false'}';
}

/// Evaluates `IF` conditions (spec §11).
///
/// Comparison rules, in order:
///  1. Unary operators (`is true`, `is empty`) need no right side.
///  2. Date operators parse both sides as dates; if either fails the condition
///     is false and the reason is recorded.
///  3. Numeric operators compare numerically when *both* sides parse as
///     numbers, otherwise fall back to lexicographic ordering.
///  4. Everything else is a case-insensitive string comparison.
class ConditionEvaluator {
  const ConditionEvaluator();

  ConditionEvaluation evaluate(Condition condition, VariableResolver variables) {
    final String left = variables.resolve(condition.left).trim();
    final String right = variables.resolve(condition.right).trim();
    final bool result = _apply(condition.operator, left, right);
    return ConditionEvaluation(result: result, left: left, right: right);
  }

  bool _apply(ConditionOperator op, String left, String right) {
    switch (op) {
      case ConditionOperator.equals:
        return _stringEquals(left, right);
      case ConditionOperator.notEquals:
        return !_stringEquals(left, right);
      case ConditionOperator.contains:
        return left.toLowerCase().contains(right.toLowerCase()) && right.isNotEmpty;
      case ConditionOperator.notContains:
        return right.isEmpty || !left.toLowerCase().contains(right.toLowerCase());
      case ConditionOperator.startsWith:
        return left.toLowerCase().startsWith(right.toLowerCase()) && right.isNotEmpty;
      case ConditionOperator.endsWith:
        return left.toLowerCase().endsWith(right.toLowerCase()) && right.isNotEmpty;
      case ConditionOperator.greaterThan:
        return _compare(left, right) > 0;
      case ConditionOperator.lessThan:
        return _compare(left, right) < 0;
      case ConditionOperator.greaterOrEqual:
        return _compare(left, right) >= 0;
      case ConditionOperator.lessOrEqual:
        return _compare(left, right) <= 0;
      case ConditionOperator.isTrue:
        return _asBool(left);
      case ConditionOperator.isFalse:
        return !_asBool(left);
      case ConditionOperator.isEmpty:
        return left.isEmpty;
      case ConditionOperator.isNotEmpty:
        return left.isNotEmpty;
      case ConditionOperator.before:
        final DateTime? a = _asDate(left);
        final DateTime? b = _asDate(right);
        if (a == null || b == null) return false;
        return a.isBefore(b);
      case ConditionOperator.after:
        final DateTime? a = _asDate(left);
        final DateTime? b = _asDate(right);
        if (a == null || b == null) return false;
        return a.isAfter(b);
      case ConditionOperator.sameDay:
        final DateTime? a = _asDate(left);
        final DateTime? b = _asDate(right);
        if (a == null || b == null) return false;
        final DateTime al = a.toLocal();
        final DateTime bl = b.toLocal();
        return al.year == bl.year && al.month == bl.month && al.day == bl.day;
    }
  }

  bool _stringEquals(String a, String b) => a.toLowerCase() == b.toLowerCase();

  bool _asBool(String value) {
    final String v = value.toLowerCase().trim();
    return v == 'true' || v == '1' || v == 'yes' || v == 'y' || v == 'on';
  }

  int _compare(String a, String b) {
    final double? na = double.tryParse(a);
    final double? nb = double.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);

    final DateTime? da = _asDate(a);
    final DateTime? db = _asDate(b);
    if (da != null && db != null) return da.compareTo(db);

    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  /// Accepts ISO-8601, `yyyy-MM-dd`, `HH:mm`, weekday names and bare numbers of
  /// the day so `{{weekday}} after 2026-01-01` style rules behave sensibly.
  DateTime? _asDate(String value) {
    if (value.isEmpty) return null;
    final DateTime? parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;

    const Map<String, int> weekdays = <String, int>{
      'monday': 1,
      'tuesday': 2,
      'wednesday': 3,
      'thursday': 4,
      'friday': 5,
      'saturday': 6,
      'sunday': 7,
      'mon': 1,
      'tue': 2,
      'wed': 3,
      'thu': 4,
      'fri': 5,
      'sat': 6,
      'sun': 7,
    };
    final int? weekday = weekdays[value.toLowerCase()];
    if (weekday != null) {
      final DateTime now = DateTime.now();
      final int delta = (weekday - now.weekday) % 7;
      final DateTime today = DateTime(now.year, now.month, now.day);
      return today.add(Duration(days: delta));
    }

    final RegExp timeOnly = RegExp(r'^(\d{1,2}):(\d{2})$');
    final Match? time = timeOnly.firstMatch(value);
    if (time != null) {
      final DateTime now = DateTime.now();
      return DateTime(now.year, now.month, now.day, int.parse(time.group(1)!), int.parse(time.group(2)!));
    }
    return null;
  }
}
