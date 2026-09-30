import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/json_utils.dart';
import 'step.dart';
import 'trigger.dart';

/// A complete, serialisable automation definition (spec §36).
///
/// Nothing about a workflow is hard-coded in the UI: every screen reads and
/// writes this object, and the engine only ever sees this object.
@immutable
class Workflow {
  const Workflow({
    required this.id,
    required this.name,
    required this.trigger,
    required this.steps,
    this.description = '',
    this.enabled = true,
    this.timeZone = 'UTC',
    this.maxRetries = EngineLimits.defaultRetries,
    this.variables = const <String, String>{},
    this.templateId,
    this.createdAt,
    this.updatedAt,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Bumped whenever the JSON shape changes so stored definitions can migrate.
  static const int currentSchemaVersion = 1;

  final String id;
  final String name;
  final String description;
  final WorkflowTrigger trigger;
  final List<WorkflowStep> steps;
  final bool enabled;

  /// IANA time zone id. Schedules are evaluated in this zone, not device zone.
  final String timeZone;

  final int maxRetries;

  /// Custom `{{variables}}` available to every block (spec §14).
  final Map<String, String> variables;

  /// Which gallery template this workflow came from, if any.
  final String? templateId;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int schemaVersion;

  bool get isScheduled => trigger.isSchedulable;

  Workflow copyWith({
    String? name,
    String? description,
    WorkflowTrigger? trigger,
    List<WorkflowStep>? steps,
    bool? enabled,
    String? timeZone,
    int? maxRetries,
    Map<String, String>? variables,
    String? templateId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Workflow(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        trigger: trigger ?? this.trigger,
        steps: steps ?? this.steps,
        enabled: enabled ?? this.enabled,
        timeZone: timeZone ?? this.timeZone,
        maxRetries: maxRetries ?? this.maxRetries,
        variables: variables ?? this.variables,
        templateId: templateId ?? this.templateId,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        schemaVersion: schemaVersion,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema_version': schemaVersion,
        'id': id,
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'enabled': enabled,
        'time_zone': timeZone,
        'max_retries': maxRetries,
        if (templateId != null) 'template_id': templateId,
        'trigger': trigger.toJson(),
        'steps': steps.map((WorkflowStep s) => s.toJson()).toList(),
        if (variables.isNotEmpty) 'variables': variables,
        if (createdAt != null) 'created_at': createdAt!.toUtc().toIso8601String(),
        if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
      };

  factory Workflow.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return Workflow(
      id: asString(map['id']),
      name: asString(map['name'], fallback: 'Untitled automation'),
      description: asString(map['description']),
      trigger: WorkflowTrigger.fromJson(map['trigger']),
      steps: WorkflowStep.listFromJson(map['steps']),
      enabled: asBool(map['enabled'], fallback: true),
      timeZone: asString(map['time_zone'], fallback: 'UTC'),
      maxRetries: asInt(map['max_retries'], fallback: EngineLimits.defaultRetries)
          .clamp(0, EngineLimits.maxRetries),
      variables: asStringMap(map['variables']),
      templateId: asStringOrNull(map['template_id']),
      createdAt: asDateTime(map['created_at']),
      updatedAt: asDateTime(map['updated_at']),
      schemaVersion: asInt(map['schema_version'], fallback: currentSchemaVersion),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Workflow &&
      other.id == id &&
      other.name == name &&
      other.enabled == enabled &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, name, enabled, updatedAt);
}
