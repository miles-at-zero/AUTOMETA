import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_services.dart';
import '../business/business_api.dart';
import '../services/notifications/notification_service.dart';
import '../domain/capabilities/execution_capabilities.dart';
import '../domain/models/trigger.dart';
import '../domain/models/workflow.dart';
import 'cloud_mapper.dart';
import 'push_client.dart';
import 'push_routing.dart';

/// Thrown when a Cloud operation can't complete; carries the blocking items.
class CloudException implements Exception {
  CloudException(this.message, {this.issues = const <CapabilityIssue>[], this.needsAccount = false, this.offline = false});

  final String message;
  final List<CapabilityIssue> issues;
  final bool needsAccount;
  final bool offline;

  @override
  String toString() => message;
}

/// Signed-in Autometa Cloud account (server/src/cloud, `/v1/*`).
///
/// The phone is only a control/monitoring client for Cloud automations: it
/// creates, edits, activates, pauses and tests them, and reads history. The
/// backend scheduler and workers run them; nothing here schedules anything.
class CloudSession extends ChangeNotifier {
  CloudSession(this._services);

  final AppServices _services;
  static const String _tokenKey = 'cloud.session_token';
  static const String _urlKey = 'cloud.server_url';

  /// Build-time default server, e.g.
  /// `flutter build apk --dart-define=AUTOMETA_CLOUD_URL=https://api.example.com`.
  /// Empty in plain builds: the user types their server address.
  static const String defaultServerUrl = String.fromEnvironment('AUTOMETA_CLOUD_URL');

  BusinessApi? api;
  Json? me;

  /// Device push (FCM). Null in tests / when not wired.
  PushClient? push;
  String serverUrl = '';
  bool ready = false;
  String? error;

  bool get signedIn => api?.token != null && me != null;
  String get email => str(asMap(me?['user'])['email']);
  String get planName => str(asMap(me?['workspace'])['planName']);
  int get unread => intOf(me?['unreadNotifications']);

  Future<void> init() async {
    serverUrl = await _services.settings.repository.get(_urlKey) ??
        await _services.settings.repository.get('business.server_url') ??
        '';
    final String? token = await _services.secrets.read(_tokenKey);
    if (serverUrl.isNotEmpty && token != null) {
      api = BusinessApi(baseUrl: serverUrl, token: token);
      try {
        await refresh();
      } on BusinessApiException catch (e) {
        if (e.status == 401) await signOut();
        error = e.message; // Offline: keep the token, show cached state.
      }
    }
    ready = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    final BusinessApi? a = api;
    if (a == null) return;
    me = await a.get('/v1/me');
    error = null;
    notifyListeners();
    unawaited(registerPush());
  }

  /// Registers this phone's push token with `POST /v1/devices`.
  Future<void> registerPush() async {
    final PushClient? p = push;
    final BusinessApi? a = api;
    if (p == null || a == null) return;
    // Once per session; token refreshes re-register by themselves.
    if (p.status != PushStatus.idle && p.status != PushStatus.error) return;
    await p.register((String token, PushPrefs prefs) async {
      final Json r = await a.post('/v1/devices', <String, dynamic>{'token': token, 'platform': 'android', 'prefs': prefs.toJson()});
      return r['pushConfigured'] == true;
    });
  }

