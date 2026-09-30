import 'dart:async';
import 'dart:collection';

import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../models/execution.dart';
import '../models/execution_status.dart';
import '../models/step.dart';
import '../models/workflow.dart';
import '../schedule/schedule_calculator.dart';
import '../validation/workflow_validator.dart';
import 'approval_request.dart';
import 'condition_evaluator.dart';
import 'engine_events.dart';
import 'engine_ports.dart';
import 'idempotency.dart';
import 'retry_policy.dart';
import 'step_context.dart';
import 'step_executor.dart';
import 'step_result.dart';

/// The automation engine (spec §37).
///
/// It is a pure interpreter over a [Workflow]: no Flutter widgets, no
/// database, no platform channels. Everything it touches the outside world
/// through is injected ([StepExecutorRegistry], [IdempotencyStore],
/// [EngineStateProvider], [EngineSink]), which is why the whole test suite can
/// exercise it on a host VM.
///
/// Execution model: the step list is expanded into a work queue. `IF` blocks
/// splice their chosen branch onto the front of the queue, so branching,
/// nesting and resuming all reduce to "keep taking the next step".
class WorkflowEngine {
  WorkflowEngine({
    required this.registry,
    required this.idempotency,
    required this.state,
    this.sink,
    this.validator = const WorkflowValidator(),
    this.evaluator = const ConditionEvaluator(),
    this.time = const EngineTime(),
    this.scheduleCalculator,
    this.delayHandler,
    this.idGenerator,
    this.maxInProcessWait = const Duration(minutes: 2),
  }) : _scheduleCalculator = scheduleCalculator ?? ScheduleCalculator(clock: time.now);

  final StepExecutorRegistry registry;
  final IdempotencyStore idempotency;
  final EngineStateProvider state;
  final EngineSink? sink;
  final WorkflowValidator validator;
  final ConditionEvaluator evaluator;
  final EngineTime time;
  final ScheduleCalculator _scheduleCalculator;
  final DelayHandler? delayHandler;
  final String Function()? idGenerator;

  /// A `WAIT` longer than this is handed back to the scheduler instead of
  /// blocking a background isolate that Android is free to kill.
  final Duration maxInProcessWait;

  final Logger _log = Logger.withTag(LogTags.engine);
  final StreamController<EngineEvent> _events = StreamController<EngineEvent>.broadcast();
  final Uuid _uuid = const Uuid();

  /// Live feed of engine activity for the UI and the notification service.
  Stream<EngineEvent> get events => _events.stream;

  String _newId() => idGenerator == null ? _uuid.v4() : idGenerator!();

