import 'package:flutter/foundation.dart';

import '../../../domain/models/step.dart';
import '../../connections/connection_state.dart';
import '../integration.dart';
import 'whatsapp_models.dart';

/// What a WhatsApp adapter is allowed to do.
///
/// These lists are the single source of truth for the capability checklist on
/// the connection screen — the UI renders them verbatim, so a capability only
/// ever appears if the adapter really implements it (spec §4, §40).
@immutable
class WhatsAppCapabilities {
  const WhatsAppCapabilities({
    required this.canOpenConversations,
    required this.canPrepareMessages,
    required this.canSendAutomatically,
    required this.canUseTemplates,
    required this.canReportDelivery,
  });

  final bool canOpenConversations;
  final bool canPrepareMessages;
  final bool canSendAutomatically;
  final bool canUseTemplates;
  final bool canReportDelivery;

  static const WhatsAppCapabilities personal = WhatsAppCapabilities(
    canOpenConversations: true,
    canPrepareMessages: true,
    canSendAutomatically: false,
    canUseTemplates: false,
    canReportDelivery: false,
  );

  static const WhatsAppCapabilities business = WhatsAppCapabilities(
    canOpenConversations: false,
    canPrepareMessages: true,
    canSendAutomatically: true,
    canUseTemplates: true,
    canReportDelivery: true,
  );

  List<String> get working {
    final List<String> list = <String>[];
    if (canOpenConversations) list.add('Open conversations');
    if (canPrepareMessages) list.add('Prepare messages');
    if (canSendAutomatically) list.add('API messaging');
    if (canUseTemplates) list.add('Approved templates');
    if (canReportDelivery) list.add('Delivery status');
    return list;
  }
}

/// The contract both WhatsApp integrations satisfy.
///
/// Personal and Business are NOT interchangeable: only [canSendAutomatically]
/// adapters may be given a `send` mode step, and the executor downgrades any
/// other attempt to a prepare/handoff rather than lying about it.
abstract class WhatsAppAdapter {
  const WhatsAppAdapter();

  WhatsAppAccountType get accountType;

  WhatsAppCapabilities get capabilities;

  /// Statements the UI must show alongside the capabilities, so the user is
  /// never left believing more is possible than is.
  List<String> get limitations;

  /// Whether a `send` step can be completed without the user right now.
  /// Only the official WhatsApp Business API can; Personal is always false.
  Future<bool> canSendNow() async => capabilities.canSendAutomatically;

  Future<IntegrationAvailability> check();

  /// Builds the official click-to-chat deep link, or null when this adapter
  /// does not open conversations on device.
  Uri? conversationUri({required String phoneNumberDigits, String? text});

  /// Attempts delivery in the given [mode].
  ///
  /// Implementations must return `notSupported` rather than silently doing
  /// something else, and must never report `delivered` unless they hold proof.
  Future<WhatsAppSendOutcome> deliver({
    required WhatsAppMode mode,
    required String phoneNumberDigits,
    required String body,
    String? templateName,
    String? templateLanguage,
  });
}
