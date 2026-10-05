import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../data/repositories/recipient.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../domain/engine/approval_request.dart';
import '../../../domain/engine/step_context.dart';
import '../../../domain/engine/step_executor.dart';
import '../../../domain/engine/step_result.dart';
import '../../../domain/models/execution.dart';
import '../../../domain/models/step.dart';
import 'whatsapp_adapter.dart';
import 'whatsapp_integration.dart';
import 'whatsapp_models.dart';

/// Runs `WhatsApp` blocks (spec §3, §16, §23, §40).
///
/// Decision table:
///
/// | account   | block mode | what happens                                   |
/// |-----------|-----------|------------------------------------------------|
/// | none      | any       | FAILED — "WhatsApp is not connected"            |
/// | personal  | prepare   | approval → open chat prefilled → user taps Send |
/// | personal  | open      | open chat (no approval, nothing is prepared)    |
/// | personal  | send      | downgraded to prepare, approval still required  |
/// | business  | send      | approval (if configured) → Cloud API POST       |
/// | business  | prepare   | approval → Cloud API POST                       |
/// | business  | open      | FAILED — the Cloud API cannot open a client chat|
///
/// The reported status always matches the table above. A personal-account
/// handoff is reported as "handed to WhatsApp", never as "sent".
class WhatsAppStepExecutor extends StepExecutor {
  WhatsAppStepExecutor({
    required this.integration,
    required this.contacts,
  });

  final WhatsAppIntegration integration;
  final ContactRepository contacts;
  final Logger _log = Logger.withTag(LogTags.whatsapp);

  @override
  StepKind get kind => StepKind.whatsapp;

  @override
  Future<bool> get isAvailable async => await integration.adapter() != null;

  @override
  String get availabilityHint =>
      'Choose a Personal or Business WhatsApp account in Connections';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    if (step is! WhatsAppStep) {
      return StepResult.failed(reason: 'Internal error: wrong block type', code: 'whatsapp.bad_step');
    }

    final WhatsAppAdapter? adapter = await integration.adapterFor(step.account);
    if (adapter == null) {
      return const StepResult.failed(
        reason: 'WhatsApp is not connected. Open Connections and choose Personal or Business.',
        code: 'whatsapp.not_connected',
      );
    }

    final Recipient? recipient = await contacts.byAlias(step.recipient);
    if (recipient == null || !recipient.hasNumber) {
      return StepResult.failed(
        reason: 'No phone number is stored for "${step.recipient}". '
            'Add it under Settings → Contacts.',
        code: 'whatsapp.no_recipient',
      );
    }

    final String message = context.resolve(step.message);
    final WhatsAppMode requested = step.mode;
    WhatsAppMode mode = requested;

    // A `send` request against an adapter that cannot send is downgraded, never
    // silently treated as delivered.
    final bool canSendNow = mode == WhatsAppMode.send && await adapter.canSendNow();
    if (mode == WhatsAppMode.send && !canSendNow) {
      mode = WhatsAppMode.prepare;
      _log.info('Downgraded WhatsApp step to prepare: '
          '${adapter.accountType.label} cannot send automatically');
    }

    if (mode == WhatsAppMode.open && !adapter.capabilities.canOpenConversations) {
      return StepResult.failed(
        reason: '${adapter.accountType.label} cannot open a conversation on this device. '
            'Use "Prepare message" with a Business account, or connect a Personal account.',
        code: 'whatsapp.cannot_open',
      );
    }

    final bool needsApproval =
        _requiresApproval(step: step, adapter: adapter, context: context, autoSend: canSendNow);

    if (needsApproval) {
      return StepResult(
        outcome: StepOutcome.awaitingApproval,
        detail: 'Waiting for your approval',
        code: 'whatsapp.approval_required',
        approval: ApprovalTicket(
          id: '${context.executionId}-${step.id}',
          executionId: context.executionId,
          workflowId: context.workflow.id,
          workflowName: context.workflow.name,
          stepId: step.id,
          title: 'Personal WhatsApp: message for ${recipient.displayName} (you tap Send)',
          integrationId: IntegrationIds.whatsapp,
          action: mode == WhatsAppMode.open ? 'open_conversation' : 'prepare_message',
          body: message,
          fields: <String, String>{
            'Recipient': '${recipient.displayName} (${recipient.maskedNumber})',
            'Account': adapter.accountType.label,
            if (mode != WhatsAppMode.open) 'Message': message,
            if (step.templateName != null) 'Template': step.templateName!,
            if (mode != WhatsAppMode.send)
              'How it is delivered': 'Opens WhatsApp with the message ready. You tap Send.',
          },
          createdAt: context.now(),
          expiresAt: context.now().add(const Duration(hours: 24)),
          simulated: context.dryRun,
        ),
      );
    }

    if (context.dryRun) {
      return StepResult.simulated(
        detail: 'Would run "${mode.label}" for ${recipient.displayName} '
            '(${recipient.maskedNumber}): "$message"',
      );
    }

    final WhatsAppSendOutcome outcome = await adapter.deliver(
      mode: mode,
      phoneNumberDigits: recipient.dialableNumber,
      body: message,
      templateName: step.templateName,
    );

    switch (outcome.state) {
      case WhatsAppDeliveryState.delivered:
      case WhatsAppDeliveryState.held:
        return StepResult(
          outcome: StepOutcome.success,
          detail: outcome.reason ?? outcome.state.label,
          code: 'whatsapp.${outcome.state.wire}',
          outputVariables: <String, String>{
            if (outcome.messageId != null) 'whatsapp_message_id': outcome.messageId!,
          },
        );
      case WhatsAppDeliveryState.handedToUser:
        // Honest state: the chat is open with the text prefilled. AUTOMETA did
        // its part; the user still has to press Send and we cannot see it.
        return const StepResult(
          outcome: StepOutcome.success,
          detail: 'Opened WhatsApp with the message ready — you tap Send. '
              'AUTOMETA cannot confirm delivery on a personal account.',
          code: 'whatsapp.handed_to_user',
        );
      case WhatsAppDeliveryState.failed:
        return StepResult.failed(
          reason: outcome.reason ?? 'WhatsApp delivery failed',
          code: 'whatsapp.failed',
          retriable: outcome.retriable,
        );
      case WhatsAppDeliveryState.notSupported:
        return StepResult.failed(
          reason: outcome.reason ?? 'Not available for this WhatsApp account type',
          code: 'whatsapp.not_supported',
        );
    }
  }

  bool _requiresApproval({
    required WhatsAppStep step,
    required WhatsAppAdapter adapter,
    required StepContext context,
    required bool autoSend,
  }) {
    if (context.dryRun) return false;
    if (context.isApproved(step.id)) return false;
    // Opening a conversation sends nothing, so it is not gated.
    if (step.mode == WhatsAppMode.open) return false;
    // Personal without auto-send can only hand the message to the user, which
    // needs them present: always show the "message ready" card, whatever
    // the block's setting says.
    if (adapter.accountType == WhatsAppAccountType.personal && !autoSend) return true;
    final bool? explicit = step.requiresApproval;
    if (explicit != null) return explicit;
    // Default policy: personal WhatsApp needs approval unless the user has
    // turned on on-device auto-send and this step is set to send.
    return adapter.accountType == WhatsAppAccountType.personal && !autoSend;
  }
}
