import 'dart:async';
import 'dart:collection';

/// A tiny leveled logger.
///
/// Two rules are enforced here and nowhere else:
///  1. Every line is prefixed with a tag so background/headless runs can be
///     told apart from UI activity.
///  2. Secret-bearing values are redacted. `Logger.redact()` is applied to
///     anything that could carry a token before it reaches `print`.
class LogLevel {
  const LogLevel._(this.name, this.severity);

  final String name;
  final int severity;

  static const LogLevel debug = LogLevel._('DEBUG', 0);
  static const LogLevel info = LogLevel._('INFO ', 1);
  static const LogLevel warn = LogLevel._('WARN ', 2);
  static const LogLevel error = LogLevel._('ERROR', 3);
}

typedef LogSink = void Function(LogRecord record);

class LogRecord {
  const LogRecord({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  @override
  String toString() {
    final String ts = time.toIso8601String();
    final StringBuffer buffer = StringBuffer('$ts [${level.name}] [$tag] $message');
    if (error != null) buffer.write(' | error: $error');
    return buffer.toString();
  }
}

class Logger {
  Logger._(this.tag);

  factory Logger.withTag(String tag) => Logger._(tag);

  final String tag;

  static LogLevel minimumLevel = LogLevel.debug;
  static final ListQueue<LogRecord> history = ListQueue<LogRecord>();
  static final List<LogSink> _sinks = <LogSink>[];

  /// In-memory ring buffer of the most recent records, surfaced by the
  /// in-app developer console.
  static const int historyLimit = 500;

  /// Registers an extra destination (e.g. a debug console widget).
  static void addSink(LogSink sink) => _sinks.add(sink);
  static void removeSink(LogSink sink) => _sinks.remove(sink);

  /// Masks a value that might contain a credential.
  ///
  /// Used for access tokens, API keys and anything logged from an integration.
  static String redact(String? value) {
    if (value == null || value.isEmpty) return '—';
    if (value.length <= 8) return '••••';
    return '${value.substring(0, 3)}••••${value.substring(value.length - 2)}';
  }

  /// Masks every `key=value` / `"key": "value"` pair whose key looks secret.
  static String scrub(String message) {
    const List<String> secretKeys = <String>[
      'token',
      'api_key',
      'apikey',
      'authorization',
      'password',
      'secret',
      'access_token',
      'app_secret',
    ];
    String out = message;
    for (final String key in secretKeys) {
      final RegExp json = RegExp('("$key"\\s*:\\s*")([^"]{0,512})(")', caseSensitive: false);
      out = out.replaceAllMapped(json, (Match m) => '${m[1]}${redact(m[2])}${m[3]}');
      final RegExp pair = RegExp('($key\\s*[=:]\\s*)(\\S+)', caseSensitive: false);
      out = out.replaceAllMapped(pair, (Match m) => '${m[1]}${redact(m[2])}');
    }
    return out;
  }

  void debug(String message) => _emit(LogLevel.debug, message);
  void info(String message) => _emit(LogLevel.info, message);
  void warn(String message, [Object? error]) => _emit(LogLevel.warn, message, error);
  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      _emit(LogLevel.error, message, error, stackTrace);

  void _emit(LogLevel level, String message, [Object? error, StackTrace? stackTrace]) {
    if (level.severity < minimumLevel.severity) return;
    final LogRecord record = LogRecord(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: scrub(message),
      error: error,
      stackTrace: stackTrace,
    );
    history.addLast(record);
    while (history.length > historyLimit) {
      history.removeFirst();
    }
    for (final LogSink sink in List<LogSink>.of(_sinks)) {
      sink(record);
    }
    // ignore: avoid_print
    print(record);
  }
}
