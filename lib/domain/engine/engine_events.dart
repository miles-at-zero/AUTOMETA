import 'package:flutter/foundation.dart';

import '../models/execution.dart';
import 'approval_request.dart';
import 'step_result.dart';

/// Broadcast by the engine so the UI, the activity log and the notification
/// service can all react without the engine knowing about any of them.
@immutable
sealed class EngineEvent {
  const EngineEvent();

  DateTime get at;
}

@immutable
class ExecutionStartedEvent extends EngineEvent {
  const ExecutionStartedEvent({required this.record, required this.at});

  final ExecutionRecord record;
  @override
  final DateTime at;
}

@immutable
class StepFinishedEvent extends EngineEvent {
  const StepFinishedEvent({
    required this.executionId,
    required this.workflowName,
    required this.stepResult,
    required this.at,
  });

  final String executionId;
  final String workflowName;
  final StepExecution stepResult;
  @override
  final DateTime at;
}

@immutable
class ExecutionFinishedEvent extends EngineEvent {
  const ExecutionFinishedEvent({required this.record, required this.at});

  final ExecutionRecord record;
  @override
  final DateTime at;
}

@immutable
class ApprovalRequestedEvent extends EngineEvent {
  const ApprovalRequestedEvent({required this.ticket, required this.at});

  final ApprovalTicket ticket;
  @override
  final DateTime at;
}

@immutable
class ExecutionSkippedEvent extends EngineEvent {
  const ExecutionSkippedEvent({required this.record, required this.reason, required this.at});

  final ExecutionRecord record;
  final String reason;
  @override
  final DateTime at;
}

@immutable
class EngineLogEvent extends EngineEvent {
  const EngineLogEvent({required this.message, required this.at});

  final String message;
  @override
  final DateTime at;
}
