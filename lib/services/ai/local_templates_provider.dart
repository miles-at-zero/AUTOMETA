import 'dart:convert';

import '../../domain/models/step.dart';
import 'ai_provider.dart';

/// On-device, deterministic text composition.
///
/// This is NOT a language model and it never claims to be: the connection card
/// reads "On-device templates", and every completion it produces is tagged
/// `providerId == localTemplates` so the UI can badge output as
/// `LOCAL TEMPLATES` rather than `AI`.
///
/// It exists so that automations keep working before the user has an API key,
/// and so the acceptance flows (Morning / Evening / Night Dad) can be built
/// and tested with no network at all.
class LocalTemplatesProvider extends AiProvider {
  const LocalTemplatesProvider();

  @override
  AiProviderId get id => AiProviderId.localTemplates;

  @override
  String get defaultModel => 'on-device-templates-v1';

  @override
  List<String> get suggestedModels => const <String>['on-device-templates-v1'];

  @override
  Future<AiAvailability> check() async => const AiAvailability(
        available: true,
        label: 'On-device templates',
        detail: 'No API key needed. Deterministic, offline, not a language model.',
        models: <String>['on-device-templates-v1'],
      );

  @override
  Future<AiCompletion> complete(AiPrompt prompt) async {
    final String text = switch (prompt.task) {
      AiTask.generate => _generate(prompt),
      AiTask.rewrite => _rewrite(prompt),
      AiTask.summarize => _summarize(prompt),
      AiTask.classify => _classify(prompt),
      AiTask.extract => _extract(prompt),
      AiTask.convert => _convert(prompt),
      AiTask.structured => _structured(prompt),
    };
    return AiCompletion(text: text, providerId: id, model: defaultModel);
  }

  // ---------------------------------------------------------------------------

  String _generate(AiPrompt prompt) {
    final String haystack = '${prompt.instruction} ${prompt.input}'.toLowerCase();
    final String period = _detectPeriod(haystack);
    final bool mentionsWeekend = haystack.contains('weekend');

    final List<String> openings = <String>[
      'Good $period',
      'Good $period to you',
      'Wishing you a good $period',
    ];
    final List<String> closings = <String>[
      'Hope the day treats you well.',
      'Take care of yourself today.',
      'Thinking of you.',
      'Hope today is a good one.',
    ];
    if (period == 'evening' || period == 'night') {
      closings.setAll(0, <String>[
        'Hope you had a good day.',
        'Rest well.',
        'Winding down here too.',
      ]);
    }
    if (mentionsWeekend) {
      closings.setAll(0, <String>['Enjoy the weekend.', 'Hope the weekend is restful.']);
    }

    final int seed = haystack.hashCode.abs();
    final String message = '${openings[seed % openings.length]}! '
        '${closings[(seed ~/ 7) % closings.length]}';
    return _clamp(message, prompt.maxLength);
  }

  String _rewrite(AiPrompt prompt) {
    final String source = prompt.input.trim().isEmpty ? prompt.instruction.trim() : prompt.input.trim();
    String text = source.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '';
    text = text[0].toUpperCase() + text.substring(1);
    if (!RegExp(r'[.!?]$').hasMatch(text)) text = '$text.';
    return _clamp(text, prompt.maxLength);
  }

  String _summarize(AiPrompt prompt) {
    final String source = prompt.input.trim().isEmpty ? prompt.instruction.trim() : prompt.input.trim();
    if (source.isEmpty) return '';
    final List<String> sentences = source
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();

    final StringBuffer buffer = StringBuffer();
    for (final String sentence in sentences) {
      if (buffer.length + sentence.length + 1 > prompt.maxLength) break;
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(sentence);
    }
    final String result = buffer.toString();
    return result.isEmpty ? _clamp(sentences.first, prompt.maxLength) : result;
  }

  String _classify(AiPrompt prompt) {
    final String text = '${prompt.input} ${prompt.instruction}'.toLowerCase();
    const Map<String, List<String>> signals = <String, List<String>>{
      'urgent': <String>['urgent', 'asap', 'immediately', 'emergency', 'now'],
      'question': <String>['?', 'how', 'what', 'why', 'when', 'can you'],
      'reminder': <String>['remind', 'reminder', 'don\'t forget', 'todo'],
      'greeting': <String>['hello', 'hi', 'good morning', 'good evening', 'good night'],
      'finance': <String>['invoice', 'payment', 'refund', 'price', 'cost', 'bill'],
    };
    String best = 'general';
    int bestScore = 0;
    signals.forEach((String label, List<String> words) {
      final int score = words.where(text.contains).length;
      if (score > bestScore) {
        bestScore = score;
        best = label;
      }
    });
    return best;
  }

  String _extract(AiPrompt prompt) {
    final String source = prompt.input.trim();
    final Map<String, Object?> extracted = <String, Object?>{
      'emails': RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+').allMatches(source).map((Match m) => m[0]).toList(),
      'numbers': RegExp(r'-?\d+(?:[.,]\d+)?').allMatches(source).map((Match m) => m[0]).toList(),
      'dates': RegExp(r'\d{4}-\d{2}-\d{2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}')
          .allMatches(source)
          .map((Match m) => m[0])
          .toList(),
      'urls': RegExp(r'https?://\S+').allMatches(source).map((Match m) => m[0]).toList(),
      'source': 'on-device pattern extraction',
    };
    return const JsonEncoder().convert(extracted);
  }

  String _convert(AiPrompt prompt) {
    final String source = prompt.input.trim();
    final String instruction = prompt.instruction.toLowerCase();
    if (instruction.contains('upper')) return source.toUpperCase();
    if (instruction.contains('lower')) return source.toLowerCase();
    if (instruction.contains('title')) {
      return source
          .split(' ')
          .map((String w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
    }
    if (instruction.contains('json')) {
      return const JsonEncoder().convert(<String, String>{'text': source});
    }
    if (instruction.contains('list') || instruction.contains('bullet')) {
      return source
          .split(RegExp(r'[\n;,]'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .map((String s) => '• $s')
          .join('\n');
    }
    return source;
  }

  String _structured(AiPrompt prompt) {
    final String source = prompt.input.trim().isEmpty ? prompt.instruction.trim() : prompt.input.trim();
    return const JsonEncoder().convert(<String, Object?>{
      'summary': _clamp(_summarize(prompt.copyWith(input: source)), 160),
      'category': _classify(prompt),
      'generated_by': 'on-device-templates-v1',
    });
  }

  // ---------------------------------------------------------------------------

  static String _detectPeriod(String haystack) {
    if (haystack.contains('night')) return 'night';
    if (haystack.contains('evening')) return 'evening';
    if (haystack.contains('afternoon')) return 'afternoon';
    if (haystack.contains('morning')) return 'morning';
    final int hour = DateTime.now().hour;
    if (hour < 12) return 'morning';
    if (hour < 17) return 'afternoon';
    if (hour < 22) return 'evening';
    return 'night';
  }

  static String _clamp(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    final String cut = value.substring(0, maxLength);
    final int lastSpace = cut.lastIndexOf(' ');
    return '${(lastSpace > maxLength ~/ 2 ? cut.substring(0, lastSpace) : cut).trim()}…';
  }
}
