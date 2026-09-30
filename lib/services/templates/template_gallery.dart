import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/json_utils.dart';
import '../../domain/models/step.dart';
import '../../domain/models/trigger.dart';
import '../../domain/models/workflow.dart';

/// A gallery entry (spec §18).
///
/// Templates are workflow *definitions*, not code paths: instantiating one
/// produces an ordinary [Workflow] the user can then edit, test and delete
/// like any other. Nothing about a template is special-cased in the engine.
@immutable
class AutomationTemplate {
  const AutomationTemplate({
    required this.id,
    required this.name,
    required this.blurb,
    required this.category,
    required this.definition,
  });

  final String id;
  final String name;
  final String blurb;
  final String category;

  /// JSON definition with `__ID__` placeholders for generated ids.
  final Map<String, dynamic> definition;

  /// Produces a real, editable workflow. Created disabled on purpose: the
  /// preview screen is the activation gate (spec §13).
  Workflow instantiate({
    String recipient = 'Dad',
    String timeZone = 'UTC',
    String Function()? idGenerator,
  }) {
    final String Function() newId = idGenerator ?? const Uuid().v4;
    final Map<String, dynamic> json = jsonClone(definition);
    _fillIds(json, newId);
    if (recipient.trim().isNotEmpty && recipient != 'Dad') {
      _renameRecipient(json, recipient.trim());
      json['name'] = '${json['name']}'.replaceAll('Dad', recipient.trim());
    }
    return Workflow.fromJson(<String, dynamic>{
      ...json,
      'id': newId(),
      'enabled': false,
      'time_zone': timeZone,
      'template_id': id,
      'variables': <String, String>{
        ...asStringMap(json['variables']),
        'name': recipient,
      },
    });
  }

  /// Starter templates are written for "Dad"; swap in the chosen alias.
  static void _renameRecipient(Object? node, String recipient) {
    if (node is Map<String, dynamic>) {
      if (node['type'] == 'whatsapp') {
        if (node['recipient'] == 'Dad') node['recipient'] = recipient;
        node['message'] = '${node['message'] ?? ''}'.replaceAll(RegExp(r'\bDad\b'), recipient);
      }
      for (final Object? v in node.values) {
        _renameRecipient(v, recipient);
      }
    } else if (node is List) {
      for (final Object? v in node) {
        _renameRecipient(v, recipient);
      }
    }
  }

  static void _fillIds(Object? node, String Function() newId) {
    if (node is Map<String, dynamic>) {
      if (node.containsKey('type') && !node.containsKey('trigger')) {
        node['id'] = newId();
      }
      for (final Object? value in node.values.toList()) {
        _fillIds(value, newId);
      }
    } else if (node is List) {
      for (final Object? value in node) {
        _fillIds(value, newId);
      }
    }
  }

  static Map<String, dynamic> jsonClone(Map<String, dynamic> source) =>
      jsonDecodeLike(source);
}

Map<String, dynamic> jsonDecodeLike(Map<String, dynamic> source) =>
    Map<String, dynamic>.from(source.map((String k, Object? v) => MapEntry<String, dynamic>(k, _clone(v))));

Object? _clone(Object? value) {
  if (value is Map) {
    return value.map((Object? k, Object? v) => MapEntry<String, dynamic>('$k', _clone(v)));
  }
  if (value is List) return value.map(_clone).toList();
  return value;
}

/// The starter gallery.
class TemplateGallery {
  const TemplateGallery._();

