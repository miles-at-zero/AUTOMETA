// AUTOMETA core constants.
//
// Single source of truth for values that must stay identical between the
// engine, the scheduler, the UI and the tests.
library;

class AppInfo {
  const AppInfo._();

  static const String name = 'AUTOMETA';
  static const String tagline = 'Trigger → Intelligence → Action';
  static const String version = '0.9.0'; // Keep in sync with pubspec.yaml (0.9.0+9: V1 beta candidate).
}

/// Limits that keep the engine from hurting itself or the user's device.
class EngineLimits {
  const EngineLimits._();

  /// Hard ceiling on steps in a single workflow definition.
  static const int maxStepsPerWorkflow = 64;

  /// Hard ceiling on nested condition branches evaluated in one run.
  static const int maxConditionDepth = 12;

  /// A `WAIT` step may never park a run longer than this.
  static const Duration maxDelayStep = Duration(hours: 12);

  /// Total wall-clock budget for a single workflow run, delays included.
  static const Duration maxRunDuration = Duration(hours: 24);

  /// Upper bound for user-configurable retries (spec §22: never retry forever).
  static const int maxRetries = 5;
  static const int defaultRetries = 2;

  /// Base backoff between retry attempts.
  static const Duration retryBaseBackoff = Duration(seconds: 30);

  /// A queued approval expires; a stale approval must never fire silently.
  static const Duration approvalTtl = Duration(hours: 24);
}

/// Stable identifiers for the built-in integrations.
class IntegrationIds {
  const IntegrationIds._();

  static const String whatsapp = 'whatsapp';
  static const String notification = 'notification';
  static const String ai = 'ai';
  static const String http = 'http';
  static const String webhook = 'webhook';
  static const String clipboard = 'clipboard';
  static const String openUrl = 'open_url';
}

/// Keys used in the key/value settings table and in `SharedPreferences`.
class SettingKeys {
  const SettingKeys._();

  static const String paused = 'engine.paused';
  static const String onboardingComplete = 'onboarding.complete';
  static const String themeMode = 'ui.theme_mode';
  static const String defaultRecipientName = 'contacts.default_name';
  static const String aiProviderId = 'ai.provider_id';
  static const String aiModel = 'ai.model';
  static const String aiTemperature = 'ai.temperature';
  static const String aiBaseUrl = 'ai.base_url';
  static const String developerMode = 'dev.mode';
  static const String deviceToken = 'webhook.device_token';
  static const String batteryWarningDismissed = 'warnings.battery_dismissed';
}

/// Secret-store keys. Values live in Android Keystore backed storage only.
class SecretKeys {
  const SecretKeys._();

  static const String aiApiKey = 'ai.api_key';
  static const String whatsappBusinessToken = 'whatsapp.business.access_token';
  static const String whatsappBusinessPhoneId = 'whatsapp.business.phone_number_id';
  static const String whatsappBusinessAppSecret = 'whatsapp.business.app_secret';
  static const String whatsappBusinessVerifyToken = 'whatsapp.business.webhook_verify_token';
}

/// Log tags. Keep them short; they are prefixed onto every engine log line.
class LogTags {
  const LogTags._();

  static const String engine = 'ENGINE';
  static const String scheduler = 'SCHED';
  static const String whatsapp = 'WHATSAPP';
  static const String ai = 'AI';
  static const String db = 'DB';
  static const String notify = 'NOTIFY';
  static const String approval = 'APPROVAL';
  static const String ui = 'UI';
}