  /// Runs [workflow] end to end.
  ///
  /// Returns the final [ExecutionRecord] — including for the early-exit paths
  /// (paused, duplicate, invalid) so the activity log always has an entry.
  Future<ExecutionRecord> execute(
    Workflow workflow, {
    TriggerSource source = TriggerSource.manual,
    DateTime? scheduledFor,
    bool dryRun = false,
    Map<String, String> runtimeVariables = const <String, String>{},
    bool isBackground = false,
  }) async {
    final DateTime startedAt = time.now();
    final DateTime target = scheduledFor ?? startedAt;
    final String executionId = _newId();

    // 1. Never run a definition we already know is broken.
    final ValidationResult validation = validator.validate(workflow);
    if (validation.errors.isNotEmpty) {
      final String reason = validation.errors.map((ValidationIssue e) => e.message).join('; ');
      _log.warn('Refusing to run "${workflow.name}": $reason');
      final ExecutionRecord record = _baseRecord(
        workflow: workflow,
        executionId: executionId,
        key: IdempotencyKeys.forAdHocRun(
          workflow: workflow,
          startedAt: startedAt,
          kind: 'invalid',
        ),
        scheduledFor: target,
        source: source,
        dryRun: dryRun,
      ).copyWith(
        status: ExecutionStatus.failed,
        startedAt: startedAt,
        finishedAt: time.now(),
        failureReason: reason,
        failureCode: 'workflow.invalid',
      );
      await sink?.onExecutionUpdate(record);
      _emit(ExecutionFinishedEvent(record: record, at: time.now()));
      return record;
    }

    // 2. Idempotency key (spec §21).
    final bool scheduled = source == TriggerSource.schedule && !dryRun;
    final String key = scheduled
        ? IdempotencyKeys.forScheduledRun(workflow: workflow, scheduledFor: target)
        : IdempotencyKeys.forAdHocRun(
            workflow: workflow,
            startedAt: startedAt,
            kind: dryRun ? 'dry_run' : source.wire,
          );

    // 3. Global pause (spec §25).
    if (state.isPaused && !dryRun && scheduled) {
      return _finishSkipped(
        workflow: workflow,
        executionId: executionId,
        key: key,
        scheduledFor: target,
        source: source,
        reason: 'AUTOMETA is paused — no automated actions will execute',
        code: 'engine.paused',
      );
    }

    // 4. Duplicate protection.
    if (!dryRun) {
      final bool claimed = await idempotency.claim(key, executionId: executionId);
      if (!claimed) {
        _log.info('Skipping duplicate execution for "${workflow.name}" (key ${_shortKey(key)})');
        return _finishSkipped(
          workflow: workflow,
          executionId: executionId,
          key: key,
          scheduledFor: target,
          source: source,
          reason: 'Already executed for this scheduled time',
          code: 'engine.duplicate',
        );
      }
    }

    final ExecutionRecord start = _baseRecord(
      workflow: workflow,
      executionId: executionId,
      key: key,
      scheduledFor: target,
      source: source,
      dryRun: dryRun,
    ).copyWith(status: ExecutionStatus.running, startedAt: startedAt);
    await sink?.onExecutionStart(start);
    _emit(ExecutionStartedEvent(record: start, at: startedAt));
    _log.info(
      '${dryRun ? 'DRY RUN' : 'RUN'} "${workflow.name}" '
      '(${source.wire}, ${workflow.steps.length} block(s))',
    );

    final StepContext context = StepContext.create(
      workflow: workflow,
      executionId: executionId,
      dryRun: dryRun,
      source: source,
      scheduledFor: target,
      defaultRecipientName: state.defaultRecipientName,
      runtimeVariables: <String, String>{
        ...state.runtimeVariables,
        ...runtimeVariables,
      },
      clock: time.now,
    );

    final List<StepExecution> results = <StepExecution>[];
    final FlowOutcome outcome = await _runQueue(
      queue: ListQueue<WorkflowStep>.of(workflow.steps),
      context: context,
      results: results,
      workflow: workflow,
      startedAt: startedAt,
      isBackground: isBackground,
    );

    final ExecutionRecord finished = start.copyWith(
      status: outcome.status,
      finishedAt: time.now(),
      stepResults: results,
      failureReason: outcome.reason,
      failureCode: outcome.code,
      resumeAt: outcome.resumeAt,
      resumeProgram: outcome.pendingProgram,
      pendingStepId: outcome.pendingStepId,
      clearFailure: outcome.status == ExecutionStatus.success,
    );

    await sink?.onExecutionUpdate(finished);
    _emit(ExecutionFinishedEvent(record: finished, at: time.now()));
    _log.info('"${workflow.name}" -> ${finished.status.wire}'
        '${finished.failureReason == null ? '' : ' (${finished.failureReason})'}');
    return finished;
  }

