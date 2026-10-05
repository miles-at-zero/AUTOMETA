import 'package:flutter/foundation.dart';

import '../../../core/utils/json_utils.dart';

/// The two WhatsApp integrations are genuinely different products and
/// AUTOMETA never pretends otherwise (spec §3).
enum WhatsAppAccountType {
  /// The regular WhatsApp / WhatsApp Business *app* installed on the phone.
  /// There is no official API for it, so AUTOMETA only ever prepares a
  /// message and hands the conversation to the user.
  personal('personal', 'Personal account', 'The WhatsApp app on this phone'),

  /// The WhatsApp Business Platform (Cloud API). Official, token
  /// authenticated, capable of sending without user interaction — subject to
  /// Meta's template and 24-hour window rules.
  business('business', 'Business account', 'WhatsApp Business Platform (Cloud API)');

  const WhatsAppAccountType(this.wire, this.label, this.blurb);

  final String wire;
  final String label;
  final String blurb;

  static WhatsAppAccountType? fromWire(Object? value) {
    final String raw = '$value'.toLowerCase().trim();
    for (final WhatsAppAccountType type in WhatsAppAccountType.values) {
      if (type.wire == raw || type.name.toLowerCase() == raw) return type;
    }
    return null;
  }
}

/// What actually happened when AUTOMETA tried to deliver a message.
///
/// `handedToUser` is the honest state for a personal account: the chat was
/// opened with the text prefilled, and only the user can press Send. AUTOMETA
/// has no way to observe that press, so it must not claim delivery.
enum WhatsAppDeliveryState {
  /// Meta accepted the message and returned a message id.
  delivered('delivered', 'Delivered to WhatsApp'),

  /// Accepted by Meta but held for quality assessment.
  held('held', 'Accepted (held for review)'),

  /// The conversation is open in WhatsApp with the text prefilled.
  handedToUser('handed_to_user', 'Handed to WhatsApp'),

  /// Legacy: records written by the removed consumer auto-send feature.
  /// Kept only so old history still reads; nothing produces it any more.
  sentFromPhone('sent_from_phone', 'Sent from your phone'),

  /// Nothing was delivered.
  failed('failed', 'Failed'),

  /// This account type cannot do that.
  notSupported('not_supported', 'Not available for this account type');

  const WhatsAppDeliveryState(this.wire, this.label);

  final String wire;
  final String label;

  /// Only these states mean the message actually left AUTOMETA's control.
  bool get isConfirmedDelivery => this == delivered || this == held;
}

@immutable
class WhatsAppSendOutcome {
  const WhatsAppSendOutcome({
    required this.state,
    this.messageId,
    this.reason,
    this.handoffUri,
    this.retriable = true,
  });

  /// False when retrying could send a duplicate (e.g. Send may have gone through).
  final bool retriable;

  final WhatsAppDeliveryState state;

  /// Meta's message id, when the Cloud API returned one.
  final String? messageId;

  /// Human readable explanation, safe to show.
  final String? reason;

  /// The deep link that was opened, for personal-account handoffs.
  final Uri? handoffUri;

  bool get succeeded =>
      state == WhatsAppDeliveryState.delivered ||
      state == WhatsAppDeliveryState.held ||
      state == WhatsAppDeliveryState.sentFromPhone;
}

/// Non-secret Business API configuration. The access token is *not* here;
/// it lives in the secret store.
@immutable
class WhatsAppBusinessConfig {
  const WhatsAppBusinessConfig({
    this.phoneNumberId = '',
    this.wabaId = '',
    this.apiVersion = defaultApiVersion,
    this.defaultTemplateLanguage = 'en_US',
  });

  /// Meta ships three or four Graph API versions a year and supports each for
  /// roughly two years, so the version is a setting rather than a constant.
  /// v26.0 shipped 2026-07-29 and is current at the time of writing.
  static const String defaultApiVersion = 'v26.0';

  final String phoneNumberId;
  final String wabaId;
  final String apiVersion;
  final String defaultTemplateLanguage;

  bool get hasPhoneNumberId => phoneNumberId.trim().isNotEmpty;

  String get effectiveVersion {
    final String v = apiVersion.trim();
    return v.isEmpty ? defaultApiVersion : v;
  }

  String get messagesUrl =>
      'https://graph.facebook.com/$effectiveVersion/$phoneNumberId/messages';

  String get phoneNumberInfoUrl =>
      'https://graph.facebook.com/$effectiveVersion/$phoneNumberId';

  WhatsAppBusinessConfig copyWith({
    String? phoneNumberId,
    String? wabaId,
    String? apiVersion,
    String? defaultTemplateLanguage,
  }) =>
      WhatsAppBusinessConfig(
        phoneNumberId: phoneNumberId ?? this.phoneNumberId,
        wabaId: wabaId ?? this.wabaId,
        apiVersion: apiVersion ?? this.apiVersion,
        defaultTemplateLanguage: defaultTemplateLanguage ?? this.defaultTemplateLanguage,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'phone_number_id': phoneNumberId,
        'waba_id': wabaId,
        'api_version': apiVersion,
        'default_template_language': defaultTemplateLanguage,
      };

  factory WhatsAppBusinessConfig.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return WhatsAppBusinessConfig(
      phoneNumberId: asString(map['phone_number_id']),
      wabaId: asString(map['waba_id']),
      apiVersion: asString(map['api_version'], fallback: defaultApiVersion),
      defaultTemplateLanguage: asString(map['default_template_language'], fallback: 'en_US'),
    );
  }
}
