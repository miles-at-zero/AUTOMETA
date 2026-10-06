/// Where a tapped Cloud alert should take the user.
///
/// Pure Dart (no plugins) so it is unit-tested with mocked payloads. Two
/// sources produce destinations:
///  * FCM data payloads built by the server (`server/src/cloud/push.js`
///    `buildPushMessage`): `actionType`, `executionId`, `connectionId`,
///    `notificationId`, `kind`, `automationId`.
///  * Local notification payload strings (`cloudexec:<id>`,
///    `cloudreconnect:<id>`, `cloud:<notificationId>`) used by the in-app
///    alerts poll fallback and by foreground pushes re-posted locally.
sealed class PushDestination {
  const PushDestination();

  /// Parses an FCM `data` map. Unknown or empty payloads → [OpenNotifications]
  /// when there is a notification id, otherwise null (nothing to open).
  static PushDestination? fromData(Map<String, dynamic> data) {
    String s(String k) => (data[k] ?? '').toString().trim();
    final String type = s('actionType');
    if (type == 'execution' && s('executionId').isNotEmpty) return OpenExecution(s('executionId'));
    if (type == 'reconnect') return OpenReconnect(s('connectionId').isEmpty ? null : s('connectionId'));
    if (s('notificationId').isNotEmpty) return OpenNotifications(s('notificationId'));
    return null;
  }

  /// Parses a local notification payload. Non-Cloud payloads (e.g. a local
  /// workflow id) → null: they are not routed here.
  static PushDestination? fromLocalPayload(String? payload) {
    if (payload == null) return null;
    if (payload.startsWith('cloudexec:') && payload.length > 10) return OpenExecution(payload.substring(10));
    if (payload.startsWith('cloudreconnect:')) {
      final String id = payload.substring(15);
      return OpenReconnect(id.isEmpty ? null : id);
    }
    if (payload.startsWith('cloud:')) return OpenNotifications(payload.substring(6));
    return null;
  }

  /// Inverse of [fromLocalPayload].
  String toLocalPayload();
}

class OpenExecution extends PushDestination {
  const OpenExecution(this.executionId);
  final String executionId;
  @override
  String toLocalPayload() => 'cloudexec:$executionId';
  @override
  bool operator ==(Object o) => o is OpenExecution && o.executionId == executionId;
  @override
  int get hashCode => executionId.hashCode;
  @override
  String toString() => 'OpenExecution($executionId)';
}

class OpenReconnect extends PushDestination {
  const OpenReconnect(this.connectionId);
  final String? connectionId;
  @override
  String toLocalPayload() => 'cloudreconnect:${connectionId ?? ''}';
  @override
  bool operator ==(Object o) => o is OpenReconnect && o.connectionId == connectionId;
  @override
  int get hashCode => connectionId.hashCode;
  @override
  String toString() => 'OpenReconnect($connectionId)';
}

class OpenNotifications extends PushDestination {
  const OpenNotifications(this.notificationId);
  final String notificationId;
  @override
  String toLocalPayload() => 'cloud:$notificationId';
  @override
  bool operator ==(Object o) => o is OpenNotifications && o.notificationId == notificationId;
  @override
  int get hashCode => notificationId.hashCode;
  @override
  String toString() => 'OpenNotifications($notificationId)';
}

/// Holds a destination until the UI can navigate.
///
/// Cold start: the tap that launched the app is read before `runApp` (FCM
/// `getInitialMessage`, local `getNotificationAppLaunchDetails`) when no
/// navigator exists yet, so it is stored here. The app shell [attach]es its
/// handler once its first frame is built and the pending destination is
/// consumed exactly once. Warm taps go straight to the attached handler.
class PendingNavigation {
  PushDestination? _pending;
  void Function(PushDestination)? _handler;

  PushDestination? get pending => _pending;

  void open(PushDestination? d) {
    if (d == null) return;
    final void Function(PushDestination)? h = _handler;
    if (h == null) {
      _pending = d; // Latest tap wins.
    } else {
      h(d);
    }
  }

  /// Registers the navigator-ready handler and flushes any pending tap.
  void attach(void Function(PushDestination) handler) {
    _handler = handler;
    final PushDestination? d = _pending;
    _pending = null;
    if (d != null) handler(d);
  }

  void detach() => _handler = null;
}

/// Stable 31-bit id for a server notification id, so the same Cloud alert
/// posted by the poll and by a foreground push replaces itself instead of
/// appearing twice (String.hashCode is not stable across processes).
int stableNotificationId(String id) {
  int h = 0x811c9dc5;
  for (final int c in id.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0x7fffffff;
  }
  return h;
}
