import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../capabilities/execution_capabilities.dart';
import '../models/step.dart';
import '../models/trigger.dart';
import '../models/workflow.dart';

enum IssueSeverity { error, warning }

@immutable
class ValidationIssue {
  const ValidationIssue({
    required this.severity,
    required this.message,
    this.stepId,
    this.code,
  });

  final IssueSeverity severity;
  final String message;
  final String? stepId;
  final String? code;

  bool get isError => severity == IssueSeverity.error;

  @override
  String toString() => '${isError ? 'ERROR' : 'WARN '}: $message';
}

@immutable
class ValidationResult {
  const ValidationResult(this.issues);

  final List<ValidationIssue> issues;

  List<ValidationIssue> get errors =>
      issues.where((ValidationIssue i) => i.isError).toList(growable: false);

  List<ValidationIssue> get warnings =>
      issues.where((ValidationIssue i) => !i.isError).toList(growable: false);

  bool get isValid => errors.isEmpty;

  String get summary => isValid
      ? (warnings.isEmpty ? 'Workflow is valid' : '${warnings.length} warning(s)')
      : errors.map((ValidationIssue e) => e.message).join(' · ');
}

/// Validates a workflow definition before it is saved or armed.
///
/// The builder surfaces these as inline warnings; the engine refuses to run
/// anything with an `error`-level issue so a broken definition can never fire
/// half-way through and leave the user guessing.
class WorkflowValidator {
  const WorkflowValidator();

  ValidationResult validate(Workflow workflow) {
    final List<ValidationIssue> issues = <ValidationIssue>[];

    // Capability check for the selected execution mode: an automation can't be
    // armed in a mode that can't actually execute every block.
    for (final CapabilityIssue c in ExecutionCapabilities.check(workflow, workflow.executionMode)) {
      issues.add(ValidationIssue(
        severity: IssueSeverity.error,
        message: '${c.label} can\'t run ${workflow.isCloud ? 'in Cloud' : 'on this device'}. ${c.reason}',
        stepId: c.stepId,
        code: 'capability.${workflow.executionMode.wire}',
      ));
    }

    if (workflow.name.trim().isEmpty) {
      issues.add(const ValidationIssue(
        severity: IssueSeverity.error,
        message: 'Give the automation a name',
        code: 'name.required',
      ));
    }

    if (workflow.steps.isEmpty) {
      issues.add(const ValidationIssue(
        severity: IssueSeverity.error,
        message: 'Add at least one action block',
        code: 'steps.empty',
      ));
    }

    if (workflow.steps.length > EngineLimits.maxStepsPerWorkflow) {
      issues.add(const ValidationIssue(
        severity: IssueSeverity.error,
        message: 'Too many blocks in one workflow',
        code: 'steps.limit',
      ));
    }

    _validateTrigger(workflow, issues);
    _validateSteps(workflow.steps, issues, depth: 0);

    final Set<String> ids = <String>{};
    for (final String id in _collectIds(workflow.steps)) {
      if (id.isEmpty) {
        issues.add(const ValidationIssue(
          severity: IssueSeverity.error,
          message: 'A block is missing its identifier',
          code: 'step.id_missing',
        ));
      } else if (!ids.add(id)) {
        issues.add(ValidationIssue(
          severity: IssueSeverity.error,
          message: 'Two blocks share the identifier "$id"',
          stepId: id,
          code: 'step.id_duplicate',
        ));
      }
    }

    if (workflow.maxRetries < 0 || workflow.maxRetries > EngineLimits.maxRetries) {
      issues.add(ValidationIssue(
        severity: IssueSeverity.error,
        message: 'Retry count must be between 0 and ${EngineLimits.maxRetries}',
        code: 'retry.range',
      ));
    }

    return ValidationResult(issues);
  }