  /// Continues a run that was parked on an approval (spec §23).
  ///
  /// Only the tail captured at park time is replayed, so approving never
  /// re-executes the blocks that already ran.
  Future<ExecutionRecord> resumeAfterApproval({
    required Workflow workflow,
    required ExecutionRecord record,
    required bool approved,
    bool isApprovalDecision = true,
    Map<String, String> runtimeVariables = const <String, String>{},
  }) async {
    final DateTime now = time.now();

    if (!approved) {
      final ExecutionRecord rejected = record.copyWith(
        status: ExecutionStatus.cancelled,
        finishedAt: now,
        failureReason: 'Rejected by user',
        failureCode: 'approval.rejected',
        clearPending: true,
      );
      await sink?.onExecutionUpdate(rejected);
      _emit(ExecutionFinishedEvent(record: rejected, at: now));
      return rejected;
    }

    if (record.resumeProgram.isEmpty) {
      final ExecutionRecord nothing = record.copyWith(
        status: ExecutionStatus.skipped,
        finishedAt: now,
        failureReason: 'Nothing left to run after approval',
        failureCode: 'approval.empty_tail',
        clearPending: true,
      );
      await sink?.onExecutionUpdate(nothing);
      _emit(ExecutionFinishedEvent(record: nothing, at: now));
      return nothing;
    }

    final StepContext context = StepContext.create(
      workflow: workflow,
      executionId: record.id,
      dryRun: record.dryRun,
      source: TriggerSource.approvalResume,
      scheduledFor: record.scheduledFor,
      approvalGranted: isApprovalDecision,
      approvedStepId: isApprovalDecision ? record.pendingStepId : null,
      defaultRecipientName: state.defaultRecipientName,
      runtimeVariables: <String, String>{...state.runtimeVariables, ...runtimeVariables},
      clock: time.now,
    );

    final List<StepExecution> results = <StepExecution>[...record.stepResults];
    final FlowOutcome outcome = await _runQueue(
      queue: ListQueue<WorkflowStep>.of(record.resumeProgram),
      context: context,
      results: results,
      workflow: workflow,
      startedAt: now,
      isBackground: true,
    );

    final ExecutionRecord finished = record.copyWith(
      status: outcome.status,
      finishedAt: time.now(),
      stepResults: results,
      failureReason: outcome.reason,
      failureCode: outcome.code,
      resumeAt: outcome.resumeAt,
      resumeProgram: outcome.pendingProgram,
      pendingStepId: outcome.pendingStepId,
      clearPending: outcome.pendingStepId == null,
      clearFailure: outcome.status == ExecutionStatus.success,
    );
    await sink?.onExecutionUpdate(finished);
    _emit(ExecutionFinishedEvent(record: finished, at: time.now()));
    return finished;
  }

  /// Test run (spec §24). Performs no real side effect and is recorded as such.
  Future<DryRunReport> dryRun(Workflow workflow, {DateTime? at}) async {
    final ExecutionRecord record = await execute(
      workflow,
      source: TriggerSource.test,
      scheduledFor: at ?? time.now(),
      dryRun: true,
    );
    return DryRunReport(
      workflow: workflow,
      record: record,
      validation: validator.validate(workflow),
      wouldRunAt: _scheduleCalculator.nextOccurrence(workflow, after: at ?? time.now()),
    );
  }

  // ---------------------------------------------------------------------------
  // Interpreter
  // ---------------------------------------------------------------------------

