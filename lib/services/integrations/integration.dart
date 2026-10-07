import 'package:flutter/foundation.dart';

import '../../domain/models/step.dart';
import '../connections/connection_state.dart';

/// What an integration can and cannot do, verified at runtime.
@immutable
class IntegrationAvailability {
  const IntegrationAvailability({
    required this.status,
    this.accountType,
    this.label = '',
    this.capabilities = const <String>[],
    this.limitations = const <String>[],
    this.metadata = const <String, String>{},
  });

  final ConnectionStatus status;
  final String? accountType;
  final String label;
  final List<String> capabilities;
  final List<String> limitations;
  final Map<String, String> metadata;

  ConnectionRecord toRecord(String service, {DateTime? connectedAt}) => ConnectionRecord(
        service: service,
        status: status,
        accountType: accountType,
        label: label,
        capabilities: capabilities,
        limitations: limitations,
        metadata: metadata,
        connectedAt: connectedAt,
        updatedAt: DateTime.now(),
      );
}

/// A connectable external service.
///
/// Registering a new integration is a matter of implementing this interface
/// and adding it to the registry at startup — no engine or UI change required
/// (spec §17).
abstract class Integration {
  const Integration();

  /// Stable id, e.g. `whatsapp`.
  String get id;

  /// Display name, e.g. `WhatsApp`.
  String get displayName;

  /// One-line explanation for the connections list.
  String get blurb;

  /// Block kinds this integration backs.
  List<StepKind> get stepKinds;

  /// Whether the user can configure it from the app at all.
  bool get isConfigurable => true;

  /// Performs a real check. Implementations must not guess: if the check
  /// cannot be completed, return [ConnectionStatus.pendingVerification].
  Future<IntegrationAvailability> check();

  /// Clears stored configuration and secrets.
  Future<void> disconnect();
}

/// The registry the Connections page renders from.
class IntegrationRegistry {
  IntegrationRegistry([Iterable<Integration>? integrations]) {
    if (integrations != null) {
      for (final Integration integration in integrations) {
        register(integration);
      }
    }
  }

  final Map<String, Integration> _byId = <String, Integration>{};

  void register(Integration integration) => _byId[integration.id] = integration;

  void unregister(String id) => _byId.remove(id);

  Integration? byId(String id) => _byId[id];

  List<Integration> get all => _byId.values.toList(growable: false);

  /// Services the app knows about but has no implementation for. These are
  /// listed as `Not available` rather than being hidden or faked (spec §17).
  static const List<PlannedIntegration> planned = <PlannedIntegration>[
    PlannedIntegration('email', 'Email / Gmail', 'Sending and reading email',
        cloudNote: 'Gmail works in Cloud automations once the Cloud server has Google sign-in configured.'),
    PlannedIntegration('telegram', 'Telegram', 'Bot API messaging',
        cloudNote: 'Available in Cloud automations: connect your bot in Autometa Cloud.'),
    PlannedIntegration('discord', 'Discord', 'Webhook posting'),
    PlannedIntegration('slack', 'Slack', 'Incoming webhooks'),
    PlannedIntegration('google_calendar', 'Google Calendar', 'Event creation and lookup'),
    PlannedIntegration('google_drive', 'Google Drive', 'File upload and sharing'),
    PlannedIntegration('notion', 'Notion', 'Database rows and pages'),
    PlannedIntegration('github', 'GitHub', 'Issues, releases and workflows'),
    PlannedIntegration('todoist', 'Todoist', 'Task creation'),
    PlannedIntegration('weather', 'Weather', 'Forecast lookups for AI blocks'),
    PlannedIntegration('rss', 'RSS / News', 'Feed polling'),
  ];
}

/// A future integration, listed in the UI as explicitly not available.
@immutable
class PlannedIntegration {
  const PlannedIntegration(this.id, this.displayName, this.blurb, {this.cloudNote});

  final String id;
  final String displayName;
  final String blurb;

  /// Set when the service already works in Cloud automations (server side)
  /// but not on this device, so the UI can say "Cloud only" instead of
  /// implying it doesn't exist. Null = coming soon everywhere.
  final String? cloudNote;

  bool get availableInCloud => cloudNote != null;
}
