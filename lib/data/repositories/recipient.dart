import 'package:flutter/foundation.dart';

import '../../core/utils/json_utils.dart';

/// A message recipient, referenced everywhere by [alias].
///
/// The number is user-supplied and never appears in a workflow definition, an
/// export or a log line. WhatsApp's official deep links require an E.164
/// number without `+`, so [phoneE164] is normalised on the way in.
@immutable
class Recipient {
  const Recipient({
    required this.id,
    required this.alias,
    required this.displayName,
    required this.phoneE164,
    this.notes = '',
    this.createdAt,
  });

  final String id;
  final String alias;
  final String displayName;
  final String phoneE164;
  final String notes;
  final DateTime? createdAt;

  /// Digits only, no `+` — the form `wa.me` and the WhatsApp API expect.
  String get dialableNumber => phoneE164.replaceAll(RegExp(r'[^0-9]'), '');

  bool get hasNumber => dialableNumber.length >= 7;

  /// A number is a credential-adjacent detail: never render it in full in the
  /// activity log.
  String get maskedNumber {
    final String digits = dialableNumber;
    if (digits.length < 6) return '••••';
    return '${digits.substring(0, 3)} ••• ${digits.substring(digits.length - 3)}';
  }

  Recipient copyWith({String? alias, String? displayName, String? phoneE164, String? notes}) =>
      Recipient(
        id: id,
        alias: alias ?? this.alias,
        displayName: displayName ?? this.displayName,
        phoneE164: phoneE164 ?? this.phoneE164,
        notes: notes ?? this.notes,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'alias': alias,
        'display_name': displayName,
        'phone_e164': phoneE164,
        'notes': notes,
      };

  factory Recipient.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return Recipient(
      id: asString(map['id']),
      alias: asString(map['alias']),
      displayName: asString(map['display_name']),
      phoneE164: asString(map['phone_e164']),
      notes: asString(map['notes']),
    );
  }
}
