import 'dart:convert';

import '../../core/constants/app_constants.dart';
import '../../core/security/secret_store.dart';
import '../../core/utils/logger.dart';
import '../net/api_client.dart';
import 'ai_provider.dart';
import 'openai_compatible_provider.dart';
import 'prompts.dart';

/// Anthropic Messages API.
///
/// `POST https://api.anthropic.com/v1/messages` with
/// `x-api-key`, `anthropic-version: 2023-06-01` and
/// `{"model": "...", "max_tokens": N, "system": "...", "messages": [...]}`.
class AnthropicProvider extends AiProvider {
  AnthropicProvider({
    required this.apiClient,
    required this.secrets,
    this.model = 'claude-sonnet-4-5',
    this.temperature = 0.7,
    this.baseUrl = 'https://api.anthropic.com',
  });

  final ApiClient apiClient;
  final SecretStore secrets;
  final String model;
  final double temperature;
  final String baseUrl;

  /// Anthropic requires this header on every request.
  static const String apiVersion = '2023-06-01';

  final Logger _log = Logger.withTag(LogTags.ai);

  @override
  AiProviderId get id => AiProviderId.anthropic;

  @override
  String get defaultModel => 'claude-sonnet-4-5';

  @override
  List<String> get suggestedModels => const <String>[
        'claude-sonnet-4-5',
        'claude-opus-4-1',
        'claude-haiku-4-5',
      ];

  String get _endpoint =>
      '${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/v1/messages';

  Map<String, String> _headers(String key) => <String, String>{
        'x-api-key': key,
        'anthropic-version': apiVersion,
        'Content-Type': 'application/json',
      };

  @override
  Future<AiAvailability> check() async {
    final String? key = await secrets.read(SecretKeys.aiApiKey);
    if (key == null || key.isEmpty) {
      return AiAvailability(
        available: false,
        label: 'No API key stored',
        detail: 'Add an Anthropic API key in Settings → AI Provider',
        models: suggestedModels,
      );
    }

    final ApiResponse response = await apiClient.send(ApiRequest(
      method: 'POST',
      url: _endpoint,
      headers: _headers(key),
      body: jsonEncode(<String, dynamic>{
        'model': model.isEmpty ? defaultModel : model,
        'max_tokens': 8,
        'messages': <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'Reply with the single word: ok'},
        ],
      }),
      timeout: const Duration(seconds: 20),
    ));

    if (!response.reachedServer) {
      return AiAvailability(
        available: false,
        label: 'Endpoint unreachable',
        detail: response.transportError ?? 'Could not reach Anthropic',
        models: suggestedModels,
      );
    }
    if (response.statusCode == 401) {
      return const AiAvailability(
        available: false,
        label: 'API key rejected',
        detail: 'Anthropic returned 401 for that key',
      );
    }
    if (!response.isSuccess) {
      return AiAvailability(
        available: false,
        label: 'HTTP ${response.statusCode}',
        detail: response.errorMessage,
        models: suggestedModels,
      );
    }
    return AiAvailability(
      available: true,
      label: model.isEmpty ? defaultModel : model,
      detail: 'Anthropic responded',
      models: suggestedModels,
    );
  }

  @override
  Future<AiCompletion> complete(AiPrompt prompt) async {
    final String? key = await secrets.read(SecretKeys.aiApiKey);
    if (key == null || key.isEmpty) {
      throw const AiProviderException('No AI API key is stored', code: 'ai.no_key');
    }

    final ApiResponse response = await apiClient.send(ApiRequest(
      method: 'POST',
      url: _endpoint,
      headers: _headers(key),
      body: jsonEncode(<String, dynamic>{
        'model': model.isEmpty ? defaultModel : model,
        'max_tokens': (prompt.maxLength * 2).clamp(64, 2048),
        'temperature': temperature.clamp(0, 1),
        'system': AiPrompts.systemFor(prompt),
        'messages': <Map<String, String>>[
          <String, String>{'role': 'user', 'content': AiPrompts.userFor(prompt)},
        ],
      }),
    ));

    if (!response.reachedServer) {
      throw AiProviderException(
        response.transportError ?? 'Could not reach Anthropic',
        code: 'ai.transport',
        retriable: true,
      );
    }
    if (!response.isSuccess) {
      throw AiProviderException(
        'AI request failed (${response.statusCode}): ${response.errorMessage}',
        code: 'ai.http_${response.statusCode}',
        retriable: response.statusCode == 429 || response.statusCode >= 500,
      );
    }

    final Map<String, dynamic> json = response.json;
    final List<dynamic> content = (json['content'] as List<dynamic>?) ?? <dynamic>[];
    final String text = content
        .whereType<Map<String, dynamic>>()
        .where((Map<String, dynamic> block) => block['type'] == 'text')
        .map((Map<String, dynamic> block) => '${block['text'] ?? ''}')
        .join()
        .trim();

    if (text.isEmpty) {
      throw const AiProviderException('The model returned an empty response', code: 'ai.empty');
    }

    final Map<String, dynamic> usage = (json['usage'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    _log.info('AI completion via ${id.wire} (${text.length} chars)');
    return AiCompletion(
      text: text,
      providerId: id,
      model: '${json['model'] ?? model}',
      promptTokens: usage['input_tokens'] is int ? usage['input_tokens'] as int : 0,
      completionTokens: usage['output_tokens'] is int ? usage['output_tokens'] as int : 0,
    );
  }
}
