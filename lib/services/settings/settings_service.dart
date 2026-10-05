import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/engine/engine_ports.dart';
import '../../domain/models/execution_mode.dart';
import '../notifications/notification_service.dart';
import '../scheduler/alarm_platform.dart';

/// Read/write facade over the settings table.
///
/// Implements [EngineStateProvider] so the engine sees exactly what the
/// settings screen writes, with no duplicated state.
class SettingsService extends ChangeNotifier implements EngineStateProvider {
  SettingsService({
    required this.repository,
    required this.variables,
    required this.platform,
  });

  final SettingsRepository repository;
  final VariableRepository variables;
  final AlarmPlatform platform;

  final Logger _log = Logger.withTag('SETTINGS');

  bool _paused = false;
  String _defaultRecipient = 'Dad';
  bool _onboardingComplete = false;
  bool _developerMode = false;
  bool _notificationsPermitted = true;
  bool _batteryOptimized = true;
  bool _loaded = false;
  Map<String, String> _customVariables = <String, String>{};
  NotificationPreferences _notificationPreferences = const NotificationPreferences();
  String? _timeZone;
  ExecutionMode _defaultExecution = ExecutionMode.recommended;

  static const String defaultExecutionKey = 'execution.default_mode';

  /// Mode pre-selected for NEW automations. Never changes existing ones.
  ExecutionMode get defaultExecution => _defaultExecution;

  Future<void> setDefaultExecution(ExecutionMode mode) async {
    _defaultExecution = mode;
    await repository.set(defaultExecutionKey, mode.wire);
    notifyListeners();
  }

  bool get loaded => _loaded;

  @override
  bool get isPaused => _paused;

  @override
  String get defaultRecipientName => _defaultRecipient;

  @override
  Map<String, String> get runtimeVariables => Map<String, String>.unmodifiable(_customVariables);

  @override
  bool get notificationsPermitted => _notificationsPermitted;

  bool get onboardingComplete => _onboardingComplete;
  bool get developerMode => _developerMode;
  bool get batteryOptimized => _batteryOptimized;
  String? get timeZone => _timeZone;
  NotificationPreferences get notificationPreferences => _notificationPreferences;

  Future<void> load() async {
    final Map<String, String> all = await repository.all();
    _paused = all[SettingKeys.paused] == 'true';
    _defaultRecipient = all[SettingKeys.defaultRecipientName] ?? 'Dad';
    _onboardingComplete = all[SettingKeys.onboardingComplete] == 'true';
    _developerMode = all[SettingKeys.developerMode] == 'true';
    _notificationPreferences = NotificationPreferences.fromMap(all);
    _customVariables = await variables.all();
    _defaultExecution = ExecutionMode.fromWire(all[defaultExecutionKey], fallback: ExecutionMode.recommended);

    try {
      _notificationsPermitted = await platform.notificationsPermitted;
      _batteryOptimized = !(await platform.isIgnoringBatteryOptimizations);
    } catch (error) {
      _log.warn('Could not read platform permission state', error);
    }

    _timeZone = await platform.deviceTimeZone();
    _loaded = true;
    notifyListeners();
  }

  Future<void> setPaused(bool value) async {
    _paused = value;
    await repository.setBool(SettingKeys.paused, value);
    _log.info(value ? 'ALL AUTOMATIONS PAUSED' : 'Automations resumed');
    notifyListeners();
  }

  Future<void> setDefaultRecipient(String name) async {
    _defaultRecipient = name.trim().isEmpty ? 'Dad' : name.trim();
    await repository.set(SettingKeys.defaultRecipientName, _defaultRecipient);
    notifyListeners();
  }

  Future<void> setOnboardingComplete(bool value) async {
    _onboardingComplete = value;
    await repository.setBool(SettingKeys.onboardingComplete, value);
    notifyListeners();
  }

  Future<void> setDeveloperMode(bool value) async {
    _developerMode = value;
    await repository.setBool(SettingKeys.developerMode, value);
    notifyListeners();
  }

  Future<void> setNotificationPreferences(NotificationPreferences preferences) async {
    _notificationPreferences = preferences;
    for (final MapEntry<String, String> entry in preferences.toMap().entries) {
      await repository.set(entry.key, entry.value);
    }
    notifyListeners();
  }

  Future<void> refreshPlatformState() async {
    try {
      _notificationsPermitted = await platform.notificationsPermitted;
      _batteryOptimized = !(await platform.isIgnoringBatteryOptimizations);
    } catch (_) {
      // Non-fatal; the UI keeps the previous values.
    }
    notifyListeners();
  }

  Future<void> reloadCustomVariables() async {
    _customVariables = await variables.all();
    notifyListeners();
  }

  Future<void> setCustomVariable(String name, String value) async {
    await variables.put(name, value);
    await reloadCustomVariables();
  }

  Future<void> removeCustomVariable(String name) async {
    await variables.delete(name);
    await reloadCustomVariables();
  }
}