  void _validateTrigger(Workflow workflow, List<ValidationIssue> issues) {
    final WorkflowTrigger trigger = workflow.trigger;
    switch (trigger) {
      case ScheduleTrigger(:final String timeOfDay, :final ScheduleRepeat repeat, :final int dayOfMonth):
        if (RegExp(r'^\d{1,2}:\d{2}$').hasMatch(timeOfDay) == false) {
          issues.add(const ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Schedule time must look like 07:00',
            code: 'trigger.time_format',
          ));
        }
        if ((repeat == ScheduleRepeat.days || repeat == ScheduleRepeat.weekly) &&
            (trigger as ScheduleTrigger).effectiveWeekdays.isEmpty) {
          issues.add(const ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Pick at least one day of the week',
            code: 'trigger.weekdays_empty',
          ));
        }
        if (repeat == ScheduleRepeat.monthly && (dayOfMonth < 1 || dayOfMonth > 31)) {
          issues.add(const ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Day of month must be between 1 and 31',
            code: 'trigger.day_of_month',
          ));
        }
        if (repeat == ScheduleRepeat.interval && (trigger as ScheduleTrigger).intervalMinutes < 5) {
          issues.add(const ValidationIssue(
            severity: IssueSeverity.warning,
            message: 'Intervals shorter than 5 minutes may be deferred by Android',
            code: 'trigger.interval_short',
          ));
        }
      case DateTimeTrigger(:final DateTime at, :final DateTimeRepeat repeat):
        if (repeat == DateTimeRepeat.once && at.isBefore(DateTime.now())) {
          issues.add(const ValidationIssue(
            severity: IssueSeverity.warning,
            message: 'That moment is already in the past',
            code: 'trigger.past',
          ));
        }
      case ManualTrigger():
        break;
      case AppEventTrigger(:final String event):
        if (AppEventTrigger.supportedEvents.containsKey(event) == false) {
          issues.add(const ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Unsupported app event',
            code: 'trigger.event_unknown',
          ));
        }
      case WebhookTrigger(:final String token):
        if (token.trim().isEmpty) {
          issues.add(const ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Webhook trigger needs a secret token',
            code: 'trigger.webhook_token',
          ));
        }
    }
  }

  void _validateSteps(List<WorkflowStep> steps, List<ValidationIssue> issues, {required int depth}) {
    for (final WorkflowStep step in steps) {
      _validateStep(step, issues, depth: depth);
    }
  }

  void _validateStep(WorkflowStep step, List<ValidationIssue> issues, {required int depth}) {
    switch (step) {
      case WhatsAppStep(:final WhatsAppMode mode, :final String recipient, :final String message,
            :final String? templateName):
        if (recipient.trim().isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'WhatsApp block needs a recipient',
            stepId: step.id,
            code: 'whatsapp.recipient',
          ));
        }
        if (mode != WhatsAppMode.open && message.trim().isEmpty && templateName == null) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'WhatsApp block needs a message or a template',
            stepId: step.id,
            code: 'whatsapp.message',
          ));
        }
        if (mode == WhatsAppMode.send) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.warning,
            message: 'Automatic sending uses the official WhatsApp Business API. Connect a Business account, or switch to "Prepare message".',
            stepId: step.id,
            code: 'whatsapp.send_requires_business',
          ));
        }
      case NotificationStep(:final String title, :final String body):
        if (title.trim().isEmpty && body.trim().isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Notification block needs a title or body',
            stepId: step.id,
            code: 'notification.empty',
          ));
        }
      case AiStep(:final String prompt, :final AiTask task):
        if (prompt.trim().isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Describe what the AI should do',
            stepId: step.id,
            code: 'ai.prompt_empty',
          ));
        }
        if ((task == AiTask.rewrite || task == AiTask.summarize) && (step as AiStep).input.trim().isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.warning,
            message: 'This AI task usually needs input text',
            stepId: step.id,
            code: 'ai.input_empty',
          ));
        }
      case HttpStep(:final String url, :final String method):
        if (url.trim().isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'HTTP block needs a URL',
            stepId: step.id,
            code: 'http.url_empty',
          ));
        } else if (Uri.tryParse(url) == null || url.startsWith('http') == false) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'URL must start with http:// or https://',
            stepId: step.id,
            code: 'http.url_invalid',
          ));
        }
        if (HttpStep.methods.contains(method) == false) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Unsupported HTTP method "$method"',
            stepId: step.id,
            code: 'http.method',
          ));
        }
      case WebhookStep(:final String url):
        if (url.trim().isEmpty || url.startsWith('https://') == false) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Webhook URL must use https://',
            stepId: step.id,
            code: 'webhook.url',
          ));
        }
      case ClipboardStep(:final String text):
        if (text.trim().isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.warning,
            message: 'Clipboard block will copy an empty string',
            stepId: step.id,
            code: 'clipboard.empty',
          ));
        }
      case OpenUrlStep(:final String url):
        if (url.trim().isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Open URL block needs a link',
            stepId: step.id,
            code: 'open_url.empty',
          ));
        }
      case ConditionStep(:final List<WorkflowStep> thenSteps, :final List<WorkflowStep> elseSteps):
        if (thenSteps.isEmpty && elseSteps.isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Condition block has no branches',
            stepId: step.id,
            code: 'condition.empty',
          ));
        }
        if (depth + 1 > EngineLimits.maxConditionDepth) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Conditions are nested too deeply',
            stepId: step.id,
            code: 'condition.depth',
          ));
        }
        _validateSteps(thenSteps, issues, depth: depth + 1);
        _validateSteps(elseSteps, issues, depth: depth + 1);
      case DelayStep():
        break;
      case SetVariableStep(:final String name):
        if (name.trim().isEmpty) {
          issues.add(ValidationIssue(
            severity: IssueSeverity.error,
            message: 'Variable needs a name',
            stepId: step.id,
            code: 'variable.name',
          ));
        }
    }
  }

  Iterable<String> _collectIds(List<WorkflowStep> steps) sync* {
    for (final WorkflowStep step in steps) {
      yield step.id;
      if (step case ConditionStep(:final List<WorkflowStep> thenSteps, :final List<WorkflowStep> elseSteps)) {
        yield* _collectIds(thenSteps);
        yield* _collectIds(elseSteps);
      }
    }
  }
}
