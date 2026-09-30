import 'package:flutter/foundation.dart';

import '../models/step.dart';
import 'step_context.dart';
import 'step_result.dart';

/// A runnable block.
///
/// Contract every implementation must honour:
///  * Never throw for an expected problem — return `StepResult.failed` with a
///    message a human can read.
///  * Never report success unless the side effect really happened.
///  * In a dry run, return `StepResult.simulated` and touch nothing.
abstract class StepExecutor {
  const StepExecutor();

  StepKind get kind;

  /// Whether this executor can act right now (connection present, credentials
  /// stored, permission granted). Surfaced by the Connections page.
  Future<bool> get isAvailable;

  /// One-line explanation of what "available" means for this block.
  String get availabilityHint;

  Future<StepResult> execute(WorkflowStep step, StepContext context);
}

/// Lookup table from block kind to its executor.
///
/// Integrations register themselves at startup, which is what keeps the action
/// library open for extension (spec §17) without touching engine code.
class StepExecutorRegistry {
  StepExecutorRegistry([Iterable<StepExecutor>? executors]) {
    if (executors != null) {
      for (final StepExecutor executor in executors) {
        register(executor);
      }
    }
  }

  final Map<StepKind, StepExecutor> _executors = <StepKind, StepExecutor>{};

  void register(StepExecutor executor) => _executors[executor.kind] = executor;

  void unregister(StepKind kind) => _executors.remove(kind);

  StepExecutor? forKind(StepKind kind) => _executors[kind];

  bool supports(StepKind kind) => _executors.containsKey(kind);

  Iterable<StepKind> get supportedKinds => _executors.keys;

  /// Block kinds present in the model but with no executor wired up. The UI
  /// labels these `NOT AVAILABLE` instead of offering them (spec §40).
  List<StepKind> get unavailableKinds =>
      StepKind.values.where((StepKind k) => !k.isControl && !supports(k)).toList();
}

/// Executor used when a block has no registered handler.
///
/// It exists so the engine can finish a run honestly instead of crashing on a
/// workflow that references an integration the build does not include.
class MissingStepExecutor extends StepExecutor {
  const MissingStepExecutor(this.kind);

  @override
  final StepKind kind;

  @override
  Future<bool> get isAvailable async => false;

  @override
  String get availabilityHint => '${kind.label} is not available in this build';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async =>
      StepResult.failed(
        reason: '${kind.label} is not available in this build',
        code: '${kind.wire}.not_available',
      );
}
