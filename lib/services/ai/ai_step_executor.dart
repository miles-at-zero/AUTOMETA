import '../../domain/engine/step_context.dart';
import '../../domain/engine/step_executor.dart';
import '../../domain/engine/step_result.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/step.dart';
import 'ai_provider.dart';
import 'ai_service.dart';
import 'openai_compatible_provider.dart';

/// Runs `AI` blocks (spec §12).
///
/// The result is written into the run's variable bag under the block's
/// `output_variable`, so a later WhatsApp or notification block can reference
/// it as `{{ai_output}}`.
class AiStepExecutor extends StepExecutor {
  AiStepExecutor({required this.ai});

  final AiService ai;

  @override
  StepKind get kind => StepKind.ai;

  @override
  Future<bool> get isAvailable => ai.isReady;

  @override
  String get availabilityHint => 'Configure an AI provider in Settings → AI Provider';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    if (step is! AiStep) {
      return StepResult.failed(reason: 'Internal error: wrong block type', code: 'ai.bad_step');
    }

    final String instruction = context.resolve(step.prompt);
    final String input = context.resolve(step.input);
    if (instruction.trim().isEmpty) {
      return const StepResult.failed(
        reason: 'The AI block has no instruction',
        code: 'ai.no_instruction',
      );
    }

    final AiPrompt prompt = AiPrompt(
      task: step.task,
      instruction: instruction,
      input: input,
      tone: step.tone.isEmpty ? 'Warm' : step.tone,
      maxLength: step.maxLength,
      systemContext: _contextLine(context),
    );

    if (context.dryRun) {
      final String provider = ai.settings.providerId.label;
      return StepResult.simulated(
        detail: 'Would ask $provider to ${step.task.label.toLowerCase()}: '
            '"${_clip(instruction)}"',
      );
    }

    try {
      final AiCompletion completion = await ai.complete(prompt);
      final String text = _enforceLimit(completion.text, step.maxLength);
      return StepResult(
        outcome: StepOutcome.success,
        detail: completion.providerId == AiProviderId.localTemplates
            ? 'LOCAL TEMPLATES · ${_clip(text)}'
            : '${completion.model.isEmpty ? 'AI' : completion.model} · ${_clip(text)}',
        code: completion.providerId == AiProviderId.localTemplates
            ? 'ai.local_templates'
            : 'ai.completed',
        outputVariables: <String, String>{
          step.outputVariable: text,
          '${step.outputVariable}_provider': completion.providerId.wire,
          '${step.outputVariable}_model': completion.model,
          // `{{message}}` is the documented alias for "the text to send".
          if (step.outputVariable == 'ai_output') 'message': text,
        },
      );
    } on AiProviderException catch (error) {
      return StepResult.failed(
        reason: error.message,
        code: error.code ?? 'ai.failed',
        retriable: error.retriable,
      );
    }
  }

  String _contextLine(StepContext context) {
    final Map<String, String> vars = context.variables;
    final List<String> parts = <String>[
      if (vars['datetime'] != null) 'Now: ${vars['datetime']}',
      if (vars['day'] != null) 'Day: ${vars['day']}',
      if (vars['name'] != null && vars['name']!.isNotEmpty) 'Recipient name: ${vars['name']}',
      'Workflow: ${context.workflow.name}',
    ];
    return parts.join(' · ');
  }

  static String _clip(String value) =>
      value.length <= 90 ? value.replaceAll('\n', ' ') : '${value.substring(0, 90).replaceAll('\n', ' ')}…';

  static String _enforceLimit(String value, int maxLength) {
    if (value.length <= maxLength) return value.trim();
    return value.substring(0, maxLength).trim();
  }
}
