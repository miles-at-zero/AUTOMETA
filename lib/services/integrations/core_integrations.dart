import '../../core/constants/app_constants.dart';
import '../../domain/models/step.dart';
import '../ai/ai_provider.dart';
import '../ai/ai_service.dart';
import '../notifications/notification_service.dart';
import '../scheduler/alarm_platform.dart';
import '../connections/connection_state.dart';
import 'integration.dart';

/// AI entry on the Connections page.
class AiIntegration extends Integration {
  AiIntegration({required this.ai});

  final AiService ai;

  @override
  String get id => IntegrationIds.ai;

  @override
  String get displayName => 'AI';

  @override
  String get blurb => 'Text generation for AI blocks and the quick-create parser';

  @override
  List<StepKind> get stepKinds => const <StepKind>[StepKind.ai];

  @override
  Future<IntegrationAvailability> check() async {
    final AiAvailability availability = await ai.check();
    return IntegrationAvailability(
      status: availability.available ? ConnectionStatus.connected : ConnectionStatus.notConnected,
      label: availability.label,
      capabilities: availability.available
          ? <String>[
              'Generate text',
              'Rewrite',
              'Summarize',
              'Classify',
              'Extract information',
              'Natural-language automation creator',
            ]
          : const <String>[],
      limitations: availability.available
          ? (ai.settings.providerId.requiresApiKey
              ? const <String>['Every call uses your API quota and may be billed']
              : const <String>['On-device templates are deterministic, not a language model'])
          : <String>[availability.detail],
      metadata: <String, String>{'provider': ai.settings.providerId.wire},
    );
  }

  @override
  Future<void> disconnect() => ai.clearApiKey();
}

/// Local notification entry.
class NotificationIntegration extends Integration {
  NotificationIntegration({required this.notifications, required this.platform});

  final NotificationService notifications;
  final AlarmPlatform platform;

  @override
  String get id => IntegrationIds.notification;

  @override
  String get displayName => 'Notifications';

  @override
  String get blurb => 'Local Android notifications';

  @override
  List<StepKind> get stepKinds => const <StepKind>[StepKind.notification];

  @override
  Future<IntegrationAvailability> check() async {
    final bool permitted = await platform.notificationsPermitted;
    return IntegrationAvailability(
      status: permitted ? ConnectionStatus.connected : ConnectionStatus.needsConfiguration,
      label: permitted ? 'Permitted' : 'Permission not granted',
      capabilities: permitted
          ? const <String>['Completed runs', 'Failed runs', 'Approvals', 'Upcoming runs']
          : const <String>[],
      limitations: permitted
          ? const <String>['Android 13+ can revoke permission at any time']
          : const <String>['Allow notifications in system settings to enable this'],
    );
  }

  @override
  Future<void> disconnect() async {
    await notifications.cancelAll();
  }
}

/// HTTP entry. No account to connect; availability is just "the block exists".
class HttpIntegration extends Integration {
  const HttpIntegration();

  @override
  String get id => IntegrationIds.http;

  @override
  String get displayName => 'HTTP';

  @override
  String get blurb => 'Call any REST endpoint from a workflow';

  @override
  List<StepKind> get stepKinds => const <StepKind>[StepKind.http];

  @override
  bool get isConfigurable => false;

  @override
  Future<IntegrationAvailability> check() async => const IntegrationAvailability(
        status: ConnectionStatus.connected,
        label: 'Available',
        capabilities: <String>['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'Status assertions'],
        limitations: <String>[
          'Requires an internet connection at run time',
          'Store API keys in the header field, never in the URL',
        ],
      );

  @override
  Future<void> disconnect() async {}
}

/// Inbound webhook entry.
class WebhookIntegration extends Integration {
  WebhookIntegration({required this.endpointProvider});

  /// Returns the URL an external service should POST to, or null when no
  /// endpoint is configured.
  final Future<String?> Function() endpointProvider;

  @override
  String get id => IntegrationIds.webhook;

  @override
  String get displayName => 'Webhooks';

  @override
  String get blurb => 'Trigger workflows from outside the app, and POST out';

  @override
  List<StepKind> get stepKinds => const <StepKind>[StepKind.webhook];

  @override
  Future<IntegrationAvailability> check() async {
    final String? endpoint = await endpointProvider();
    return IntegrationAvailability(
      status: endpoint == null ? ConnectionStatus.needsConfiguration : ConnectionStatus.connected,
      label: endpoint == null ? 'No endpoint configured' : 'Endpoint ready',
      capabilities: endpoint == null
          ? const <String>[]
          : const <String>['Outbound POST', 'Inbound trigger tokens'],
      limitations: const <String>[
        'Inbound delivery requires the app process to be reachable; '
            'a missed webhook is retried by the sender, not by AUTOMETA',
      ],
      metadata: <String, String>{if (endpoint != null) 'endpoint': endpoint},
    );
  }

  @override
  Future<void> disconnect() async {}
}
