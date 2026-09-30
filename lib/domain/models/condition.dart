import 'package:meta/meta.dart';

import '../../core/utils/json_utils.dart';

/// How a condition compares its two sides.
enum ConditionOperator {
  equals('==', 'equals'),
  notEquals('!=', 'does not equal'),
  contains('contains', 'contains'),
  notContains('not_contains', 'does not contain'),
  startsWith('starts_with', 'starts with'),
  endsWith('ends_with', 'ends with'),
  greaterThan('>', 'is greater than'),
  lessThan('<', 'is less than'),
  greaterOrEqual('>=', 'is greater or equal'),
  lessOrEqual('<=', 'is less or equal'),
  isTrue('is_true', 'is true'),
  isFalse('is_false', 'is false'),
  isEmpty('is_empty', 'is empty'),
  isNotEmpty('is_not_empty', 'is not empty'),
  before('before', 'is before (date/time)'),
  after('after', 'is after (date/time)'),
  sameDay('same_day', 'is the same day as');

  const ConditionOperator(this.wire, this.label);

  final String wire;
  final String label;

  /// Operators that ignore the right-hand side entirely.
  bool get isUnary =>
      this == isTrue || this == isFalse || this == isEmpty || this == isNotEmpty;

  static ConditionOperator fromWire(Object? value, {ConditionOperator fallback = equals}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final ConditionOperator op in ConditionOperator.values) {
      if (op.wire == raw || op.name.toLowerCase() == raw) return op;
    }
    return fallback;
  }
}

/// A single testable predicate used by `IF` blocks (spec §11).
///
/// Either side may contain `{{variables}}`; they are resolved by the engine
/// before evaluation.
@immutable
class Condition {
  const Condition({
    required this.left,
    required this.operator,
    this.right = '',
    this.label,
  });

  final String left;
  final ConditionOperator operator;
  final String right;
  final String? label;

  Condition copyWith({String? left, ConditionOperator? operator, String? right, String? label}) =>
      Condition(
        left: left ?? this.left,
        operator: operator ?? this.operator,
        right: right ?? this.right,
        label: label ?? this.label,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'left': left,
        'operator': operator.wire,
        'right': right,
        if (label != null) 'label': label,
      };

  factory Condition.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return Condition(
      left: asString(map['left']),
      operator: ConditionOperator.fromWire(map['operator']),
      right: asString(map['right']),
      label: asStringOrNull(map['label']),
    );
  }

  /// One-line description used in the builder, e.g. `{{day}} equals Sunday`.
  String describe() {
    if (operator.isUnary) return '$left ${operator.label}';
    return '$left ${operator.label} $right';
  }

  @override
  String toString() => describe();
}