  Future<FlowOutcome> _runQueue({
    required ListQueue<WorkflowStep> queue,
    required StepContext context,
    required List<StepExecution> results,
    required Workflow workflow,
    required DateTime startedAt,
    required bool isBackground,
  }) async {
    final RetryPolicy retryPolicy = RetryPolicy.fromMaxRetries(workflow.maxRetries);
    int executed = 0;

    while (queue.isNotEmpty) {
      if (time.now().difference(startedAt) > EngineLimits.maxRunDuration) {
        return FlowOutcome(
          status: ExecutionStatus.failed,
          reason: 'Run exceeded the ${EngineLimits.maxRunDuration.inHours} hour safety limit',
          code: 'engine.timeout',
          stepsExecuted: executed,
        );
      }
      if (executed > EngineLimits.maxStepsPerWorkflow * 8) {
        return FlowOutcome(
          status: ExecutionStatus.failed,
          reason: 'Runaway workflow stopped (too many blocks executed)',
          code: 'engine.runaway',
          stepsExecuted: executed,
        );
      }

      final WorkflowStep step = queue.removeFirst();
      executed++;

      // --- IF / ELSE ---------------------------------------------------------
      if (step is ConditionStep) {
        final ConditionEvaluation evaluation = evaluator.evaluate(step.condition, context.resolver);
        results.add(StepExecution(
          stepId: step.id,
          kind: step.kind,
          title: step.condition.describe(),
          outcome: StepOutcome.success,
          detail: evaluation.result ? 'IF branch' : 'ELSE branch',
          startedAt: time.now(),
          finishedAt: time.now(),
          simulated: context.dryRun,
        ));
        _emitStep(context.executionId, workflow, results.last);
        queue.addAllFirst(evaluation.result ? step.thenSteps : step.elseSteps);
        continue;
      }

      // --- WAIT --------------------------------------------------------------
      if (step is DelayStep) {
        final Duration wait = Duration(seconds: step.effectiveSeconds);
        if (context.dryRun) {
          results.add(StepExecution(
            stepId: step.id,
            kind: step.kind,
            title: step.describe(),
            outcome: StepOutcome.simulated,
            detail: 'Would wait ${wait.inMinutes} min',
            startedAt: time.now(),
            finishedAt: time.now(),
            simulated: true,
          ));
          _emitStep(context.executionId, workflow, results.last);
          continue;
        }

        final DelayDecision decision = await _decideDelay(
          step: step,
          context: context,
          workflow: workflow,
          remaining: queue.length,
          isBackground: isBackground,
        );

        if (decision.handling == DelayHandling.reschedule) {
          final DateTime resumeAt = time.now().add(wait);
          results.add(StepExecution(
            stepId: step.id,
            kind: step.kind,
            title: step.describe(),
            outcome: StepOutcome.pending,
            detail: 'Deferred to the scheduler',
            startedAt: time.now(),
          ));
          _emitStep(context.executionId, workflow, results.last);
          return FlowOutcome(
            status: ExecutionStatus.pending,
            reason: 'Waiting ${wait.inMinutes} min',
            code: 'engine.deferred',
            resumeAt: resumeAt,
            pendingStepId: step.id,
            pendingProgram: List<WorkflowStep>.of(queue),
            stepsExecuted: executed,
          );
        }

        await time.sleep(wait);
        results.add(StepExecution(
          stepId: step.id,
          kind: step.kind,
          title: step.describe(),
          outcome: StepOutcome.success,
          detail: 'Waited ${wait.inMinutes} min',
          startedAt: time.now().subtract(wait),
          finishedAt: time.now(),
        ));
        _emitStep(context.executionId, workflow, results.last);
        continue;
      }

      // --- SET VARIABLE ------------------------------------------------------
      if (step is SetVariableStep) {
        final String value = context.resolve(step.value);
        context.setVariable(step.name, value);
        results.add(StepExecution(
          stepId: step.id,
          kind: step.kind,
          title: step.describe(),
          outcome: context.dryRun ? StepOutcome.simulated : StepOutcome.success,
          detail: '${step.name} = $value',
          startedAt: time.now(),
          finishedAt: time.now(),
          simulated: context.dryRun,
        ));
        _emitStep(context.executionId, workflow, results.last);
        continue;
      }

      // --- ACTION BLOCKS -----------------------------------------------------
      final StepExecutor executor = registry.forKind(step.kind) ?? MissingStepExecutor(step.kind);
      final DateTime stepStart = time.now();
      StepResult result = StepResult.failed(reason: 'Not executed', code: 'engine.not_run');
      int attempt = 1;

      while (true) {
        try {
          result = await executor.execute(step, context);
        } catch (error, stackTrace) {
          _log.error('Block ${step.kind.wire} threw', error, stackTrace);
          result = StepResult.failed(
            reason: 'Unexpected error: $error',
            code: '${step.kind.wire}.exception',
            retriable: false,
          );
        }
        if (!result.isFailure || !retryPolicy.shouldRetry(attempt: attempt, retriable: result.retriable)) {
          break;
        }
        final Duration backoff = retryPolicy.backoffFor(attempt);
        _log.warn('Block ${step.kind.wire} failed (attempt $attempt): ${result.detail}. '
            'Retrying in ${backoff.inSeconds}s');
        await time.sleep(backoff);
        attempt++;
      }

      if (result.outputVariables.isNotEmpty) context.mergeVariables(result.outputVariables);

      final StepExecution stepExecution = StepExecution(
        stepId: step.id,
        kind: step.kind,
        title: step.label ?? step.describe(),
        outcome: result.outcome,
        detail: result.detail,
        code: result.code,
        startedAt: stepStart,
        finishedAt: time.now(),
        attempts: attempt,
        simulated: context.dryRun && result.outcome != StepOutcome.failed,
      );
      results.add(stepExecution);
      _emitStep(context.executionId, workflow, stepExecution);

      // Approval gate ---------------------------------------------------------
      if (result.needsApproval) {
        final ApprovalTicket? draft = result.approval;
        final ApprovalTicket ticket = ApprovalTicket(
          id: draft?.id ?? _newId(),
          executionId: context.executionId,
          workflowId: workflow.id,
          workflowName: workflow.name,
          stepId: step.id,
          title: draft?.title ?? 'AUTOMETA needs approval',
          integrationId: draft?.integrationId ?? step.kind.wire,
          action: draft?.action ?? step.kind.wire,
          body: draft?.body ?? '',
          fields: draft?.fields ?? const <String, String>{},
          createdAt: time.now(),
          expiresAt: time.now().add(EngineLimits.approvalTtl),
          simulated: context.dryRun,
        );
        await sink?.onApprovalRequested(ticket);
        _emit(ApprovalRequestedEvent(ticket: ticket, at: time.now()));

        return FlowOutcome(
          status: ExecutionStatus.waitingApproval,
          reason: 'Waiting for approval',
          code: 'approval.required',
          pendingApprovalId: ticket.id,
          pendingStepId: step.id,
          pendingProgram: <WorkflowStep>[step, ...queue],
          stepsExecuted: executed,
        );
      }

      // Deferred wait requested by an executor -------------------------------
      if (result.deferUntil != null) {
        return FlowOutcome(
          status: ExecutionStatus.pending,
          reason: result.detail ?? 'Deferred',
          code: result.code ?? 'engine.deferred',
          resumeAt: result.deferUntil,
          pendingStepId: step.id,
          pendingProgram: <WorkflowStep>[step, ...queue],
          stepsExecuted: executed,
        );
      }

      // Failure handling -----------------------------------------------------
      if (result.isFailure) {
        if (step.continueOnError) {
          results[results.length - 1] = stepExecution.copyWith(
            outcome: StepOutcome.skipped,
            detail: 'Ignored error: ${result.detail}',
          );
          continue;
        }
        return FlowOutcome(
          status: ExecutionStatus.failed,
          reason: result.detail ?? 'Step failed',
          code: result.code,
          stepsExecuted: executed,
        );
      }
    }

    return FlowOutcome(status: ExecutionStatus.success, stepsExecuted: executed);
  }

