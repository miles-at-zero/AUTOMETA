import 'dart:convert';

import '../../core/constants/app_constants.dart';
import '../../core/security/secret_store.dart';
import '../../core/utils/logger.dart';
import '../net/api_client.dart';
import 'ai_provider.dart';
import 'prompts.dart';

/// Any OpenAI-compatible chat completions endpoint.
///
/// `POST {baseUrl}/chat/completions` with
/// `{"model": "...", "messages": [{"role": "user", "content": "..."}],
///   "temperature": 0.7, "max_tokens": 512, "response_format": {...}}`.
///
/// Changing [baseUrl] is all it takes to point at Groq, OpenRouter, Together or
/// a local Ollama server, which is why AUTOMETA does not hard-wire a vendor.
class OpenAiCompatibleProvider extends AiProvider {
  OpenAiCompatibleProvider({
    required this.apiClient,
    required this.secrets,
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    this.temperature = 0.7,
  });

  final ApiClient apiClient;
  final SecretStore secrets;
  final String baseUrl;
  final String model;
  final double temperature;

  final Logger _log = Logger.withTag(LogTags.ai);

  @override
  AiProviderId get id => AiProviderId.openAiCompatible;

  @override
  String get defaultModel => 'gpt-4o-mini';

  @override
  List<String> get suggestedModels => const <String>[
        'gpt-4o-mini',
        'gpt-4o',
        'gpt-4.1-mini',
        'llama-3.3-70b-versatile',
        'mixtral-8x7b-32768',
        'qwen2.5-72b-instruct',
      ];

  String get _normalizedBaseUrl {
    final String trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? 'https://api.openai.com/v1' : trimmed;
  }

  @override
  Future<AiAvailability> check() async {
    final String? key = await secrets.read(SecretKeys.aiApiKey);
    if (key == null || key.isEmpty) {
      return AiAvailability(
        available: false,
        label: 'No API key stored',
        detail: 'Add an API key in Settings → AI Provider',
        models: suggestedModels,
      );
    }

    final ApiResponse response = await apiClient.send(ApiRequest(
      method: 'POST',
      url: '$_normalizedBaseUrl/chat/completions',
      headers: <String, String>{
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'model': model.isEmpty ? defaultModel : model,
        'messages': <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'Reply with the single word: ok'},
        ],
        'max_tokens': 8,
        'temperature': 0,
      }),
      timeout: const Duration(seconds: 20),
    ));

    if (!response.reachedServer) {
      return AiAvailability(
        available: false,
        label: 'Endpoint unreachable',
        detail: response.transportError ?? 'Could not reach $_normalizedBaseUrl',
        models: suggestedModels,
      );
    }
    if (response.statusCode == 401) {
      return AiAvailability(
        available: false,
        label: 'API key rejected',
        detail: 'The endpoint returned 401. Check the key and the base URL.',
        models: suggestedModels,
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

    final List<dynamic> choices = (response.json['choices'] as List<dynamic>?) ?? <dynamic>[];
    final String probe = choices.isEmpty
        ? ''
        : '${((choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?)?['content'] ?? ''}';
    return AiAvailability(
      available: true,
      label: model.isEmpty ? defaultModel : model,
      detail: probe.trim().isEmpty ? 'Endpoint responded' : 'Endpoint responded to a probe',
      models: suggestedModels,
    );
  }

  @override
  Future<AiCompletion> complete(AiPrompt prompt) async {
    final String? key = await secrets.read(SecretKeys.aiApiKey);
    if (key == null || key.isEmpty) {
      throw AiProviderException('No AI API key is stored', code: 'ai.no_key');
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'model': model.isEmpty ? defaultModel : model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': AiPrompts.systemFor(prompt)},
        <String, String>{'role': 'user', 'content': AiPrompts.userFor(prompt)},
      ],
      'temperature': temperature.clamp(0, 2),
      'max_tokens': (prompt.maxLength * 2).clamp(64, 2048),
      if (prompt.wantsJson)
        'response_format': <String, String>{'type': 'json_object'},
    };

    final ApiResponse response = await apiClient.send(ApiRequest(
      method: 'POST',
      url: '$_normalizedBaseUrl/chat/completions',
      headers: <String, String>{
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    ));

    if (!response.reachedServer) {
      throw AiProviderException(
        response.transportError ?? 'Could not reach the AI endpoint',
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
    final List<dynamic> choices = (json['choices'] as List<dynamic>?) ?? <dynamic>[];
    if (choices.isEmpty) {
      throw AiProviderException('The AI endpoint returned no choices', code: 'ai.empty');
    }
    final Map<String, dynamic> message =
        ((choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?) ??
            <String, dynamic>{};
    final String text = '${message['content'] ?? ''}'.trim();
    final Map<String, dynamic> usage = (json['usage'] as Map<String, dynamic>?) ?? <String, dynamic>{};

    if (text.isEmpty) {
      throw AiProviderException('The model returned an empty response', code: 'ai.empty');
    }

    _log.info('AI completion via ${id.wire} (${text.length} chars)');
    return AiCompletion(
      text: text,
      providerId: id,
      model: '${json['model'] ?? model}',
      promptTokens: usage['prompt_tokens'] is int ? usage['prompt_tokens'] as int : 0,
      completionTokens: usage['completion_tokens'] is int ? usage['completion_tokens'] as int : 0,
    );
  }
}

/// Raised for expected AI failures so the engine can turn them into a
/// user-readable step failure instead of a stack trace.
class AiProviderException implements Exception {
  const AiProviderException(this.message, {this.code, this.retriable = false});

  final String message;
  final String? code;
  final bool retriable;

  @override
  String toString() => 'AiProviderException(${code ?? 'error'}): $message';
}
