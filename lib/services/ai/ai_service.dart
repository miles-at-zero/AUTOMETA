import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/security/secret_store.dart';
import '../../core/utils/logger.dart';
import 'ai_provider.dart';
import 'openai_compatible_provider.dart';

/// User-facing AI configuration. Mirrors the Settings screen (spec §29).
@immutable
class AiSettings {
  const AiSettings({
    this.providerId = AiProviderId.localTemplates,
    this.model = '',
    this.temperature = 0.7,
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKeyStored = false,
  });

  final AiProviderId providerId;
  final String model;
  final double temperature;
  final String baseUrl;

  /// Whether a key exists in the secret store. The key itself never leaves it.
  final bool apiKeyStored;

  AiSettings copyWith({
    AiProviderId? providerId,
    String? model,
    double? temperature,
    String? baseUrl,
    bool? apiKeyStored,
  }) =>
      AiSettings(
        providerId: providerId ?? this.providerId,
        model: model ?? this.model,
        temperature: temperature ?? this.temperature,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKeyStored: apiKeyStored ?? this.apiKeyStored,
      );
}

/// Facade over the registered [AiProvider]s.
///
/// This is the only thing the rest of the app talks to, which is what keeps
/// the vendor swappable. It refuses to silently substitute a different
/// provider: if the configured one is unavailable the caller gets a failure it
/// can show, rather than output labelled with the wrong engine.
class AiService {
  AiService({
    required this.registry,
    required this.secrets,
    required AiSettings initial,
  }) : _settings = initial;

  final AiProviderRegistry registry;
  final SecretStore secrets;
  AiSettings _settings;

  final Logger _log = Logger.withTag(LogTags.ai);

  AiSettings get settings => _settings;

  void updateSettings(AiSettings settings) => _settings = settings;

  AiProvider? get activeProvider => registry.byId(_settings.providerId);

  /// True when the configured provider can actually produce text.
  Future<bool> get isReady async {
    final AiProvider? provider = activeProvider;
    if (provider == null) return false;
    if (provider.id.requiresApiKey && !_settings.apiKeyStored) return false;
    return true;
  }

  /// Short status line for the dashboard's "AI" chip.
  Future<String> statusLabel() async {
    final AiProvider? provider = activeProvider;
    if (provider == null) return 'Not configured';
    if (provider.id.requiresApiKey && !_settings.apiKeyStored) return 'Needs API key';
    return provider.id == AiProviderId.localTemplates
        ? 'On-device templates'
        : (_settings.model.isEmpty ? provider.defaultModel : _settings.model);
  }

  /// Runs a prompt through the configured provider.
  ///
  /// Throws [AiProviderException] for expected failures; the AI step executor
  /// turns those into a step failure with a readable reason.
  Future<AiCompletion> complete(AiPrompt prompt) async {
    final AiProvider? provider = activeProvider;
    if (provider == null) {
      throw const AiProviderException('No AI provider is configured', code: 'ai.not_configured');
    }
    if (provider.id.requiresApiKey && !_settings.apiKeyStored) {
      throw const AiProviderException(
        'No AI API key is stored. Add one in Settings → AI Provider, '
        'or switch to On-device templates.',
        code: 'ai.no_key',
      );
    }
    final AiCompletion completion = await provider.complete(prompt);
    _log.info('Completed ${prompt.task.wire} with ${completion.providerId.wire}');
    return completion;
  }

  /// Verification used by the Connections page. Never logs the key.
  Future<AiAvailability> check() async {
    final AiProvider? provider = activeProvider;
    if (provider == null) {
      return const AiAvailability(available: false, label: 'Not configured');
    }
    return provider.check();
  }

  Future<void> saveApiKey(String key) async {
    if (key.trim().isEmpty) {
      await secrets.delete(SecretKeys.aiApiKey);
      _settings = _settings.copyWith(apiKeyStored: false);
      return;
    }
    await secrets.write(SecretKeys.aiApiKey, key.trim());
    _settings = _settings.copyWith(apiKeyStored: true);
    _log.info('AI API key stored (${Logger.redact(key.trim())})');
  }

  Future<void> clearApiKey() async {
    await secrets.delete(SecretKeys.aiApiKey);
    _settings = _settings.copyWith(apiKeyStored: false);
  }
}
