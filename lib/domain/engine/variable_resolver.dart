import 'package:intl/intl.dart';

/// Expands `{{variable}}` tokens inside any string field (spec §14).
///
/// Supported syntax:
///   `{{name}}`              -> value or empty string
///   `{{name|fallback}}`     -> value or `fallback` when missing/empty
///
/// Unknown variables expand to an empty string rather than throwing, and the
/// resolver records them so the UI can warn the user about a typo.
class VariableResolver {
  VariableResolver(this.values);

  final Map<String, String> values;

  static final RegExp _token = RegExp(r'\{\{\s*([a-zA-Z0-9_.\-]+)\s*(?:\|\s*([^{}]*?))?\s*\}\}');

  /// Tokens that were referenced but had no value.
  final Set<String> _missing = <String>{};
  Set<String> get missingVariables => Set<String>.unmodifiable(_missing);

  String? lookup(String key) {
    final String? direct = values[key];
    if (direct != null && direct.isNotEmpty) return direct;
    // Allow snake_case / camelCase to be used interchangeably.
    final String alternate = key.contains('_')
        ? key.replaceAll('_', '')
        : key.replaceAllMapped(RegExp('[A-Z]'), (Match m) => '_${m[0]!.toLowerCase()}');
    final String? fallback = values[alternate];
    return (fallback != null && fallback.isNotEmpty) ? fallback : direct;
  }

  String resolve(String template) {
    if (!template.contains('{{')) return template;
    return template.replaceAllMapped(_token, (Match match) {
      final String key = match.group(1)!;
      final String? fallback = match.group(2);
      final String? value = lookup(key);
      if (value != null && value.isNotEmpty) return value;
      if (fallback != null) return fallback;
      _missing.add(key);
      return '';
    });
  }

  /// Resolves every string in a map (used for HTTP headers and webhook bodies).
  Map<String, String> resolveMap(Map<String, String> input) =>
      input.map((String key, String value) => MapEntry<String, String>(resolve(key), resolve(value)));

  VariableResolver withValues(Map<String, String> extra) =>
      VariableResolver(<String, String>{...values, ...extra});

  /// Built-in variables derived from the run's wall-clock moment.
  static Map<String, String> builtIns(
    DateTime now, {
    String defaultName = '',
    String workflowName = '',
  }) {
    final DateTime local = now.toLocal();
    final bool weekend = local.weekday == DateTime.saturday || local.weekday == DateTime.sunday;
    return <String, String>{
      'date': DateFormat('yyyy-MM-dd').format(local),
      'date_long': DateFormat.yMMMMd().format(local),
      'date_short': DateFormat.MMMd().format(local),
      'time': DateFormat.Hm().format(local),
      'time_12': DateFormat.jm().format(local),
      'datetime': DateFormat.yMMMd().add_jm().format(local),
      'day': DateFormat('EEEE').format(local),
      'day_short': DateFormat('EEE').format(local),
      'day_number': '${local.weekday}',
      'month': DateFormat('MMMM').format(local),
      'month_number': '${local.month}',
      'year': '${local.year}',
      'weekend': weekend ? 'true' : 'false',
      'weekday': weekend ? 'false' : 'true',
      'day_type': weekend ? 'weekend' : 'weekday',
      'greeting': _greeting(local),
      'timestamp': '${local.millisecondsSinceEpoch}',
      'iso': local.toUtc().toIso8601String(),
      'name': defaultName,
      'workflow': workflowName,
    };
  }

  static String _greeting(DateTime local) {
    final int hour = local.hour;
    if (hour < 5) return 'Still up';
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    if (hour < 22) return 'Good evening';
    return 'Good night';
  }

  /// Every variable name the resolver knows, for the variable picker UI.
  static const List<String> builtInNames = <String>[
    'name',
    'date',
    'date_long',
    'date_short',
    'time',
    'time_12',
    'datetime',
    'day',
    'day_short',
    'day_number',
    'month',
    'month_number',
    'year',
    'weekend',
    'weekday',
    'day_type',
    'greeting',
    'timestamp',
    'iso',
    'workflow',
    'message',
  ];

  /// Pulls `{{tokens}}` out of a template so the builder can show what a block
  /// depends on.
  static Set<String> referencedIn(String template) =>
      _token.allMatches(template).map((Match m) => m.group(1)!).toSet();
}
