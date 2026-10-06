import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/json_utils.dart';
import '../../core/utils/logger.dart';
import '../../domain/models/step.dart';
import '../../domain/models/trigger.dart';
import '../../domain/models/workflow.dart';
import 'ai_provider.dart';
import 'ai_service.dart';
import 'prompts.dart';

/// What the parser understood, plus an honest account of how it understood it.
@immutable
class ParsedWorkflow {
  const ParsedWorkflow({
    required this.workflow,
    required this.usedAi,
    required this.confidence,
    this.assumptions = const <String>[],
    this.rawRequest = '',
  });

  final Workflow workflow;

  /// True when a configured language model produced the definition.
  final bool usedAi;

  final double confidence;

  /// Every guess the parser made, surfaced in the preview so nothing is hidden.
  final List<String> assumptions;
  final String rawRequest;

  String get engineLabel => usedAi ? 'AI' : 'Local parser';
}

/// Natural-language automation creator (spec §13, §35).
///
/// Two-stage by design:
///  1. If a real AI provider is configured, it is asked for a workflow JSON.
///  2. Otherwise — or if that output does not parse — a deterministic rule
///     parser handles the request. It is a rule parser and is labelled as one;
///     it never pretends to be a language model.
///
/// Either way the result is a [Workflow] object that the preview screen shows
/// before anything is saved or armed. Nothing is activated silently.
class NaturalLanguageWorkflowParser {
  NaturalLanguageWorkflowParser({
    required this.ai,
    String Function()? idGenerator,
  }) : _newId = idGenerator ?? const Uuid().v4;

  final AiService ai;
  final String Function() _newId;
  final Logger _log = Logger.withTag(LogTags.ai);

  /// Default hour used when the request names no time.
  static const String fallbackTime = '09:00';

  Future<ParsedWorkflow> parse(
    String request, {
    String defaultRecipient = 'Dad',
    String timeZone = 'UTC',
  }) async {
    final String text = request.trim();
    if (text.isEmpty) {
      throw const FormatException('Nothing to interpret');
    }

    if (await ai.isReady && ai.settings.providerId != AiProviderId.localTemplates) {
      try {
        final ParsedWorkflow? fromAi = await _parseWithAi(text, defaultRecipient, timeZone);
        if (fromAi != null) return fromAi;
        _log.warn('AI output could not be parsed; falling back to the local parser');
      } catch (error) {
        _log.warn('AI parsing failed; falling back to the local parser', error);
      }
    }

    return parseLocally(text, defaultRecipient: defaultRecipient, timeZone: timeZone);
  }

  Future<ParsedWorkflow?> _parseWithAi(
    String request,
    String defaultRecipient,
    String timeZone,
  ) async {
    final AiCompletion completion = await ai.complete(AiPrompt(
      task: AiTask.structured,
      instruction: AiPrompts.naturalLanguageCreator(request),
      maxLength: 1200,
      systemContext: 'Default recipient name: $defaultRecipient. Time zone: $timeZone.',
    ));

    final Map<String, dynamic>? json = _extractJson(completion.text);
    if (json == null) return null;

    final Workflow workflow = Workflow.fromJson(<String, dynamic>{
      'id': _newId(),
      'name': asString(json['name'], fallback: _titleFrom(request)),
      'time_zone': timeZone,
      'trigger': json['trigger'],
      'steps': json['steps'],
      'variables': <String, String>{'name': defaultRecipient},
    });

    if (workflow.steps.isEmpty) return null;

    return ParsedWorkflow(
      workflow: workflow,
      usedAi: true,
      confidence: 0.85,
      assumptions: <String>[
        'Built by ${ai.settings.providerId.label}',
        'Review every field before enabling — nothing has been saved yet',
      ],
      rawRequest: request,
    );
  }

  /// Pulls the first JSON object out of a model response, tolerating code
  /// fences and leading prose.
  @visibleForTesting
  static Map<String, dynamic>? _extractJson(String text) {
    String candidate = text.trim();
    if (candidate.startsWith('```')) {
      candidate = candidate.replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '').replaceAll(RegExp(r'```\s*$'), '');
    }
    final int start = candidate.indexOf('{');
    final int end = candidate.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final Object? decoded = jsonDecode(candidate.substring(start, end + 1));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Deterministic rule parser
  // ---------------------------------------------------------------------------

