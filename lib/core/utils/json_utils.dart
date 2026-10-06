/// Defensive JSON coercion helpers.
///
/// Workflow definitions are stored as JSON in SQLite and are also produced by
/// the natural-language creator, so parsing must never throw on a missing or
/// wrongly-typed field: it degrades to a default and lets validation report
/// the problem to the user.
library;

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((Object? k, Object? v) => MapEntry<String, dynamic>('$k', v));
  return <String, dynamic>{};
}

Map<String, dynamic>? asMapOrNull(Object? value) => value == null ? null : asMap(value);

String asString(Object? value, {String fallback = ''}) {
  if (value is String) return value;
  if (value == null) return fallback;
  return '$value';
}

String? asStringOrNull(Object? value) {
  if (value == null) return null;
  final String text = value is String ? value : '$value';
  return text.isEmpty ? null : text;
}

int asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double asDouble(Object? value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

bool asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final String v = value.toLowerCase();
    if (v == 'true' || v == '1' || v == 'yes') return true;
    if (v == 'false' || v == '0' || v == 'no') return false;
  }
  return fallback;
}

List<dynamic> asList(Object? value) {
  if (value is List) return value;
  return <dynamic>[];
}

List<String> asStringList(Object? value) =>
    asList(value).map((Object? e) => asString(e)).where((String s) => s.isNotEmpty).toList();

Set<int> asIntSet(Object? value) => asList(value)
    .map((Object? e) => asInt(e, fallback: -1))
    .where((int e) => e >= 1 && e <= 7)
    .toSet();

Map<String, String> asStringMap(Object? value) {
  final Map<String, dynamic> map = asMap(value);
  return map.map((String k, Object? v) => MapEntry<String, String>(k, asString(v)));
}

DateTime? asDateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}

/// Encodes an [int] set as a sorted JSON list so stored definitions are stable.
List<int> sortedInts(Iterable<int> values) => values.toSet().toList()..sort();
