import 'package:url_launcher/url_launcher.dart' as launcher;
import 'package:whatsapp_auto_send/whatsapp_auto_send.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../domain/models/step.dart';
import '../../connections/connection_state.dart';
import '../integration.dart';
import 'whatsapp_adapter.dart';
import 'whatsapp_models.dart';

typedef UrlProbe = Future<bool> Function(Uri uri);
typedef UrlOpener = Future<bool> Function(Uri uri);
typedef AutoSendStatusProbe = Future<AutoSendServiceStatus> Function();
typedef AutoSender = Future<AutoSendResult> Function(String phoneDigits, String text);

/// Personal-account WhatsApp integration.
///
/// Two delivery paths, both using the WhatsApp app on this phone:
///
///  * **Hand-off (default):** the official click-to-chat link opens the chat
///    with the text prefilled and the user taps Send.
///  * **On-device auto-send (opt-in):** when the user enables AUTOMETA's
///    Accessibility Service, AUTOMETA opens the same chat and presses Send
///    itself. It reports "Sent from your phone" only after WhatsApp clears
///    the input box, and fails clearly when the phone is locked or WhatsApp
///    doesn't respond.
///
/// Never used: WhatsApp Web scraping, reverse-engineered protocols, session
/// token extraction, or anti-ban evasion.
class PersonalWhatsAppAdapter extends WhatsAppAdapter {
  PersonalWhatsAppAdapter({
    UrlProbe? probe,
    UrlOpener? opener,
    AutoSendStatusProbe? autoSendStatus,
    AutoSender? autoSender,
  })  : _probe = probe ?? launcher.canLaunchUrl,
        _open = opener ?? _launchExternal,
        _autoStatus = autoSendStatus ?? const WhatsAppAutoSend().status,
        _autoSend = autoSender ??
            ((String phone, String text) => const WhatsAppAutoSend().send(phoneDigits: phone, text: text));

  final UrlProbe _probe;
  final UrlOpener _open;
  final AutoSendStatusProbe _autoStatus;
  final AutoSender _autoSend;

  /// Whether the auto-send Accessibility Service is on and WhatsApp installed.
  Future<AutoSendServiceStatus> autoSendStatus() async {
    try {
      return await _autoStatus();
    } catch (error) {
      _log.warn('Could not read auto-send status', error);
      return const AutoSendServiceStatus(enabled: false, running: false);
    }
  }

  @override
  Future<bool> canSendNow() async => (await autoSendStatus()).ready;
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
        'Automatic sending needs auto-send turned on (Accessibility) and the phone unlocked',
        'Without auto-send you tap Send inside WhatsApp and AUTOMETA cannot confirm delivery',
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

    final AutoSendServiceStatus auto = await autoSendStatus();
    if (auto.ready) {
      return IntegrationAvailability(
        status: ConnectionStatus.connected,
        accountType: 'personal',
        label: 'Personal account · auto-send on',
        capabilities: <String>[...capabilities.working, 'Auto-send from this phone'],
        limitations: const <String>[
          'Sends only while the phone is unlocked (or has no screen lock)',
          'WhatsApp does not officially support automation; use at your own discretion',
        ],
        metadata: const <String, String>{'handoff': 'auto_send'},
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
      if (!(await autoSendStatus()).ready) {
        return const WhatsAppSendOutcome(
          state: WhatsAppDeliveryState.notSupported,
          reason: 'Auto-send is off. Turn it on in Connections → WhatsApp, '
              'or switch the block to "Prepare message".',
        );
      }
      final AutoSendResult r = await _autoSend(digits, body);
      switch (r.status) {
        case AutoSendStatus.sent:
          _log.info('WhatsApp message sent from phone (auto-send confirmed)');
          return const WhatsAppSendOutcome(state: WhatsAppDeliveryState.sentFromPhone);
        case AutoSendStatus.unconfirmed:
          return WhatsAppSendOutcome(
            state: WhatsAppDeliveryState.failed,
            reason: r.reason ?? 'Send was tapped but WhatsApp did not confirm. Check the chat before retrying.',
            retriable: false,
          );
        case AutoSendStatus.locked:
        case AutoSendStatus.disabled:
        case AutoSendStatus.busy:
        case AutoSendStatus.failed:
          return WhatsAppSendOutcome(
            state: WhatsAppDeliveryState.failed,
            reason: r.reason ?? 'Auto-send failed',
          );
      }
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
