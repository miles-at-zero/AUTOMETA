import 'dart:async';

import 'package:autometa/cloud/push_client.dart';
import 'package:autometa/cloud/push_routing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the `data` block of server/src/cloud/push.js buildPushMessage.
Map<String, dynamic> serverData({String actionType = '', String executionId = '', String connectionId = '', String id = 'n_1'}) =>
    <String, dynamic>{
      'notificationId': id, 'kind': 'automation_failed', 'severity': 'error',
      'actionType': actionType, 'executionId': executionId, 'connectionId': connectionId, 'automationId': 'a_1',
    };

class FakeTransport implements PushTransport {
  FakeTransport({this.configured = true, this.permission = true, this.token = 'fcm-token-0123456789abcdef', this.launch});
  bool configured;
  bool permission;
  String? token;
  PushMessage? launch;
  final StreamController<String> refresh = StreamController<String>.broadcast();
  final StreamController<PushMessage> fg = StreamController<PushMessage>.broadcast();
  final StreamController<PushMessage> opened = StreamController<PushMessage>.broadcast();

  @override
  Future<bool> initialize() async => configured;
  @override
  Future<bool> requestPermission() async => permission;
  @override
  Future<String?> getToken() async => token;
  @override
  Stream<String> get onTokenRefresh => refresh.stream;
  @override
  Stream<PushMessage> get onForegroundMessage => fg.stream;
  @override
  Stream<PushMessage> get onOpenedFromBackground => opened.stream;
  @override
  Future<PushMessage?> initialMessage() async => launch;
}