  static const List<AutomationTemplate> all = <AutomationTemplate>[
    AutomationTemplate(
      id: 'morning_dad',
      name: 'Morning Dad',
      blurb: 'Every day at 07:00, prepare a good-morning WhatsApp for Dad',
      category: 'Starter',
      definition: <String, dynamic>{
        'name': 'Morning Dad',
        'description': 'Prepares a morning greeting for you to send',
        'trigger': <String, dynamic>{'type': 'schedule', 'time': '07:00', 'repeat': 'daily'},
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'whatsapp',
            'mode': 'prepare',
            'recipient': 'Dad',
            'message': 'Good morning Dad',
          },
        ],
      },
    ),
    AutomationTemplate(
      id: 'evening_dad',
      name: 'Evening Dad',
      blurb: 'Every day at 20:00, prepare a good-evening WhatsApp for Dad',
      category: 'Starter',
      definition: <String, dynamic>{
        'name': 'Evening Dad',
        'trigger': <String, dynamic>{'type': 'schedule', 'time': '20:00', 'repeat': 'daily'},
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'whatsapp',
            'mode': 'prepare',
            'recipient': 'Dad',
            'message': 'Good evening Dad',
          },
        ],
      },
    ),
    AutomationTemplate(
      id: 'night_dad',
      name: 'Night Dad',
      blurb: 'Every day at 22:00, prepare a good-night WhatsApp for Dad',
      category: 'Starter',
      definition: <String, dynamic>{
        'name': 'Night Dad',
        'trigger': <String, dynamic>{'type': 'schedule', 'time': '22:00', 'repeat': 'daily'},
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'whatsapp',
            'mode': 'prepare',
            'recipient': 'Dad',
            'message': 'Good night Dad',
          },
        ],
      },
    ),
    AutomationTemplate(
      id: 'morning_brief',
      name: 'Morning Brief',
      blurb: 'AI writes a short daily briefing and posts it as a notification',
      category: 'AI',
      definition: <String, dynamic>{
        'name': 'Morning Brief',
        'trigger': <String, dynamic>{'type': 'schedule', 'time': '07:30', 'repeat': 'daily'},
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'ai',
            'task': 'generate',
            'prompt': 'Write a short, useful daily briefing for {{name}}. '
                'Three practical points, warm tone, under 240 characters.',
            'tone': 'Warm',
            'max_length': 240,
            'output_variable': 'ai_output',
          },
          <String, dynamic>{
            'type': 'notification',
            'title': 'Good morning',
            'body': '{{ai_output}}',
          },
        ],
      },
    ),
    AutomationTemplate(
      id: 'message_writer',
      name: 'AI Message Writer',
      blurb: 'Run manually: AI polishes your draft and copies it to the clipboard',
      category: 'AI',
      definition: <String, dynamic>{
        'name': 'AI Message Writer',
        'trigger': <String, dynamic>{'type': 'manual', 'hint': 'Run it when you need a message polished'},
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'ai',
            'task': 'rewrite',
            'prompt': 'Rewrite this message so it reads naturally and politely',
            'input': '{{draft}}',
            'tone': 'Warm',
            'max_length': 300,
            'output_variable': 'ai_output',
          },
          <String, dynamic>{'type': 'clipboard', 'text': '{{ai_output}}'},
          <String, dynamic>{
            'type': 'notification',
            'title': 'Message ready',
            'body': '{{ai_output}}',
          },
        ],
        'variables': <String, String>{'draft': 'hey, can you send the file today'},
      },
    ),
    AutomationTemplate(
      id: 'daily_reminder',
      name: 'Daily Reminder',
      blurb: 'A simple notification at a fixed time every day',
      category: 'Basics',
      definition: <String, dynamic>{
        'name': 'Daily Reminder',
        'trigger': <String, dynamic>{'type': 'schedule', 'time': '09:00', 'repeat': 'daily'},
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'notification',
            'title': 'Daily reminder',
            'body': 'Review today\'s priorities',
          },
        ],
      },
    ),
    AutomationTemplate(
      id: 'follow_up',
      name: 'Follow-up Assistant',
      blurb: 'Notify now, wait 30 minutes, then nudge again',
      category: 'Basics',
      definition: <String, dynamic>{
        'name': 'Follow-up Assistant',
        'trigger': <String, dynamic>{'type': 'manual', 'hint': 'Start it when you send something you want to chase'},
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'notification',
            'title': 'Sent',
            'body': 'Follow-up scheduled in 30 minutes',
          },
          <String, dynamic>{'type': 'delay', 'seconds': 1800},
          <String, dynamic>{
            'type': 'notification',
            'title': 'Follow up',
            'body': 'Still no reply? Time to chase it.',
          },
        ],
      },
    ),
    AutomationTemplate(
      id: 'weekly_summary',
      name: 'Weekly Summary',
      blurb: 'Every Sunday at 18:00, AI summarises your notes into a notification',
      category: 'AI',
      definition: <String, dynamic>{
        'name': 'Weekly Summary',
        'trigger': <String, dynamic>{
          'type': 'schedule',
          'time': '18:00',
          'repeat': 'weekly',
          'weekdays': <int>[7],
        },
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'ai',
            'task': 'summarize',
            'prompt': 'Summarise the notes below into three bullet points',
            'input': '{{week_notes}}',
            'tone': 'Clear',
            'max_length': 400,
            'output_variable': 'ai_output',
          },
          <String, dynamic>{
            'type': 'notification',
            'title': 'Week in review',
            'body': '{{ai_output}}',
          },
        ],
        'variables': <String, String>{'week_notes': 'Paste the week\'s notes here'},
      },
    ),
    AutomationTemplate(
      id: 'api_monitor',
      name: 'API Monitor',
      blurb: 'Poll an endpoint hourly and alert only when it is unhealthy',
      category: 'Ops',
      definition: <String, dynamic>{
        'name': 'API Monitor',
        'trigger': <String, dynamic>{
          'type': 'schedule',
          'repeat': 'interval',
          'interval_minutes': 60,
        },
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'http',
            'method': 'GET',
            'url': 'https://example.com/health',
            'success_status_min': 200,
            'success_status_max': 299,
            'output_variable': 'http_response',
            'continue_on_error': true,
          },
          <String, dynamic>{
            'type': 'condition',
            'if': <String, dynamic>{
              'left': '{{http_response_status}}',
              'operator': '==',
              'right': '200',
            },
            'then': <Map<String, dynamic>>[],
            'else': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'notification',
                'title': 'API is unhealthy',
                'body': 'Expected HTTP 200, got {{http_response_status}}',
              },
            ],
          },
        ],
      },
    ),
    AutomationTemplate(
      id: 'sunday_ai_summary',
      name: 'Sunday AI Summary',
      blurb: 'The acceptance-test workflow: Sunday 18:00 → AI summary → notification',
      category: 'Starter',
      definition: <String, dynamic>{
        'name': 'Sunday AI Summary',
        'trigger': <String, dynamic>{
          'type': 'schedule',
          'time': '18:00',
          'repeat': 'weekly',
          'weekdays': <int>[7],
        },
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'ai',
            'task': 'generate',
            'prompt': 'Generate a short AI summary of the week for {{name}}',
            'tone': 'Warm',
            'max_length': 240,
            'output_variable': 'ai_output',
          },
          <String, dynamic>{
            'type': 'notification',
            'title': 'Your weekly summary',
            'body': '{{ai_output}}',
          },
        ],
      },
    ),
  ];

  static AutomationTemplate? byId(String id) {
    for (final AutomationTemplate template in all) {
      if (template.id == id) return template;
    }
    return null;
  }

  static List<String> get categories =>
      all.map((AutomationTemplate t) => t.category).toSet().toList();

  /// The three starter automations offered on first launch (spec §5, §39).
  static List<AutomationTemplate> get starters =>
      all.where((AutomationTemplate t) => t.category == 'Starter').toList(growable: false);
}
