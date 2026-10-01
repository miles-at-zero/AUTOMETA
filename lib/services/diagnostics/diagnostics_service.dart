import 'dart:convert';

import 'package:flutter/services.dart';

import '../../data/repositories/settings_repository.dart';
import '../scheduler/alarm_platform.dart';

/// One delivered alarm: what it was for, when it should have fired, and when
/// Android actually delivered it.
class AlarmFire {
  const AlarmFire({required this.label, required this.scheduledFor, required this.firedAt, this.test = false});

  final String label;
  final DateTime scheduledFor;
  final DateTime firedAt;
  final bool test;

  Duration get late => firedAt.difference(scheduledFor);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'scheduled': scheduledFor.toUtc().toIso8601String(),
        'fired': firedAt.toUtc().toIso8601String(),
        'test': test,
      };

  static AlarmFire? fromJson(Object? json) {
    if (json is! Map) return null;
    final DateTime? s = DateTime.tryParse('${json['scheduled']}');
    final DateTime? f = DateTime.tryParse('${json['fired']}');
    if (s == null || f == null) return null;
    return AlarmFire(label: '${json['label']}', scheduledFor: s, firedAt: f, test: json['test'] == true);
  }
}

/// Device facts that decide whether background automation is reliable.
class DeviceReliability {
  const DeviceReliability({
    this.manufacturer = '',
    this.model = '',
    this.sdk = 0,
    this.exactAlarmsAllowed = true,
    this.batteryOptimized = false,
    this.notificationsAllowed = true,
  });

  final String manufacturer;
  final String model;
  final int sdk;
  final bool exactAlarmsAllowed;
  final bool batteryOptimized;
  final bool notificationsAllowed;

  /// Infinix, Tecno and itel run Transsion's XOS/HiOS, which also needs
  /// "Auto-start" allowed and the app locked in recents.
  bool get isTranssion {
    final String m = manufacturer.toLowerCase();
    return m.contains('infinix') || m.contains('tecno') || m.contains('itel') || m.contains('transsion');
  }

  bool get hasAggressiveOem {
    final String m = manufacturer.toLowerCase();
    return isTranssion ||
        <String>['xiaomi', 'redmi', 'poco', 'oppo', 'realme', 'vivo', 'huawei', 'honor', 'oneplus', 'samsung']
            .any(m.contains);
  }
}

/// Stores alarm delivery history (in the settings table, so the background
/// isolate can write it too) and schedules self-test alarms.
class DiagnosticsService {
  DiagnosticsService({required this.settings, required this.platform});

  final SettingsRepository settings;
  final AlarmPlatform platform;

  static const String _logKey = 'diagnostics.alarm_log';
  static const int _keep = 60;
  static const int testAlarmId = 0x7FFFFFE0;
  static const MethodChannel _channel = MethodChannel('dev.autometa/platform');

  Future<List<AlarmFire>> history() async {
    final String? raw = await settings.get(_logKey);
    if (raw == null || raw.isEmpty) return <AlarmFire>[];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list.map(AlarmFire.fromJson).whereType<AlarmFire>().toList();
    } catch (_) {
      return <AlarmFire>[];
    }
  }

  Future<void> record(AlarmFire fire) async {
    final List<AlarmFire> list = <AlarmFire>[fire, ...await history()];
    await settings.set(_logKey, jsonEncode(list.take(_keep).map((AlarmFire f) => f.toJson()).toList()));
  }

  Future<void> clear() => settings.remove(_logKey);

  /// Arms a real AlarmManager alarm through exactly the same path automations use.
  Future<DateTime> scheduleTest(Duration inFromNow, {String label = 'Reliability test'}) async {
    final DateTime when = DateTime.now().add(inFromNow);
    await platform.scheduleOnce(
      id: testAlarmId,
      when: when,
      payload: <String, String>{
        'reason': 'diag_test',
        'label': label,
        'scheduled_for': when.toUtc().toIso8601String(),
      },
    );
    await settings.set('diagnostics.pending_test', jsonEncode(<String, String>{
      'label': label,
      'at': when.toUtc().toIso8601String(),
    }));
    return when;
  }

  Future<(String, DateTime)?> pendingTest() async {
    final String? raw = await settings.get('diagnostics.pending_test');
    if (raw == null) return null;
    try {
      final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
      final DateTime? at = DateTime.tryParse('${m['at']}');
      return at == null ? null : ('${m['label']}', at);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPendingTest() => settings.remove('diagnostics.pending_test');

  Future<void> cancelTest() async {
    await platform.cancel(testAlarmId);
    await clearPendingTest();
  }

  Future<DeviceReliability> device() async {
    Map<dynamic, dynamic>? info;
    bool exact = true;
    try {
      info = await _channel.invokeMapMethod<dynamic, dynamic>('deviceInfo');
      exact = await _channel.invokeMethod<bool>('canScheduleExactAlarms') ?? true;
    } catch (_) {}
    return DeviceReliability(
      manufacturer: '${info?['manufacturer'] ?? ''}',
      model: '${info?['model'] ?? ''}',
      sdk: (info?['sdk'] as int?) ?? 0,
      exactAlarmsAllowed: exact,
      batteryOptimized: !(await platform.isIgnoringBatteryOptimizations),
      notificationsAllowed: await platform.notificationsPermitted,
    );
  }

  Future<void> openExactAlarmSettings() => _invoke('openExactAlarmSettings');
  Future<bool> openAutostartSettings() async => await _invoke('openAutostartSettings') == true;
  Future<void> openAppDetails() => _invoke('openAppDetails');

  Future<Object?> _invoke(String method) async {
    try {
      return await _channel.invokeMethod<Object?>(method);
    } catch (_) {
      return null;
    }
  }
}