void main() {
  group('payload parsing', () {
    test('execution / reconnect / generic / empty', () {
      expect(PushDestination.fromData(serverData(actionType: 'execution', executionId: 'x_9')), const OpenExecution('x_9'));
      expect(PushDestination.fromData(serverData(actionType: 'reconnect', connectionId: 'c_2')), const OpenReconnect('c_2'));
      expect(PushDestination.fromData(serverData(actionType: 'reconnect')), const OpenReconnect(null));
      expect(PushDestination.fromData(serverData()), const OpenNotifications('n_1'));
      expect(PushDestination.fromData(serverData(actionType: 'execution')), const OpenNotifications('n_1'),
          reason: 'execution without id falls back to the notifications list');
      expect(PushDestination.fromData(const <String, dynamic>{}), isNull);
    });

    test('local payloads round-trip; non-Cloud payloads are ignored', () {
      for (final PushDestination d in const <PushDestination>[OpenExecution('x_1'), OpenReconnect('c_1'), OpenReconnect(null), OpenNotifications('n_1')]) {
        expect(PushDestination.fromLocalPayload(d.toLocalPayload()), d);
      }
      expect(PushDestination.fromLocalPayload('wf-morning'), isNull);
      expect(PushDestination.fromLocalPayload(null), isNull);
      expect(PushDestination.fromLocalPayload('cloudexec:'), isNull);
    });

    test('stable notification ids are deterministic and positive', () {
      expect(stableNotificationId('n_1'), stableNotificationId('n_1'));
      expect(stableNotificationId('n_1'), isNot(stableNotificationId('n_2')));
      expect(stableNotificationId('n_1'), greaterThanOrEqualTo(0));
    });
  });

  group('terminated-app navigation', () {
    test('a tap before the router exists is stored, then consumed exactly once on attach', () {
      final PendingNavigation nav = PendingNavigation();
      nav.open(const OpenExecution('x_1'));
      expect(nav.pending, const OpenExecution('x_1'));
      final List<PushDestination> opened = <PushDestination>[];
      nav.attach(opened.add);
      expect(opened, <PushDestination>[const OpenExecution('x_1')]);
      expect(nav.pending, isNull);
      nav.attach(opened.add); // e.g. shell rebuilt
      expect(opened.length, 1, reason: 'not replayed');
      nav.open(const OpenReconnect('c_1')); // warm tap goes straight through
      expect(opened.last, const OpenReconnect('c_1'));
      nav.detach();
      nav.open(const OpenNotifications('n'));
      expect(nav.pending, const OpenNotifications('n'));
    });

    test('FCM launch message (getInitialMessage) becomes the pending destination', () async {
      final PendingNavigation nav = PendingNavigation();
      final PushClient c = PushClient(
        transport: FakeTransport(launch: PushMessage(title: 't', data: serverData(actionType: 'execution', executionId: 'x_42'))),
        navigation: nav, postLocal: _noPost, readSetting: (_) async => null, writeSetting: (_, __) async {},
      );
      await c.start();
      expect(nav.pending, const OpenExecution('x_42'));
    });

    test('background tap routes through to the attached handler', () async {
      final FakeTransport t = FakeTransport();
      final PendingNavigation nav = PendingNavigation();
      final List<PushDestination> opened = <PushDestination>[];
      nav.attach(opened.add);
      final PushClient c = PushClient(transport: t, navigation: nav, postLocal: _noPost, readSetting: (_) async => null, writeSetting: (_, __) async {});
      await c.start();
      t.opened.add(PushMessage(data: serverData(actionType: 'reconnect', connectionId: 'c_7')));
      await pumpEventQueue();
      expect(opened, <PushDestination>[const OpenReconnect('c_7')]);
    });
  });

  group('push client states (no fake success)', () {
    PushClient make(FakeTransport t, {List<String>? posted, Map<String, String>? store}) => PushClient(
          transport: t,
          navigation: PendingNavigation(),
          postLocal: ({required String title, required String body, required String payload, required int id}) async =>
              posted?.add('$title|$body|$payload|$id'),
          readSetting: (String k) async => store?[k],
          writeSetting: (String k, String v) async => store?[k] = v,
        );

    test('no Firebase config in the build → notConfigured, never registers', () async {
      final PushClient c = make(FakeTransport(configured: false));
      await c.start();
      bool called = false;
      await c.register((_, __) async => called = true);
      expect(c.status, PushStatus.notConfigured);
      expect(called, isFalse);
      expect(c.active, isFalse);
    });

    test('permission denied', () async {
      final PushClient c = make(FakeTransport(permission: false));
      await c.start();
      await c.register((_, __) async => true);
      expect(c.status, PushStatus.permissionDenied);
    });

    test('registered, but server has no FCM credentials → serverNotConfigured (poll stays on)', () async {
      final PushClient c = make(FakeTransport());
      await c.start();
      await c.register((_, __) async => false);
      expect(c.status, PushStatus.serverNotConfigured);
      expect(c.active, isFalse);
    });

    test('registers the token with prefs; refresh re-registers; prefs persist; unregister deletes', () async {
      final FakeTransport t = FakeTransport();
      final Map<String, String> store = <String, String>{};
      final PushClient c = make(t, store: store);
      await c.start();
      final List<String> sent = <String>[];
      await c.register((String token, PushPrefs p) async {
        sent.add('$token:${p.messages}');
        return true;
      });
      expect(c.status, PushStatus.registered);
      expect(c.active, isTrue);
      t.refresh.add('fcm-token-rotated-000000000');
      await pumpEventQueue();
      await c.setPrefs(c.prefs.copyWith(messages: false));
      expect(sent, <String>['fcm-token-0123456789abcdef:true', 'fcm-token-rotated-000000000:true', 'fcm-token-rotated-000000000:false']);
      expect(PushPrefs.fromJson(store[PushClient.prefsKey]).messages, isFalse);
      String? removed;
      await c.unregister((String tok) async => removed = tok);
      expect(removed, 'fcm-token-rotated-000000000');
      expect(c.status, PushStatus.idle);
    });

    test('server error while registering → error, not registered', () async {
      final PushClient c = make(FakeTransport());
      await c.start();
      await c.register((_, __) async => throw Exception('500'));
      expect(c.status, PushStatus.error);
    });

    test('foreground message is re-posted locally with a deep link and stable id', () async {
      final FakeTransport t = FakeTransport();
      final List<String> posted = <String>[];
      final PushClient c = make(t, posted: posted);
      await c.start();
      t.fg.add(PushMessage(title: 'Morning failed', body: 'Telegram rejected', data: serverData(actionType: 'execution', executionId: 'x_5', id: 'n_5')));
      await pumpEventQueue();
      expect(posted.single, '☁️ Morning failed|Telegram rejected|cloudexec:x_5|${stableNotificationId('n_5')}');
    });
  });
}

Future<void> _noPost({required String title, required String body, required String payload, required int id}) async {}
