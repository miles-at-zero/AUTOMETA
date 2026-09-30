import 'package:flutter/foundation.dart';

import '../models/execution.dart';
import '../models/step.dart';
import '../models/workflow.dart';
import 'variable_resolver.dart';

/// Everything a block needs to know about the run it is part of.
///
/// Executors receive this instead of reaching into global state, which is what
/// makes the engine testable without a widget tree or a database.
class StepContext {
  StepContext({
    required this.workflow,
    required this.executionId,
    required this.dryRun,
    required this.source,
    required this.scheduledFor,
    this.approvalGranted = false,
    this.approvedStepId,
    Map<String, String>? initialVariables,
    DateTime Function()? clock,
  })  : _bag = <String, String>{...?initialVariables},
        _clock = clock ?? DateTime.now;

  final Workflow workflow;
  final String executionId;
  final bool dryRun;
  final TriggerSource source;
  final DateTime scheduledFor;

  /// True while replaying the tail of a run whose approval was granted.
  final bool approvalGranted;

  /// The one block the user approved. Later blocks still need their own.
  final String? approvedStepId;

  bool isApproved(String stepId) => approvalGranted && approvedStepId == stepId;
  final DateTime Function() _clock;
  final Map<String, String> _bag;

  final List<String> resolvedFieldLog = <String>[];

  DateTime now() => _clock();

  /// Read-only view of the current variable bag.
  Map<String, String> get variables => Map<String, String>.unmodifiable(_bag);

  VariableResolver get resolver => VariableResolver(_bag);

  /// Expands `{{tokens}}` in [template] using the run's variables.
  String resolve(String template) {
    final String value = resolver.resolve(template);
    if (value != template) resolvedFieldLog.add(template);
    return value;
  }

  void setVariable(String name, String value) {
    if (name.trim().isEmpty) return;
    _bag[name.trim()] = value;
  }

  void mergeVariables(Map<String, String> values) => _bag.addAll(values);

  /// Seeds the run with built-ins plus the workflow's own custom variables.
  static StepContext create({
    required Workflow workflow,
    required String executionId,
    required bool dryRun,
    required TriggerSource source,
    required DateTime scheduledFor,
    bool approvalGranted = false,
    String? approvedStepId,
    String defaultRecipientName = '',
    Map<String, String> runtimeVariables = const <String, String>{},
    DateTime Function()? clock,
  }) {
    final DateTime Function() nowFn = clock ?? DateTime.now;
    final Map<String, String> bag = <String, String>{
      ...VariableResolver.builtIns(
        nowFn(),
        defaultName: defaultRecipientName,
        workflowName: workflow.name,
      ),
      ...workflow.variables,
      ...runtimeVariables,
    };
    return StepContext(
      workflow: workflow,
      executionId: executionId,
      dryRun: dryRun,
      source: source,
      scheduledFor: scheduledFor,
      approvalGranted: approvalGranted,
      approvedStepId: approvedStepId,
      initialVariables: bag,
      clock: clock,
    );
  }
}

/// Convenience for executors that only care about one block type.
abstract class TypedStepExecutor<T extends WorkflowStep> {
  const TypedStepExecutor();
}
