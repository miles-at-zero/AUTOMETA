import 'dart:convert';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../domain/models/step.dart';
import '../../connections/connection_state.dart';
import '../integration.dart';
import '../../net/api_client.dart';
import '../../../core/security/secret_store.dart';
import 'whatsapp_adapter.dart';
import 'whatsapp_models.dart';

typedef TokenProvider = Future<String?> Function();
typedef ConfigProvider = Future<WhatsAppBusinessConfig> Function();

/// Official WhatsApp Business Platform (Cloud API) integration.
///
/// Verified against Meta's published reference at the time of writing:
///   POST https://graph.facebook.com/{Version}/{Phone-Number-ID}/messages
///   Authorization: Bearer <system user access token>
///   { "messaging_product": "whatsapp", "recipient_type": "individual",
///     "to": "<E.164>", "type": "text", "text": { "body": "..." } }
///
/// Because Meta ships three or four Graph API versions a year and retires them
/// on a roughly two-year clock, the version is a stored setting
/// ([WhatsAppBusinessConfig.apiVersion]) rather than a hard-coded constant.
///
/// Prerequisites the user must complete in Meta Business Manager — the setup
/// screen lists these, the app cannot do them:
///   1. A Meta developer app with the WhatsApp product added.
///   2. Business verification.
///   3. A registered phone number (yields the Phone Number ID).
///   4. A system-user access token with `whatsapp_business_messaging`.
///   5. Approved message templates for business-initiated conversations.
class BusinessWhatsAppAdapter extends WhatsAppAdapter {
  BusinessWhatsAppAdapter({
    required ApiClient apiClient,
    required SecretStore secrets,
    ConfigProvider? configProvider,
  })  : _api = apiClient,
        _secrets = secrets,
        _configProvider = configProvider;

  final ApiClient _api;
  final SecretStore _secrets;
  final ConfigProvider? _configProvider;
  final Logger _log = Logger.withTag(LogTags.whatsapp);

  WhatsAppBusinessConfig _config = const WhatsAppBusinessConfig();

  /// Cache of the last successful verification, used for instant UI while a
  /// fresh check is in flight.
  WhatsAppBusinessConfig get config => _config;

  Future<WhatsAppBusinessConfig> _loadConfig() async {
    if (_configProvider != null) {
      _config = await _configProvider!();
      return _config;
    }
    return _config;
  }

  Future<void> configure(WhatsAppBusinessConfig config) async {
    _config = config;
  }

  @override
  WhatsAppAccountType get accountType => WhatsAppAccountType.business;

  @override
  WhatsAppCapabilities get capabilities => WhatsAppCapabilities.business;

  @override
  List<String> get limitations => const <String>[
        'Business-initiated conversations outside the 24-hour window need an approved template',
        'Templates must be created and approved in Meta Business Manager first',
        'Meta rate limits and per-message charges apply to your business account',
      ];

