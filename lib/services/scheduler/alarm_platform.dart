import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Port to the OS scheduling primitives.
///
/// Everything the app promises about background behaviour goes through this
/// interface, so the scheduler can be unit-tested with a fake and so iOS can
/// be supported later by adding another implementation (spec §27, §2).
abstract class AlarmPlatform {
  const AlarmPlatform();

  /// False when the platform cannot schedule anything (unsupported OS, or the
  /// plugin failed to initialise). The UI must then say so.
  Future<bool> get isAvailable;

  /// Schedules a one-shot wake at an exact wall-clock instant.
  ///
  /// [id] must be stable for the workflow so re-arming replaces rather than
  /// duplicates the alarm.
  Future<void> scheduleOnce({
    required int id,
    required DateTime when,
    required Map<String, String> payload,
  });

  /// Repeating maintenance wake (re-arms anything that drifted or was lost).
  Future<void> scheduleRepeating({
    required int id,
    required DateTime first,
    required Duration period,
    required Map<String, String> payload,
  });

  Future<void> cancel(int id);

  Future<void> cancelAll();

  /// Whether the app is exempt from Android battery optimisation. When false,
  /// exact alarms can still be deferred by Doze — the UI must warn about this
  /// rather than promise punctuality.
  Future<bool> get isIgnoringBatteryOptimizations;

  /// Sends the user to the system dialog. The OS shows it; we cannot grant it.
  Future<void> requestIgnoreBatteryOptimizations();

  /// Whether the given Android package is installed.
  Future<bool> isPackageInstalled(String packageName);

  /// Whether notifications are permitted (Android 13+).
  Future<bool> get notificationsPermitted;

  Future<bool> requestNotificationPermission();

  /// Device IANA time zone name, or null when it cannot be determined.
  Future<String?> deviceTimeZone();
}

/// AlarmManager-backed implementation for Android.
///
/// Bound through a small MethodChannel implemented in `MainActivity.kt` rather
/// than pulling in more plugins: battery-optimisation state and package
/// visibility are two lines of Kotlin and are the difference between the app
/// being able to tell the truth about its reliability and not.
class AndroidAlarmPlatform extends AlarmPlatform {
  AndroidAlarmPlatform({
    required Future<void> Function({required int id, required DateTime when, Map<String, String>? payload})
        scheduleOnceImpl,
    required Future<void> Function({
      required int id,
      required DateTime first,
      required Duration period,
      Map<String, String>? payload,
    }) scheduleRepeatingImpl,
    required Future<void> Function(int id) cancelImpl,
    required Future<void> Function() cancelAllImpl,
    required Future<bool> Function() availableImpl,
  })  : _scheduleOnce = scheduleOnceImpl,
        _scheduleRepeating = scheduleRepeatingImpl,
        _cancel = cancelImpl,
        _cancelAll = cancelAllImpl,
        _available = availableImpl;

  static const MethodChannel _channel = MethodChannel('dev.autometa/platform');

  final Future<void> Function({required int id, required DateTime when, Map<String, String>? payload})
      _scheduleOnce;
  final Future<void> Function({
    required int id,
    required DateTime first,
    required Duration period,
    Map<String, String>? payload,
  }) _scheduleRepeating;
  final Future<void> Function(int id) _cancel;
  final Future<void> Function() _cancelAll;
  final Future<bool> Function() _available;

  @override
  Future<bool> get isAvailable => _available();

  @override
  Future<void> scheduleOnce({
    required int id,
    required DateTime when,
    required Map<String, String> payload,
  }) =>
      _scheduleOnce(id: id, when: when, payload: payload);

  @override
  Future<void> scheduleRepeating({
    required int id,
    required DateTime first,
    required Duration period,
    required Map<String, String> payload,
  }) =>
      _scheduleRepeating(id: id, first: first, period: period, payload: payload);

  @override
  Future<void> cancel(int id) => _cancel(id);

  @override
  Future<void> cancelAll() => _cancelAll();

  @override
  Future<bool> get isIgnoringBatteryOptimizations async {
    try {
      final bool? value =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return value ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } on PlatformException {
      // Ignored: the user declined or the OEM does not expose the dialog.
    } on MissingPluginException {
      // Ignored in unit tests.
    }
  }