  static String cleanUrl(String url) {
    String u = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isNotEmpty && !u.startsWith('http')) u = 'https://$u';
    return u;
  }

  Future<void> _start(String url, Json res) async {
    await _services.secrets.write(_tokenKey, str(res['token']));
    await _services.settings.repository.set(_urlKey, url);
    serverUrl = url;
    api = BusinessApi(baseUrl: url, token: str(res['token']));
    await refresh();
  }

  Future<void> signUp(String url, String email, String password, String name) async {
    final String u = cleanUrl(url);
    await _start(u, await BusinessApi(baseUrl: u).post('/v1/auth/signup', <String, dynamic>{
      'email': email.trim(), 'password': password, 'name': name.trim(), 'timezone': _services.settings.timeZone ?? 'UTC',
    }));
  }

  Future<void> signIn(String url, String email, String password) async {
    final String u = cleanUrl(url);
    await _start(u, await BusinessApi(baseUrl: u).post('/v1/auth/login', <String, dynamic>{'email': email.trim(), 'password': password}));
  }

  Future<String> forgotPassword(String url, String email) async {
    final Json r = await BusinessApi(baseUrl: cleanUrl(url)).post('/v1/auth/forgot', <String, dynamic>{'email': email.trim()});
    return str(r['message']);
  }

  Future<void> signOut() async {
    final BusinessApi? a = api;
    if (a != null) await push?.unregister((String token) => a.call('DELETE', '/v1/devices', <String, dynamic>{'token': token}));
    try {
      await api?.post('/v1/auth/logout');
    } catch (_) {/* best effort */}
    await _services.secrets.delete(_tokenKey);
    api = null;
    me = null;
    notifyListeners();
  }

  BusinessApi _need() {
    final BusinessApi? a = api;
    if (a == null || me == null) {
      throw CloudException('Sign in to Autometa Cloud to use Cloud execution.', needsAccount: true);
    }
    return a;
  }

  Future<T> _wrap<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on BusinessApiException catch (e) {
      if (e.status == 0) throw CloudException('Can\'t reach Autometa Cloud. Check your connection and try again.', offline: true);
      if (e.status == 401) {
        await signOut();
        throw CloudException('Your Cloud session expired. Sign in again.', needsAccount: true);
      }
      final List<CapabilityIssue> issues = asList(asMap(e.body['validation'])['checks'])
          .where((Json c) => c['ok'] != true)
          .map((Json c) => CapabilityIssue(stepId: c['stepId'] == null ? null : str(c['stepId']), label: str(c['label']), reason: str(c['fix'])))
          .toList();
      throw CloudException(e.message, issues: issues);
    }
  }

  // ---------------------------------------------------------------- alerts
  static const String _alertsSeenKey = 'cloud.alerts_seen_at';

  /// Server notification kinds worth interrupting the user for. Ordinary
  /// successes are never surfaced as phone notifications.
  static const Set<String> alertKinds = <String>{
    'automation_failed', 'automation_paused', 'connection_reauth', 'usage_limit', 'usage_warning', 'automation_message',
  };

  /// In-app fallback for device push: on app start/resume, shows important
  /// Cloud notifications that arrived since the last check as Android
  /// notifications with a deep link (`cloudexec:<id>` / `cloudreconnect:<id>`).
  /// Device push (FCM) needs Firebase config in the app build and on the
  /// server: EXTERNAL CONFIG REQUIRED (docs/NOTIFICATIONS.md). While push is
  /// active this poll only advances its marker (no duplicates); otherwise it is
  /// the fallback that shows the alerts.
  Future<int> checkAlerts() async {
    if (!signedIn) return 0;
    final bool pushActive = push?.active ?? false;
    try {
      final List<Json> list = await _need().list('/v1/notifications');
      final int now = DateTime.now().millisecondsSinceEpoch;
      final int seen = int.tryParse(await _services.settings.repository.get(_alertsSeenKey) ?? '') ?? (now - const Duration(hours: 24).inMilliseconds);
      int shown = 0;
      int newest = seen;
      for (final Json n in list.reversed) {
        final int at = intOf(n['createdAt']);
        if (at <= seen || n['read'] == true || !alertKinds.contains(str(n['kind']))) continue;
        if (at > newest) newest = at;
        if (pushActive) continue;
        final Json action = asMap(n['action']);
        final PushDestination d = PushDestination.fromData(<String, dynamic>{
              'actionType': action['type'], 'executionId': action['executionId'], 'connectionId': action['connectionId'],
            }) ??
            OpenNotifications(str(n['id']));
        await _services.notifications.show(
          title: '☁️ ${str(n['title'])}',
          body: str(n['body']),
          channel: NotificationChannels.cloudAlerts,
          payload: d.toLocalPayload(),
          id: stableNotificationId(str(n['id'])),
        );
        shown++;
      }
      await _services.settings.repository.set(_alertsSeenKey, '${newest > seen ? newest : now}');
      return shown;
    } catch (_) {
      return 0; // Offline or signed out: try again on the next resume.
    }
  }

  // ---------------------------------------------------------------- connections
  Future<List<Json>> integrations() => _wrap(() => _need().list('/v1/integrations'));
  Future<List<Json>> connections() => _wrap(() => _need().list('/v1/connections'));
  Future<Json> connect(String integration, Map<String, String> fields) =>
      _wrap(() => _need().post('/v1/connections', <String, dynamic>{'integration': integration, 'fields': fields}));
  Future<Json> reconnect(String id, Map<String, String> fields) =>
      _wrap(() => _need().post('/v1/connections/$id/reconnect', <String, dynamic>{'fields': fields}));
  /// Starts Google OAuth on the server and returns the consent URL to open.
  Future<String> startOAuth(String integration, {String? connectionId}) => _wrap(() async =>
      str((await _need().post('/v1/oauth/$integration/start', <String, dynamic>{if (connectionId != null) 'connectionId': connectionId}))['url']));
  Future<List<Json>> notifications() => _wrap(() => _need().list('/v1/notifications'));
  Future<void> disconnect(String id) => _wrap(() => _need().delete('/v1/connections/$id'));

  // ---------------------------------------------------------------- automations
  Future<CloudMapping> mapping(Workflow w) async {
    final List<Json> conns = await connections();
    final Json? wa = conns.cast<Json?>().firstWhere(
        (Json? c) => c?['integration'] == 'whatsapp' && c?['status'] == 'connected', orElse: () => null);
    final Map<String, String> phones = <String, String>{};
    for (final r in await _services.contacts.all()) {
      phones[r.alias.toLowerCase()] = r.dialableNumber;
    }
    final Json? gmail = conns.cast<Json?>().firstWhere(
        (Json? c) => c?['integration'] == 'gmail' && c?['status'] == 'connected', orElse: () => null);
    String? hook;
    if (w.trigger is WebhookTrigger) hook = await _webhookFor(w);
    return CloudMapper(
      phoneFor: (String alias) => phones[alias.toLowerCase()],
      whatsappConnectionId: wa == null ? null : str(wa['id']),
      webhookId: hook,
      gmailConnectionId: gmail == null ? null : str(gmail['id']),
    ).map(w);
  }

  Future<String?> _webhookFor(Workflow w) async {
    if (w.cloudId != null) {
      final Json a = await _need().get('/v1/automations/${w.cloudId}');
      final String id = str(asMap(asMap(a['trigger'])['config'])['webhookId']);
      if (id.isNotEmpty) return id;
    }
    final Json created = await _need().post('/v1/webhooks', <String, dynamic>{'name': w.name});
    lastCreatedWebhook = created;
    return str(created['id']);
  }

  /// Set when a sync created a webhook, so the UI can show URL + secret once.
  Json? lastCreatedWebhook;

  /// Creates or updates the Cloud copy and sets active/paused to match
  /// [Workflow.enabled]. Returns the Cloud id. Throws [CloudException].
  Future<String> sync(Workflow w) => _wrap(() async {
        final BusinessApi a = _need();
        final CloudMapping m = await mapping(w);
        if (!m.ok) throw CloudException('This automation needs attention before it can run in Cloud.', issues: m.issues);
        String? id = w.cloudId;
        if (id != null) {
          try {
            await a.put('/v1/automations/$id', m.body);
          } on BusinessApiException catch (e) {
            if (e.status != 404) rethrow;
            id = null; // Deleted on the server: recreate.
          }
        }
        id ??= str((await a.post('/v1/automations', m.body))['id']);
        if (w.enabled) {
          await a.post('/v1/automations/$id/activate');
        } else {
          await a.post('/v1/automations/$id/pause');
        }
        return id;
      });

  Future<void> pause(String cloudId) => _wrap(() => _need().post('/v1/automations/$cloudId/pause'));
  Future<void> remove(String cloudId) => _wrap(() => _need().delete('/v1/automations/$cloudId'));
  Future<Json> detail(String cloudId) => _wrap(() => _need().get('/v1/automations/$cloudId'));
  Future<Json> run(String cloudId) => _wrap(() => _need().post('/v1/automations/$cloudId/run'));
  Future<Json> test(String cloudId, {bool live = false}) =>
      _wrap(() => _need().post('/v1/automations/$cloudId/test', <String, dynamic>{'live': live, 'confirm': live}));
  Future<List<Json>> executions({String? cloudId}) =>
      _wrap(() => _need().list(cloudId == null ? '/v1/executions' : '/v1/executions?automation=$cloudId'));
  Future<Json> execution(String id) => _wrap(() => _need().get('/v1/executions/$id'));
  Future<Json> retryExecution(String id) => _wrap(() => _need().post('/v1/executions/$id/retry'));
}
