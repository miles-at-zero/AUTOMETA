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
/// What this adapter deliberately does NOT do, and why:
///
///  * No WhatsApp Web scraping, Selenium or headless browser automation.
///  * No reverse-engineered protocol, unofficial client API or session/QR
///    token extraction.
///  * No anti-ban or rate-limit evasion.
///
/// None of those are sanctioned by WhatsApp, all of them risk the user's
/// account, and none of them can be verified as delivered. The only officially
/// documented way to start a conversation from a third-party app is the
/// click-to-chat deep link (`https://wa.me/<number>?text=...`), which opens
/// the chat with the text prefilled and requires the user to press Send.
///
/// Consequence, stated plainly everywhere in the UI: automatic sending is not
/// available for a personal account, and AUTOMETA cannot confirm delivery.
class PersonalWhatsAppAdapter extends WhatsAppAdapter {
  PersonalWhatsAppAdapter({UrlProbe? probe, UrlOpener? opener})
      : _probe = probe ?? launcher.canLaunchUrl,
        _open = opener ?? _launchExternal;

  final UrlProbe _probe;
  final UrlOpener _open;
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
        'Automatic sending is not available for this account type',
        'You tap Send inside WhatsApp — AUTOMETA cannot confirm delivery',
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
      return const WhatsAppSendOutcome(
        state: WhatsAppDeliveryState.notSupported,
        reason: 'A personal WhatsApp account cannot send automatically. '
            'Switch the block to "Prepare message" or connect a Business account.',
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
