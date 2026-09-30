import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
import '../../../domain/models/step.dart';
import '../../connections/connection_state.dart';
import '../integration.dart';
import 'business_whatsapp_adapter.dart';
import 'personal_whatsapp_adapter.dart';
import 'whatsapp_adapter.dart';
import 'whatsapp_models.dart';

/// The WhatsApp entry on the Connections page.
///
/// One service, two mutually exclusive adapters. The active adapter is chosen
/// by the user on the connection screen and is the only thing the executor
/// ever talks to, so a personal account can never silently gain "send"
/// behaviour.
class WhatsAppIntegration extends Integration {
  WhatsAppIntegration({
    required this.personalAdapter,
    required this.businessAdapter,
    required this.activeTypeProvider,
    required this.activeTypeWriter,
  });

  final PersonalWhatsAppAdapter personalAdapter;
  final BusinessWhatsAppAdapter businessAdapter;

  /// Reads which account type the user selected.
  final Future<WhatsAppAccountType?> Function() activeTypeProvider;

  /// Persists the user's selection.
  final Future<void> Function(WhatsAppAccountType? type) activeTypeWriter;

  WhatsAppAccountType? _activeType;

  @override
  String get id => IntegrationIds.whatsapp;

  @override
  String get displayName => 'WhatsApp';

  @override
  String get blurb => 'Personal account (approval required) or Business Cloud API';

  @override
  List<StepKind> get stepKinds => const <StepKind>[StepKind.whatsapp];

  Future<WhatsAppAccountType?> activeType() async {
    _activeType ??= await activeTypeProvider();
    return _activeType;
  }

  Future<void> selectType(WhatsAppAccountType type) async {
    _activeType = type;
    await activeTypeWriter(type);
  }

  Future<void> clearType() async {
    _activeType = null;
    await activeTypeWriter(null);
  }

  /// The adapter that will act right now, or null when nothing is selected.
  Future<WhatsAppAdapter?> adapter() async {
    final WhatsAppAccountType? type = await activeType();
    return switch (type) {
      WhatsAppAccountType.personal => personalAdapter,
      WhatsAppAccountType.business => businessAdapter,
      null => null,
    };
  }

  /// Adapter for one step: an explicit per-automation account wins over the
  /// default chosen in Connections.
  Future<WhatsAppAdapter?> adapterFor(String? account) async {
    switch (WhatsAppAccountType.fromWire(account)) {
      case WhatsAppAccountType.personal:
        return personalAdapter;
      case WhatsAppAccountType.business:
        return businessAdapter;
      case null:
        return adapter();
    }
  }

  @override
  Future<IntegrationAvailability> check() async {
    final WhatsAppAccountType? type = await activeType();
    if (type == null) {
      return const IntegrationAvailability(
        status: ConnectionStatus.notConnected,
        label: 'Choose Personal or Business',
        capabilities: <String>[],
        limitations: <String>[
          'Personal accounts need your approval before every message',
          'Business accounts can send automatically through the official Cloud API',
        ],
      );
    }

    final WhatsAppAdapter adapter =
        type == WhatsAppAccountType.personal ? personalAdapter : businessAdapter;
    // Whatever the adapter reports is returned verbatim: a configured but
    // broken connection must never read as "connected".
    return adapter.check();
  }

  @override
  Future<void> disconnect() async {
    await clearType();
  }
}
