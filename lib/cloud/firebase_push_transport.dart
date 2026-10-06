import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../core/utils/logger.dart';
import 'push_client.dart';

/// Background/terminated FCM handler. Cloud alerts are sent as
/// "notification" messages, which Android displays by itself while the app
/// is not in the foreground, so there is nothing to do here except exist:
/// the tap is delivered later via onMessageOpenedApp / getInitialMessage.
/// It must be a top-level function and must not touch UI state.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

PushMessage _convert(RemoteMessage m) =>
    PushMessage(title: m.notification?.title, body: m.notification?.body, data: m.data);

/// [PushTransport] backed by Firebase Cloud Messaging.
///
/// Firebase is configured at build time by android/app/google-services.json
/// (never committed; see docs/NOTIFICATIONS.md). Without it,
/// `Firebase.initializeApp()` fails and [initialize] returns false, so the app
/// reports "Not configured in this build" instead of pretending.
class FirebasePushTransport implements PushTransport {
  final Logger _log = Logger.withTag('PUSH');

  FirebaseMessaging get _m => FirebaseMessaging.instance;

  @override
  Future<bool> initialize() async {
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      return true;
    } catch (e) {
      _log.info('Firebase not configured in this build: push disabled (${e.runtimeType})');
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    final NotificationSettings s = await _m.requestPermission();
    return s.authorizationStatus == AuthorizationStatus.authorized ||
        s.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> getToken() => _m.getToken();

  @override
  Stream<String> get onTokenRefresh => _m.onTokenRefresh;

  @override
  Stream<PushMessage> get onForegroundMessage => FirebaseMessaging.onMessage.map(_convert);

  @override
  Stream<PushMessage> get onOpenedFromBackground => FirebaseMessaging.onMessageOpenedApp.map(_convert);

  @override
  Future<PushMessage?> initialMessage() async {
    final RemoteMessage? m = await _m.getInitialMessage();
    return m == null ? null : _convert(m);
  }
}