  Future<DelayDecision> _decideDelay({
    required DelayStep step,
    required StepContext context,
    required Workflow workflow,
    required int remaining,
    required bool isBackground,
  }) async {
    final Duration wait = Duration(seconds: step.effectiveSeconds);
    final DelayHandler? handler = delayHandler;
    if (handler != null) {
      return handler(
        DelayRequest(
          executionId: context.executionId,
          workflowId: workflow.id,
          duration: wait,
          remainingSteps: remaining,
          isBackground: isBackground,
        ),
      );
    }
    // Default policy: short waits in-process, long waits handed to the OS
    // scheduler, because Android will not keep an isolate alive for hours.
    if (wait > maxInProcessWait) return DelayDecision.defer;
    return DelayDecision.sleep;
  }

  ExecutionRecord _baseRecord({
    required Workflow workflow,
    required String executionId,
    required String key,
    required DateTime scheduledFor,
    required TriggerSource source,
    required bool dryRun,
  }) =>
      ExecutionRecord(
        id: executionId,
        workflowId: workflow.id,
        workflowName: workflow.name,
        idempotencyKey: key,
        scheduledFor: scheduledFor,
        status: ExecutionStatus.pending,
        source: source,
        dryRun: dryRun,
        maxAttempts: workflow.maxRetries + 1,
        createdAt: time.now(),
      );

  Future<ExecutionRecord> _finishSkipped({
    required Workflow workflow,
    required String executionId,
    required String key,
    required DateTime scheduledFor,
    required TriggerSource source,
    required String reason,
    required String code,
  }) async {
    final DateTime now = time.now();
    // The audit row gets its own key suffix: reusing the slot key would collide
    // with (and, under REPLACE semantics, overwrite) the run that did happen.
    final ExecutionRecord record = _baseRecord(
      workflow: workflow,
      executionId: executionId,
      key: '$key#skip-$executionId',
      scheduledFor: scheduledFor,
      source: source,
      dryRun: false,
    ).copyWith(
      status: ExecutionStatus.skipped,
      startedAt: now,
      finishedAt: now,
      failureReason: reason,
      failureCode: code,
    );
    await sink?.onExecutionUpdate(record);
    _emit(ExecutionSkippedEvent(record: record, reason: reason, at: now));
    return record;
  }

  void _emitStep(String executionId, Workflow workflow, StepExecution stepExecution) => _emit(
        StepFinishedEvent(
          executionId: executionId,
          workflowName: workflow.name,
          stepResult: stepExecution,
          at: time.now(),
        ),
      );

  void _emit(EngineEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  String _shortKey(String key) => key.length <= 12 ? key : key.substring(key.length - 12);

  Future<void> dispose() async {
    await _events.close();
  }
}