  @override
  Future<bool> isPackageInstalled(String packageName) async {
    try {
      final bool? value =
          await _channel.invokeMethod<bool>('isPackageInstalled', <String, String>{
        'package': packageName,
      });
      return value ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> get notificationsPermitted async {
    try {
      final bool? value = await _channel.invokeMethod<bool>('notificationsPermitted');
      return value ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      final bool? value = await _channel.invokeMethod<bool>('requestNotificationPermission');
      return value ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<String?> deviceTimeZone() async {
    try {
      return await _channel.invokeMethod<String>('deviceTimeZone');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Used on unsupported platforms and in tests. Reports itself honestly as
/// unavailable so the UI shows "Scheduling not available on this platform"
/// instead of pretending automations will run.
class UnavailableAlarmPlatform extends AlarmPlatform {
  const UnavailableAlarmPlatform({this.reason = 'Scheduling is not available on this platform'});

  final String reason;

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<void> scheduleOnce({
    required int id,
    required DateTime when,
    required Map<String, String> payload,
  }) async {}

  @override
  Future<void> scheduleRepeating({
    required int id,
    required DateTime first,
    required Duration period,
    required Map<String, String> payload,
  }) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> get isIgnoringBatteryOptimizations async => false;

  @override
  Future<void> requestIgnoreBatteryOptimizations() async {}

  @override
  Future<bool> isPackageInstalled(String packageName) async => false;

  @override
  Future<bool> get notificationsPermitted async => false;

  @override
  Future<bool> requestNotificationPermission() async => false;

  @override
  Future<String?> deviceTimeZone() async => null;
}

/// Records every arm/cancel so the developer screen can show exactly what was
/// handed to the OS.
class RecordingAlarmPlatform extends AlarmPlatform {
  RecordingAlarmPlatform({this.available = true});

  bool available;
  final List<String> events = <String>[];
  final Map<int, DateTime> scheduled = <int, DateTime>{};
  final Set<int> cancelled = <int>{};

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<void> scheduleOnce({
    required int id,
    required DateTime when,
    required Map<String, String> payload,
  }) async {
    scheduled[id] = when;
    events.add('once:$id@${when.toIso8601String()}');
  }

  @override
  Future<void> scheduleRepeating({
    required int id,
    required DateTime first,
    required Duration period,
    required Map<String, String> payload,
  }) async {
    scheduled[id] = first;
    events.add('repeat:$id@${first.toIso8601String()}/+${period.inMinutes}m');
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
    events.add('cancel:$id');
  }

  @override
  Future<void> cancelAll() async {
    cancelled.addAll(scheduled.keys);
    scheduled.clear();
    events.add('cancelAll');
  }

  @override
  Future<bool> get isIgnoringBatteryOptimizations async => true;

  @override
  Future<void> requestIgnoreBatteryOptimizations() async {}

  @override
  Future<bool> isPackageInstalled(String packageName) async => true;

  @override
  Future<bool> get notificationsPermitted async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<String?> deviceTimeZone() async => 'UTC';
}

/// Stable 31-bit alarm id derived from a workflow id.
///
/// AlarmManager ids are ints; workflow ids are UUID strings. FNV-1a over the
/// UUID keeps the mapping deterministic across app restarts, which is what
/// allows re-arming to replace an existing alarm instead of stacking up.
int alarmIdFor(String workflowId) {
  const int offset = 0x811c9dc5;
  const int prime = 0x01000193;
  int hash = offset;
  for (final int byte in workflowId.codeUnits) {
    hash = (hash ^ (byte & 0xFF)) & 0xFFFFFFFF;
    hash = (hash * prime) & 0xFFFFFFFF;
  }
  return hash & 0x3FFFFFFF; // below the reserved 0x7FFFFFFx ids
}

/// Reserved ids that must never collide with a workflow alarm.
class AlarmIds {
  const AlarmIds._();

  /// Hourly maintenance: re-arms anything the OS dropped and catches up runs
  /// that were deferred by Doze.
  static const int maintenance = 0x7FFFFFF0;

  /// Boot resync.
  static const int bootResync = 0x7FFFFFF1;
}

/// Keeps the platform binding visible to the compiler even when the app runs
/// on a host VM during tests.
@visibleForTesting
const MethodChannel debugPlatformChannel = AndroidAlarmPlatform._channel;
