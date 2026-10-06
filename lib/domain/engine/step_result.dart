import 'package:flutter/foundation.dart';

import '../models/execution.dart';
import 'approval_request.dart';

/// What a single block did.
///
/// `outcome` is the only field the UI is allowed to trust when it renders
/// status text: an executor that could not deliver returns `failed` with a
/// reason, never `success` (spec §40).
@immutable
class StepResult {
  const StepResult({
    required this.outcome,
    this.detail,
    this.code,
    this.retriable = false,
    this.outputVariables = const <String, String>{},
    this.approval,
    this.deferUntil,
  });

  const StepResult.done({String? detail, Map<String, String> outputVariables = const <String, String>{}})
      : this(
          outcome: StepOutcome.success,
          detail: detail,
          outputVariables: outputVariables,
        );

  /// Produced by a dry run: describes what *would* happen, performs nothing.
  const StepResult.simulated({String? detail})
      : this(outcome: StepOutcome.simulated, detail: detail);

  const StepResult.failed({
    required String reason,
    String? code,
    bool retriable = false,
  }) : this(
          outcome: StepOutcome.failed,
          detail: reason,
          code: code,
          retriable: retriable,
        );

  const StepResult.skipped({String? reason})
      : this(outcome: StepOutcome.skipped, detail: reason);

  final StepOutcome outcome;
  final String? detail;
  final String? code;
  final bool retriable;

  /// Values merged into the run's variable bag for later blocks.
  final Map<String, String> outputVariables;

  /// Present when the block needs an explicit user approval before acting.
  final ApprovalTicket? approval;

  /// Present when the block asks the run to be parked and resumed later.
  final DateTime? deferUntil;

  bool get isFailure => outcome == StepOutcome.failed;
  bool get needsApproval => outcome == StepOutcome.awaitingApproval;
  bool get isTerminalBlock => needsApproval || deferUntil != null;
}
