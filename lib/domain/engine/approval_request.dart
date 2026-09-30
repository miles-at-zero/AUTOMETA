import 'package:flutter/foundation.dart';

import '../../core/utils/json_utils.dart';

/// A request for the user to approve one pending action (spec §23).
///
/// Approvals are persisted. If the app is killed while one is outstanding, it
/// is still there on the next launch, and it expires rather than firing late.
@immutable
class ApprovalTicket {
  const ApprovalTicket({
    required this.id,
    required this.executionId,
    required this.workflowId,
    required this.workflowName,
    required this.stepId,
    required this.title,
    required this.integrationId,
    required this.action,
    required this.createdAt,
    required this.expiresAt,
    this.body = '',
    this.fields = const <String, String>{},
    this.simulated = false,
  });

  final String id;
  final String executionId;
  final String workflowId;
  final String workflowName;
  final String stepId;

  /// Headline shown in the approval sheet, e.g. "Send WhatsApp to Dad".
  final String title;

  /// Which integration will act if approved, e.g. `whatsapp`.
  final String integrationId;

  /// What the integration will do, e.g. `open_conversation`.
  final String action;

  final String body;

  /// Labelled fields rendered verbatim ("Recipient", "Message", "Amount").
  final Map<String, String> fields;

  final DateTime createdAt;
  final DateTime expiresAt;

  /// True for tickets created by a dry run; approving one performs nothing.
  final bool simulated;

  bool isExpiredAt(DateTime moment) => moment.isAfter(expiresAt);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'execution_id': executionId,
        'workflow_id': workflowId,
        'workflow_name': workflowName,
        'step_id': stepId,
        'title': title,
        'integration_id': integrationId,
        'action': action,
        'body': body,
        'fields': fields,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'simulated': simulated,
      };

  factory ApprovalTicket.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    final DateTime created = asDateTime(map['created_at']) ?? DateTime.now();
    return ApprovalTicket(
      id: asString(map['id']),
      executionId: asString(map['execution_id']),
      workflowId: asString(map['workflow_id']),
      workflowName: asString(map['workflow_name']),
      stepId: asString(map['step_id']),
      title: asString(map['title'], fallback: 'AUTOMETA needs approval'),
      integrationId: asString(map['integration_id']),
      action: asString(map['action']),
      body: asString(map['body']),
      fields: asStringMap(map['fields']),
      createdAt: created,
      expiresAt: asDateTime(map['expires_at']) ?? created.add(const Duration(hours: 24)),
      simulated: asBool(map['simulated']),
    );
  }
}

enum ApprovalDecision { approved, rejected, expired }
