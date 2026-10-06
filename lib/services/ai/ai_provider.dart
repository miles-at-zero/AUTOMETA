import 'package:flutter/foundation.dart';

import '../../domain/models/step.dart';

/// Which AI backend AUTOMETA is talking to (spec §29).
enum AiProviderId {
  /// Any OpenAI-compatible `/chat/completions` endpoint: OpenAI, Groq,
  /// OpenRouter, Together, a local Ollama server.
  openAiCompatible('openai_compatible', 'OpenAI-compatible API', true),

  /// Anthropic Messages API.
  anthropic('anthropic', 'Anthropic', true),

  /// Deterministic, on-device text composition. Not a language model — it is
  /// offered so automations keep working without a key, and it is always
  /// labelled as such.
  localTemplates('local_templates', 'On-device templates', false);

  const AiProviderId(this.wire, this.label, this.requiresApiKey);

  final String wire;
  final String label;
  final bool requiresApiKey;

  static AiProviderId fromWire(Object? value, {AiProviderId fallback = localTemplates}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final AiProviderId id in AiProviderId.values) {
      if (id.wire == raw || id.name.toLowerCase() == raw) return id;
    }
    return fallback;
  }
}

/// What the AI block is being asked for.
@immutable
class AiPrompt {
  const AiPrompt({
    required this.task,
    required this.instruction,
    this.input = '',
    this.tone = 'Warm',
    this.maxLength = 240,
    this.systemContext = '',
  });

  final AiTask task;
  final String instruction;
  final String input;
  final String tone;
  final int maxLength;

  /// Extra grounding supplied by the workflow (date, recipient, variables).
  final String systemContext;

  /// Structured-data tasks must come back as JSON.
  bool get wantsJson => task == AiTask.structured || task == AiTask.extract;

  AiPrompt copyWith({String? instruction, String? input, String? tone, int? maxLength}) => AiPrompt(
        task: task,
        instruction: instruction ?? this.instruction,
        input: input ?? this.input,
        tone: tone ?? this.tone,
        maxLength: maxLength ?? this.maxLength,
        systemContext: systemContext,
      );
}

@immutable
class AiCompletion {
  const AiCompletion({
    required this.text,
    required this.providerId,
    this.model = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  final String text;
  final AiProviderId providerId;
  final String model;
  final int promptTokens;
  final int completionTokens;

  bool get isEmpty => text.trim().isEmpty;
}

@immutable
class AiAvailability {
  const AiAvailability({
    required this.available,
    required this.label,
    this.detail = '',
    this.models = const <String>[],
  });

  final bool available;
  final String label;
  final String detail;
  final List<String> models;
}

/// The AI abstraction (spec §29).
///
/// Nothing outside this folder knows which vendor is in use, and no
/// implementation is permitted to write an API key to a log — the key is read
/// from [SecretStore] and passed straight into a request header.
abstract class AiProvider {
  const AiProvider();

  AiProviderId get id;

  /// Default model used when the user has not chosen one.
  String get defaultModel;

  /// Models offered in the settings picker. Always editable, because vendors
  /// add and retire models faster than an app release cycle.
  List<String> get suggestedModels;

  /// Live verification. A missing key must report `available == false` with a
  /// reason, never a silent fallback to another provider.
  Future<AiAvailability> check();

  Future<AiCompletion> complete(AiPrompt prompt);
}

/// Registry of AI backends.
class AiProviderRegistry {
  AiProviderRegistry([Iterable<AiProvider>? providers]) {
    if (providers != null) {
      for (final AiProvider provider in providers) {
        register(provider);
      }
    }
  }

  final Map<AiProviderId, AiProvider> _byId = <AiProviderId, AiProvider>{};

  void register(AiProvider provider) => _byId[provider.id] = provider;

  AiProvider? byId(AiProviderId id) => _byId[id];

  List<AiProvider> get all => _byId.values.toList(growable: false);
}
