import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'push_routing.dart';

/// A received push, reduced to what the app needs.
class PushMessage {
  const PushMessage({this.title, this.body, this.data = const <String, dynamic>{}});
  final String? title;
  final String? body;
  final Map<String, dynamic> data;
}

/// Platform side of push (Firebase Cloud Messaging in the app, a fake in
/// tests). See `firebase_push_transport.dart`.
abstract class PushTransport {
  /// False when this build has no Firebase configuration
  /// (android/app/google-services.json was not present at build time).
  Future<bool> initialize();
  Future<bool> requestPermission();
  Future<String?> getToken();
  Stream<String> get onTokenRefresh;

  /// Messages received while the app is in the foreground. FCM does not show
  /// these itself, so the client re-posts them as local notifications.
  Stream<PushMessage> get onForegroundMessage;

  /// A notification tapped while the app was in the background.
  Stream<PushMessage> get onOpenedFromBackground;

  /// The notification tap that launched a terminated app, if any.
  Future<PushMessage?> initialMessage();
}

/// What is true about push on this phone right now. Kept deliberately
/// separate from "real-device verified", which no code can claim.
enum PushStatus {
  /// Not started yet / not signed in to Cloud.
  idle('Not active', 'Sign in to Autometa Cloud to receive alerts.'),

  /// No Firebase configuration in this build: EXTERNAL CONFIG REQUIRED.
  notConfigured('Not configured in this build',
      'This build has no Firebase configuration, so the server cannot push to it. '
          'Important alerts are still shown when you open the app.'),

  permissionDenied('Notifications blocked',
      'Allow notifications for Autometa in Android settings to receive alerts.'),

  /// Registered with the server, but the server has no FCM credentials.
  serverNotConfigured('Server push not configured',
      'This phone is registered, but the Autometa server has no push credentials yet. '
          'Alerts appear when you open the app.'),

  registered('Push alerts on', 'Failures and reconnect requests arrive as phone notifications.'),

  error('Push unavailable', 'Couldn\'t register for push. Alerts appear when you open the app.');

  const PushStatus(this.label, this.explanation);
  final String label;
  final String explanation;
}

/// Which alert kinds this device wants (server `devices.prefs`).
@immutable
class PushPrefs {
  const PushPrefs({this.failures = true, this.account = true, this.messages = true});
  final bool failures;
  final bool account;
  final bool messages;

  PushPrefs copyWith({bool? failures, bool? account, bool? messages}) =>
      PushPrefs(failures: failures ?? this.failures, account: account ?? this.account, messages: messages ?? this.messages);

  Map<String, bool> toJson() => <String, bool>{'failures': failures, 'account': account, 'messages': messages};

  static PushPrefs fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const PushPrefs();
    try {
      final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
      return PushPrefs(failures: m['failures'] != false, account: m['account'] != false, messages: m['messages'] != false);
    } catch (_) {
      return const PushPrefs();
    }
  }
}

/// Server device API (`POST/DELETE /v1/devices`). Returns whether the server
/// itself is able to send pushes (`pushConfigured`).
typedef DeviceRegistrar = Future<bool> Function(String token, PushPrefs prefs);
typedef DeviceUnregistrar = Future<void> Function(String token);
typedef LocalAlertPoster = Future<void> Function({required String title, required String body, required String payload, required int id});

/// Registers this phone for Cloud alert pushes and routes taps.
///
/// Foreground: re-post as a local notification (same id as the poll, so no
/// duplicates). Background: the system shows the notification; a tap arrives
/// via [PushTransport.onOpenedFromBackground]. Terminated: the launching tap
/// is read with [PushTransport.initialMessage] and stored in [navigation]
/// until the UI attaches.
class PushClient extends ChangeNotifier {
  PushClient({
    required this.transport,
    required this.navigation,
    required this.postLocal,
    required Future<String?> Function(String key) readSetting,
    required Future<void> Function(String key, String value) writeSetting,
  })  : _read = readSetting,
        _write = writeSetting;

  final PushTransport transport;
  final PendingNavigation navigation;
  final LocalAlertPoster postLocal;
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  static const String prefsKey = 'push.prefs';

  PushStatus status = PushStatus.idle;
  PushPrefs prefs = const PushPrefs();
  String? _token;
  bool _available = false;
  bool _listening = false;
  DeviceRegistrar? _register;
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  /// True when the server can actually push to this phone. The in-app alerts
  /// poll stays on as the fallback whenever this is false.
  bool get active => status == PushStatus.registered;

  /// Call once at startup, before `runApp`, so a cold-start tap is captured.
  Future<void> start() async {
    prefs = PushPrefs.fromJson(await _read(prefsKey));
    try {
      _available = await transport.initialize();
    } catch (_) {
      _available = false;
    }
    if (!_available) {
      _set(PushStatus.notConfigured);
      return;
    }
    if (!_listening) {
      _listening = true;
      _subs
        ..add(transport.onForegroundMessage.listen(_onForeground))
        ..add(transport.onOpenedFromBackground.listen((PushMessage m) => navigation.open(PushDestination.fromData(m.data))))
        ..add(transport.onTokenRefresh.listen((String t) {
          _token = t;
          unawaited(_sendRegistration());
        }));
    }
    try {
      navigation.open(PushDestination.fromData((await transport.initialMessage())?.data ?? const <String, dynamic>{}));
    } catch (_) {/* no launch message */}
  }

  /// Signed in: register this phone's token with the server.
  Future<void> register(DeviceRegistrar registrar) async {
    _register = registrar;
    if (!_available) {
      _set(PushStatus.notConfigured);
      return;
    }
    try {
      if (!await transport.requestPermission()) {
        _set(PushStatus.permissionDenied);
        return;
      }
      _token = await transport.getToken();
      await _sendRegistration();
    } catch (_) {
      _set(PushStatus.error);
    }
  }

  Future<void> _sendRegistration() async {
    final String? t = _token;
    final DeviceRegistrar? r = _register;
    if (t == null || t.isEmpty || r == null) {
      if (r != null) _set(PushStatus.error);
      return;
    }
    try {
      _set(await r(t, prefs) ? PushStatus.registered : PushStatus.serverNotConfigured);
    } catch (_) {
      _set(PushStatus.error);
    }
  }

  /// Signing out: the server must stop pushing to this phone.
  Future<void> unregister(DeviceUnregistrar unregistrar) async {
    final String? t = _token;
    _register = null;
    if (t != null) {
      try {
        await unregistrar(t);
      } catch (_) {/* best effort; the server prunes dead tokens */}
    }
    _set(_available ? PushStatus.idle : PushStatus.notConfigured);
  }

  Future<void> setPrefs(PushPrefs p) async {
    prefs = p;
    await _write(prefsKey, jsonEncode(p.toJson()));
    notifyListeners();
    if (_register != null) await _sendRegistration();
  }

  Future<void> _onForeground(PushMessage m) async {
    final PushDestination? d = PushDestination.fromData(m.data);
    final String nid = (m.data['notificationId'] ?? '').toString();
    await postLocal(
      title: '☁️ ${m.title ?? 'Autometa Cloud'}',
      body: m.body ?? '',
      payload: d?.toLocalPayload() ?? 'cloud:$nid',
      id: stableNotificationId(nid.isEmpty ? '${m.title}${m.body}' : nid),
    );
  }

  void _set(PushStatus s) {
    status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final StreamSubscription<Object?> s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
