import 'notification_center.dart';

/// Persistence for the user's Notification Center state.
///
/// Only state the user owns is stored: which notifications they have read and
/// which they dismissed. The notifications themselves are never persisted --
/// they are re-derived from a live Guardian pass on every load, so the inbox
/// can never keep warning about something that is already fixed.
class NotificationStore {
  const NotificationStore._();

  static const String readKey = 'notifications.read';
  static const String dismissedKey = 'notifications.dismissed';

  /// Record separator between stored keys / records, and field separator
  /// between a dismissed key and its signature. Both are control characters
  /// the on-screen keyboard cannot produce.
  static const String _rec = '\x1E';
  static const String _field = '\x1F';

  /// Strips the separators so a workflow name or an error message can never
  /// corrupt the encoding.
  ///
  /// Deliberately does NOT strip NUL: [NotificationEntry.signature] joins the
  /// title and body with NUL, and a dismissed row is recognised by comparing
  /// that signature. Sanitising it here would store a signature that can never
  /// match the live one, and dismissal would silently stop working.
  ///
  /// A signature containing a real separator therefore degrades safely: it
  /// won't match after a round-trip, so the row simply comes back rather than
  /// staying hidden.
  static String _safe(String value) =>
      value.replaceAll(_rec, ' ').replaceAll(_field, ' ').replaceAll('\n', ' ').trim();

  static String encodeRead(NotificationCenter center) =>
      center.readKeys.map(_safe).join(_rec);

  static Set<String> decodeRead(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>{};
    return raw.split(_rec).map(_safe).where((String s) => s.isNotEmpty).toSet();
  }

  static String encodeDismissed(NotificationCenter center) => center.dismissed.entries
      .map((MapEntry<String, String> e) => '${_safe(e.key)}$_field${_safe(e.value)}')
      .join(_rec);

  static Map<String, String> decodeDismissed(String? raw) {
    if (raw == null || raw.isEmpty) return const <String, String>{};
    final Map<String, String> out = <String, String>{};
    for (final String record in raw.split(_rec)) {
      final List<String> parts = record.split(_field);
      if (parts.isEmpty) continue;
      final String key = _safe(parts.first);
      if (key.isEmpty) continue;
      // A signature may itself contain the field separator after sanitising,
      // so rejoin everything after the first field.
      out[key] = parts.length > 1 ? parts.sublist(1).join(_field) : '';
    }
    return out;
  }

  /// Rebuilds a center that carries the persisted user state. Entries arrive
  /// from the next Guardian pass via [NotificationCenter.merge].
  static NotificationCenter restore({String? read, String? dismissed}) => NotificationCenter(
        readKeys: decodeRead(read),
        dismissed: decodeDismissed(dismissed),
      );
}
