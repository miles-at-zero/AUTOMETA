import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../domain/models/step.dart';
import '../../connections/connection_state.dart';
import '../integration.dart';
import 'whatsapp_adapter.dart';
import 'whatsapp_models.dart';

typedef UrlProbe = Future<bool> Function(Uri uri);
typedef UrlOpener = Future<bool> Function(Uri uri);

/// Personal-account WhatsApp integration.
///
/// The only delivery path is the official click-to-chat hand-off: Autometa
/// prepares the message, opens the chat with the text filled in, and the user
/// taps Send. Autometa never sends from the consumer WhatsApp app by itself:
/// no Accessibility/UI automation, simulated taps, unofficial clients or
/// WhatsApp Web scraping. Automatic sending is only available through the
/// official WhatsApp Business API (see BusinessWhatsAppAdapter / Cloud).
class PersonalWhatsAppAdapter extends WhatsAppAdapter {
  PersonalWhatsAppAdapter({UrlProbe? probe, UrlOpener? opener})
      : _probe = probe ?? launcher.canLaunchUrl,
        _open = opener ?? _launchExternal;

  final UrlProbe _probe;
  final UrlOpener _open;

  /// Personal accounts can never send without the user.
  @override
  Future<bool> canSendNow() async => false;
  final Logger _log = Logger.withTag(LogTags.whatsapp);

  /// Scheme used to detect an installed WhatsApp client. Declared in the
  /// Android manifest's `<queries>` block so package visibility rules allow it.
  static final Uri _probeUri = Uri.parse('whatsapp://send?phone=0');

  static Future<bool> _launchExternal(Uri uri) => launcher.launchUrl(
        uri,
        mode: launcher.LaunchMode.externalApplication,
      );

  @override
  WhatsAppAccountType get accountType => WhatsAppAccountType.personal;

  @override
  WhatsAppCapabilities get capabilities => WhatsAppCapabilities.personal;

  @override
  List<String> get limitations => const <String>[
        'You tap Send inside WhatsApp; Autometa never sends from personal WhatsApp by itself',
        'Autometa cannot confirm delivery of messages you send yourself',
        'For automatic sending, connect the official WhatsApp Business API',
        'Requires the WhatsApp app to be installed on this device',
      ];

  @override
  Future<IntegrationAvailability> check() async {
    bool installed;
    try {
      installed = await _probe(_probeUri);
    } catch (error) {
      _log.warn('Could not probe for WhatsApp', error);
      return const IntegrationAvailability(
        status: ConnectionStatus.pendingVerification,
        accountType: 'personal',
        label: 'Personal account',
        capabilities: <String>[],
        limitations: <String>['Could not check whether WhatsApp is installed'],
      );
    }

    if (!installed) {
      return const IntegrationAvailability(
        status: ConnectionStatus.unavailable,
        accountType: 'personal',
        label: 'Personal account',
        capabilities: <String>[],
        limitations: <String>['WhatsApp app not found on this device'],
      );
    }

    return IntegrationAvailability(
      status: ConnectionStatus.degraded,
      accountType: 'personal',
      label: 'Personal account · approval required',
      capabilities: capabilities.working,
      limitations: limitations,
      metadata: const <String, String>{'handoff': 'click_to_chat'},
    );
  }

  @override
  Uri? conversationUri({required String phoneNumberDigits, String? text}) {
    final String digits = phoneNumberDigits.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    final Map<String, String> query = <String, String>{
      if (text != null && text.isNotEmpty) 'text': text,
    };
    return Uri(
      scheme: 'https',
      host: 'wa.me',
      path: '/$digits',
      queryParameters: query.isEmpty ? null : query,
    );
  }

  @override
  Future<WhatsAppSendOutcome> deliver({
    required WhatsAppMode mode,
    required String phoneNumberDigits,
    required String body,
    String? templateName,
    String? templateLanguage,
  }) async {
    if (mode == WhatsAppMode.send) {
      final String digits = phoneNumberDigits.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isEmpty) {
        return const WhatsAppSendOutcome(
          state: WhatsAppDeliveryState.failed,
          reason: 'No phone number is stored for that recipient',
        );
      }
      return const WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.notSupported,
        reason: 'Personal WhatsApp can\'t send automatically. Switch this block to "Prepare message" '
            '(you tap Send) or use a WhatsApp Business API connection.',
      );
    }

    final Uri? uri = conversationUri(phoneNumberDigits: phoneNumberDigits, text: body);
    if (uri == null) {
      return const WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.failed,
        reason: 'No phone number is stored for that recipient',
      );
    }

    try {
      final bool launched = await _open(uri);
      if (!launched) {
        return WhatsAppSendOutcome(
          state: WhatsAppDeliveryState.failed,
          reason: 'WhatsApp did not open the conversation',
          handoffUri: uri,
        );
      }
    } catch (error) {
      _log.warn('Failed to open WhatsApp conversation', error);
      return WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.failed,
        reason: 'WhatsApp could not be opened: $error',
        handoffUri: uri,
      );
    }

    _log.info('Handed conversation to WhatsApp (delivery not confirmed)');
    return WhatsAppSendOutcome(
      state: WhatsAppDeliveryState.handedToUser,
      handoffUri: uri,
      reason: 'Opened the conversation with the message ready. Tap Send inside WhatsApp.',
    );
  }
}
