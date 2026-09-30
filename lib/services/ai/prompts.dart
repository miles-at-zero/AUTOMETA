import '../../domain/models/step.dart';
import 'ai_provider.dart';

/// Prompt construction for every AI task (spec §12).
///
/// Prompts are deterministic functions of the block configuration so the same
/// automation behaves the same way run to run, and so a dry run can show the
/// user exactly what will be asked.
class AiPrompts {
  const AiPrompts._();

  static String systemFor(AiPrompt prompt) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('You are the text engine inside AUTOMETA, a personal automation app.')
      ..writeln('Follow the instruction exactly and output only the requested text.')
      ..writeln('Do not add greetings, explanations, markdown fences or commentary.')
      ..writeln('Tone: ${prompt.tone}.')
      ..writeln('Hard limit: ${prompt.maxLength} characters.');
    if (prompt.systemContext.isNotEmpty) {
      buffer.writeln('Context: ${prompt.systemContext}');
    }
    switch (prompt.task) {
      case AiTask.generate:
        buffer.writeln('Task: write original text.');
      case AiTask.rewrite:
        buffer.writeln('Task: rewrite the supplied text. Keep every fact; change only wording.');
      case AiTask.summarize:
        buffer.writeln('Task: summarize the supplied text. Keep names, numbers and dates.');
      case AiTask.classify:
        buffer.writeln('Task: classify the supplied text into exactly one short label '
            '(one to three words, lowercase).');
      case AiTask.extract:
        buffer.writeln('Task: extract the requested information as a JSON object. '
            'Use null for anything not present. Output JSON only.');
      case AiTask.convert:
        buffer.writeln('Task: convert the supplied text into the requested form.');
      case AiTask.structured:
        buffer.writeln('Task: produce a JSON object matching the requested shape. Output JSON only.');
    }
    return buffer.toString().trim();
  }

  static String userFor(AiPrompt prompt) {
    final StringBuffer buffer = StringBuffer()..writeln(prompt.instruction.trim());
    if (prompt.input.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('--- INPUT ---')
        ..writeln(prompt.input.trim())
        ..writeln('--- END INPUT ---');
    }
    return buffer.toString().trim();
  }

  /// Prompt text used when the natural-language creator asks for a workflow.
  static String naturalLanguageCreator(String userRequest) => '''
You convert a plain-language request into an AUTOMETA workflow definition.

Return ONLY a JSON object with this shape:
{
  "name": "short title",
  "trigger": { "type": "schedule", "time": "HH:mm", "repeat": "daily|weekdays|weekends|days|monthly" , "weekdays": [1..7] },
  "steps": [ { "type": "notification", "title": "...", "body": "..." } ]
}

Rules:
- "steps" entries may be: notification {title, body}, whatsapp {mode, recipient, message},
  ai {task, prompt, tone, max_length, output_variable}, delay {seconds},
  condition {if:{left,operator,right}, then:[...], else:[...]}.
- Use the default recipient name when the user says a person's name but gives no number.
- Weekdays are ISO numbers: Monday = 1 ... Sunday = 7.
- Never invent phone numbers.
- Output JSON only, no prose, no code fences.

Request:
$userRequest
''';

  /// Prompt used when a rough message should be improved.
  static String improveMessage(String draft, {String tone = 'Warm', int maxLength = 240}) => '''
Rewrite the message below so it reads naturally.
Tone: $tone. Maximum $maxLength characters. Keep every fact. Output only the message.

--- DRAFT ---
$draft
--- END DRAFT ---
''';
}