  /// Rule-based interpretation. Covers the phrasing shown in the app's own
  /// examples and degrades predictably for anything else.
  @visibleForTesting
  ParsedWorkflow parseLocally(
    String request, {
    String defaultRecipient = 'Dad',
    String timeZone = 'UTC',
  }) {
    final String lower = request.toLowerCase();
    final List<String> assumptions = <String>['Built by the on-device rule parser (no AI used)'];

    // --- Recurrence ----------------------------------------------------------
    ScheduleRepeat repeat = ScheduleRepeat.daily;
    Set<int> weekdays = const <int>{1, 2, 3, 4, 5, 6, 7};
    final Set<int> foundDays = _weekdaysIn(lower);
    if (lower.contains('weekday') || lower.contains('monday to friday') || lower.contains('mon-fri')) {
      repeat = ScheduleRepeat.weekdays;
      weekdays = const <int>{1, 2, 3, 4, 5};
    } else if (lower.contains('weekend')) {
      repeat = ScheduleRepeat.weekends;
      weekdays = const <int>{6, 7};
    } else if (lower.contains('every month') || lower.contains('monthly')) {
      repeat = ScheduleRepeat.monthly;
    } else if (foundDays.isNotEmpty) {
      repeat = foundDays.length == 1 ? ScheduleRepeat.weekly : ScheduleRepeat.days;
      weekdays = foundDays;
    } else if (lower.contains('every day') ||
        lower.contains('daily') ||
        lower.contains('each day') ||
        lower.contains('everyday')) {
      repeat = ScheduleRepeat.daily;
    }

    // --- Time of day ---------------------------------------------------------
    final _TimeOfDay time = _timeIn(lower);
    if (!time.explicit) {
      assumptions.add('No time given — using ${_human(time.value)}');
    }

    // --- Recipient -----------------------------------------------------------
    final String? named = _recipientIn(request);
    final String recipient = named ?? defaultRecipient;
    if (named == null && lower.contains('whatsapp')) {
      assumptions.add('No recipient named — using "$defaultRecipient"');
    }

    // --- Message -------------------------------------------------------------
    final String? quoted = _quotedIn(request);

    // --- Channel / steps -----------------------------------------------------
    final List<WorkflowStep> steps = <WorkflowStep>[];
    final bool wantsAi = RegExp(r'\b(ai|briefing|briefings|summar(y|ize|ise|ises)|generate|draft)\b')
        .hasMatch(lower);
    final bool wantsWhatsApp = lower.contains('whatsapp') || lower.contains('whats app');
    final bool wantsNotification = lower.contains('notif') ||
        lower.contains('remind') ||
        lower.contains('reminder') ||
        lower.contains('alert me') ||
        lower.contains('tell me');

    final String greeting = _greetingFor(time.value);

    if (wantsAi) {
      // With no source text to condense, a "summary" request is a generation task.
      const AiTask task = AiTask.generate;
      steps.add(AiStep(
        id: _newId(),
        task: task,
        prompt: lower.contains('briefing')
            ? 'Write a short, useful daily briefing for {{name}}. Keep it under 240 characters.'
            : (quoted ?? _instructionFrom(request)),
        tone: 'Warm',
        maxLength: 240,
        outputVariable: 'ai_output',
      ));
    }

    if (wantsWhatsApp) {
      steps.add(WhatsAppStep(
        id: _newId(),
        mode: WhatsAppMode.prepare,
        recipient: recipient,
        message: quoted ??
            (wantsAi ? '{{ai_output}}' : '$greeting $recipient'),
      ));
    }

    if (wantsNotification || (!wantsWhatsApp && steps.isEmpty)) {
      steps.add(NotificationStep(
        id: _newId(),
        title: wantsAi ? 'Your daily briefing' : 'AUTOMETA reminder',
        body: quoted ?? (wantsAi ? '{{ai_output}}' : _reminderBody(request)),
      ));
    }

    if (steps.isEmpty) {
      steps.add(NotificationStep(
        id: _newId(),
        title: 'AUTOMETA',
        body: _reminderBody(request),
      ));
      assumptions.add('No channel was recognised — using a notification');
    }

    final Workflow workflow = Workflow(
      id: _newId(),
      name: _titleFrom(request),
      description: request,
      timeZone: timeZone,
      trigger: ScheduleTrigger(timeOfDay: time.value, repeat: repeat, weekdays: weekdays),
      steps: steps,
      variables: <String, String>{'name': recipient},
      enabled: false,
    );

    return ParsedWorkflow(
      workflow: workflow,
      usedAi: false,
      confidence: 0.6,
      assumptions: assumptions,
      rawRequest: request,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static const Map<String, int> _dayWords = <String, int>{
    'monday': 1,
    'tuesday': 2,
    'wednesday': 3,
    'thursday': 4,
    'friday': 5,
    'saturday': 6,
    'sunday': 7,
    'mon': 1,
    'tue': 2,
    'tues': 2,
    'wed': 3,
    'thu': 4,
    'thurs': 4,
    'fri': 5,
    'sat': 6,
    'sun': 7,
  };

  Set<int> _weekdaysIn(String lower) {
    final Set<int> found = <int>{};
    _dayWords.forEach((String word, int value) {
      if (RegExp('\\b$word\\b').hasMatch(lower)) found.add(value);
    });
    return found;
  }

  _TimeOfDay _timeIn(String lower) {
    // 07:00 / 7:30
    final Match? colon = RegExp(r'\b(\d{1,2}):(\d{2})\b').firstMatch(lower);
    if (colon != null) {
      final int hour = int.parse(colon.group(1)!) % 24;
      return _TimeOfDay(_pad(hour, int.parse(colon.group(2)!)), explicit: true);
    }

    // "at 7", "at 7am", "at 7 pm", "at 19"
    final Match? at = RegExp(r'\bat\s+(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)?\b').firstMatch(lower);
    if (at != null) {
      int hour = int.parse(at.group(1)!);
      final String? meridiem = at.group(2)?.replaceAll('.', '').toLowerCase();
      if (meridiem == 'pm' && hour < 12) hour += 12;
      if (meridiem == 'am' && hour == 12) hour = 0;
      // No meridiem given ("every morning at 7") — take the hour as written.
      return _TimeOfDay(_pad(hour.clamp(0, 23), 0), explicit: true);
    }

    if (lower.contains('midnight')) return const _TimeOfDay('00:00', explicit: true);
    if (lower.contains('noon')) return const _TimeOfDay('12:00', explicit: true);
    if (lower.contains('morning')) return const _TimeOfDay('07:00', explicit: true);
    if (lower.contains('afternoon')) return const _TimeOfDay('14:00', explicit: true);
    if (lower.contains('evening')) return const _TimeOfDay('20:00', explicit: true);
    if (lower.contains('night')) return const _TimeOfDay('22:00', explicit: true);

    return const _TimeOfDay(fallbackTime, explicit: false);
  }

  String? _recipientIn(String original) {
    final String text = original.trim();

    // "send Dad ...", "to Dad", "message Mum", "tell Chidi"
    final RegExp pattern = RegExp(
      r'(?:send|to|message|text|tell|wish|greet)\s+(?:my\s+)?([A-Z][a-zA-Z]{1,19})\b',
    );
    for (final Match match in pattern.allMatches(text)) {
      final String candidate = match.group(1)!;
      if (!_isStopWord(candidate)) return candidate;
    }

    // A capitalised personal noun like "Dad", "Mum", "Chidi" anywhere.
    final RegExp bare = RegExp(r'\b(Dad|Daddy|Mom|Mum|Mother|Father|Babe|Boss|[A-Z][a-z]{2,15})\b');
    for (final Match match in bare.allMatches(text)) {
      final String candidate = match.group(1)!;
      if (!_isStopWord(candidate)) return candidate;
    }
    return null;
  }

  static bool _isStopWord(String word) {
    final String w = word.toLowerCase();
    return _stopWords.contains(w) || _dayWords.containsKey(w) || _monthWords.contains(w);
  }

  static const Set<String> _monthWords = <String>{
    'january', 'february', 'march', 'april', 'may', 'june', 'july',
    'august', 'september', 'october', 'november', 'december',
  };

  static const Set<String> _stopWords = <String>{
    'whatsapp',
    'autometa',
    'every',
    'each',
    'send',
    'message',
    'notify',
    'notification',
    'remind',
    'reminder',
    'morning',
    'evening',
    'afternoon',
    'night',
    'today',
    'tomorrow',
    'good',
    'nice',
    'short',
    'daily',
    'weekdays',
    'weekend',
    'the',
    'and',
    'with',
    'please',
    'summary',
    'briefing',
    'review',
    'projects',
    'greeting',
    'me',
    'my',
    'a',
    'an',
    'at',
    'to',
    'of',
    'am',
    'pm',
    'ai',
    'generate',
    'give',
    'show',
    'weekday',
    'weekends',
    'monthly',
    'weekly',
    'hourly',
    'tonight',
  };

  String? _quotedIn(String original) {
    final Match? match = RegExp(r'''["'“]([^"'”]{2,400})["'”]''').firstMatch(original);
    return match?.group(1)?.trim();
  }

  String _instructionFrom(String request) {
    final String cleaned = request
        .replaceAll(RegExp(r'\b(every|each)\s+(day|morning|evening|night|weekday|weekend)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bat\s+\d{1,2}(:\d{2})?\s*(am|pm)?\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'Write a short friendly message.' : cleaned;
  }

  String _reminderBody(String request) {
    String cleaned = _instructionFrom(request)
        .replaceAll(RegExp(r'^\s*(every|each)\s+\w+[,]?\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'^\s*(please\s+)?(remind|tell|notify)\s+me\s+(to\s+)?', caseSensitive: false), '')
        .trim();
    if (cleaned.isNotEmpty) cleaned = cleaned[0].toUpperCase() + cleaned.substring(1);
    return cleaned.isEmpty ? 'Scheduled reminder' : cleaned;
  }

  String _titleFrom(String request) {
    final List<String> words = request
        .replaceAll(RegExp(r'[^A-Za-z0-9\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .take(5)
        .toList();
    if (words.isEmpty) return 'New automation';
    return words.map((String w) => w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');
  }

  static String _greetingFor(String hhmm) {
    final int hour = int.tryParse(hhmm.split(':').first) ?? 9;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    if (hour < 22) return 'Good evening';
    return 'Good night';
  }

  static String _human(String hhmm) {
    final List<String> parts = hhmm.split(':');
    final int hour = int.tryParse(parts.first) ?? 9;
    final String minute = parts.length > 1 ? parts[1] : '00';
    final String suffix = hour < 12 ? 'AM' : 'PM';
    final int display = hour % 12 == 0 ? 12 : hour % 12;
    return '$display:$minute $suffix';
  }

  static String _pad(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

@immutable
class _TimeOfDay {
  const _TimeOfDay(this.value, {required this.explicit});

  /// `HH:mm`.
  final String value;
  final bool explicit;
}