  @override
  Future<IntegrationAvailability> check() async {
    final WhatsAppBusinessConfig config = await _loadConfig();

    if (!config.hasPhoneNumberId) {
      return const IntegrationAvailability(
        status: ConnectionStatus.needsConfiguration,
        accountType: 'business',
        label: 'Business account',
        capabilities: <String>[],
        limitations: <String>['Add your WhatsApp Phone Number ID'],
      );
    }

    final String? token = await _secrets.read(SecretKeys.whatsappBusinessToken);
    if (token == null || token.isEmpty) {
      return const IntegrationAvailability(
        status: ConnectionStatus.needsConfiguration,
        accountType: 'business',
        label: 'Business account',
        capabilities: <String>[],
        limitations: <String>['Add a system user access token'],
      );
    }

    final ApiResponse response = await _api.send(ApiRequest(
      method: 'GET',
      url: '${config.phoneNumberInfoUrl}?fields=verified_name,display_phone_number,quality_rating',
      headers: <String, String>{'Authorization': 'Bearer $token'},
    ));

    if (!response.reachedServer) {
      return IntegrationAvailability(
        status: ConnectionStatus.error,
        accountType: 'business',
        label: 'Business account',
        limitations: <String>[response.transportError ?? 'Could not reach Meta'],
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      return IntegrationAvailability(
        status: ConnectionStatus.error,
        accountType: 'business',
        label: 'Business account',
        limitations: <String>[
          'Meta rejected the access token (${response.errorMessage})',
        ],
        metadata: <String, String>{'graph_error_code': '${response.errorCode ?? ''}'},
      );
    }

    if (!response.isSuccess) {
      return IntegrationAvailability(
        status: ConnectionStatus.error,
        accountType: 'business',
        label: 'Business account',
        limitations: <String>['HTTP ${response.statusCode}: ${response.errorMessage}'],
      );
    }

    final Map<String, dynamic> info = response.json;
    final String verifiedName = '${info['verified_name'] ?? ''}';
    final String displayNumber = '${info['display_phone_number'] ?? ''}';
    final String quality = '${info['quality_rating'] ?? 'UNKNOWN'}';

    _log.info('WhatsApp Business verified (quality $quality)');
    return IntegrationAvailability(
      status: ConnectionStatus.connected,
      accountType: 'business',
      label: verifiedName.isEmpty ? 'Business account' : verifiedName,
      capabilities: capabilities.working,
      limitations: limitations,
      metadata: <String, String>{
        if (displayNumber.isNotEmpty) 'display_phone_number': displayNumber,
        'quality_rating': quality,
        'api_version': config.effectiveVersion,
      },
    );
  }

  @override
  Uri? conversationUri({required String phoneNumberDigits, String? text}) => null;

  @override
  Future<WhatsAppSendOutcome> deliver({
    required WhatsAppMode mode,
    required String phoneNumberDigits,
    required String body,
    String? templateName,
    String? templateLanguage,
  }) async {
    final WhatsAppBusinessConfig config = await _loadConfig();
    if (!config.hasPhoneNumberId) {
      return const WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.failed,
        reason: 'WhatsApp Business is not configured with a Phone Number ID',
      );
    }
    final String? token = await _secrets.read(SecretKeys.whatsappBusinessToken);
    if (token == null || token.isEmpty) {
      return const WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.failed,
        reason: 'WhatsApp Business access token is missing',
      );
    }

    if (phoneNumberDigits.replaceAll(RegExp(r'[^0-9]'), '').isEmpty) {
      return const WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.failed,
        reason: 'No phone number is stored for that recipient',
      );
    }

    final Map<String, dynamic> payload = templateName == null || templateName.isEmpty
        ? <String, dynamic>{
            'messaging_product': 'whatsapp',
            'recipient_type': 'individual',
            'to': phoneNumberDigits,
            'type': 'text',
            'text': <String, dynamic>{'preview_url': false, 'body': body},
          }
        : <String, dynamic>{
            'messaging_product': 'whatsapp',
            'recipient_type': 'individual',
            'to': phoneNumberDigits,
            'type': 'template',
            'template': <String, dynamic>{
              'name': templateName,
              'language': <String, String>{
                'code': templateLanguage ?? config.defaultTemplateLanguage,
              },
              if (body.isNotEmpty)
                'components': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'body',
                    'parameters': <Map<String, String>>[
                      <String, String>{'type': 'text', 'text': body},
                    ],
                  },
                ],
            },
          };

    final ApiResponse response = await _api.send(ApiRequest(
      method: 'POST',
      url: config.messagesUrl,
      headers: <String, String>{
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    ));

    if (!response.reachedServer) {
      return WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.failed,
        reason: response.transportError ?? 'Could not reach Meta',
      );
    }

    if (!response.isSuccess) {
      _log.warn('Cloud API rejected the message: ${response.errorMessage}');
      return WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.failed,
        reason: 'Meta rejected the request (${response.statusCode}): ${response.errorMessage}',
      );
    }

    final Map<String, dynamic> json = response.json;
    final List<dynamic> messages = (json['messages'] as List<dynamic>?) ?? <dynamic>[];
    final String? messageId = messages.isEmpty
        ? null
        : '${(messages.first as Map<String, dynamic>)['id'] ?? ''}';
    final String status = messages.isEmpty
        ? ''
        : '${(messages.first as Map<String, dynamic>)['message_status'] ?? ''}';

    if (status == 'held_for_quality_assessment') {
      return WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.held,
        messageId: messageId,
        reason: 'Accepted by WhatsApp and held for quality assessment',
      );
    }
    if (status == 'paused') {
      return WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.failed,
        messageId: messageId,
        reason: 'WhatsApp paused this message (per-message marketing limits)',
      );
    }

    return WhatsAppSendOutcome(
      state: WhatsAppDeliveryState.delivered,
      messageId: messageId,
      reason: messageId == null
          ? 'Accepted by WhatsApp'
          : 'Accepted by WhatsApp (message id ${messageId.length > 18 ? '${messageId.substring(0, 18)}…' : messageId})',
    );
  }
}
