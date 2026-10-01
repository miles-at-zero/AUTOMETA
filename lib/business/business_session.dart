import 'package:flutter/foundation.dart';

import '../app_services.dart';
import 'business_api.dart';

/// Signed-in state for Business mode. The session token lives in secure
/// storage; the server address in settings.
class BusinessSession extends ChangeNotifier {
  BusinessSession(this._services);

  final AppServices _services;
  static const String _tokenKey = 'business.session_token';
  static const String _urlKey = 'business.server_url';
  static const String _bizKey = 'business.current_id';

  BusinessApi? api;
  Json? me;
  String? businessId;
  bool ready = false;
  String serverUrl = '';
  String? error;

  bool get signedIn => api?.token != null && me != null;
  String get planId => str(asMap(me?['plan'])['id']);
  String get planName => str(asMap(me?['plan'])['name']);
  Json get subscription => asMap(me?['subscription']);
  Json get usage => asMap(me?['usage']);
  Json get member => asMap(me?['member']);
  String get role => str(member['role']);
  List<Json> get businesses => asList(me?['businesses']);
  Json get business => businesses.firstWhere((Json b) => b['id'] == businessId, orElse: () => businesses.isEmpty ? <String, dynamic>{} : businesses.first);
  String get bid => str(business['id']);

  bool can(String feature) => asStrings(asMap(me?['plan'])['features']).contains(feature);
  bool allowed(String perm) {
    final List<String> p = asStrings(me?['permissions']);
    return p.contains('*') || p.contains(perm);
  }

  Future<void> init() async {
    serverUrl = await _services.settings.repository.get(_urlKey) ?? '';
    businessId = await _services.settings.repository.get(_bizKey);
    final String? token = await _services.secrets.read(_tokenKey);
    if (serverUrl.isNotEmpty && token != null) {
      api = BusinessApi(baseUrl: serverUrl, token: token);
      try {
        await refresh();
      } on BusinessApiException catch (e) {
        if (e.status == 401) await signOut();
        error = e.message;
      }
    }
    ready = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    final BusinessApi? a = api;
    if (a == null) return;
    me = await a.get('/me');
    if (businesses.isNotEmpty && !businesses.any((Json b) => b['id'] == businessId)) businessId = str(businesses.first['id']);
    error = null;
    notifyListeners();
  }

  Future<void> _start(String url, Json res) async {
    final String token = str(res['token']);
    await _services.secrets.write(_tokenKey, token);
    await _services.settings.repository.set(_urlKey, url);
    serverUrl = url;
    api = BusinessApi(baseUrl: url, token: token);
    await refresh();
  }

  static String cleanUrl(String url) {
    String u = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isNotEmpty && !u.startsWith('http')) u = 'https://$u';
    return u;
  }

  Future<void> redeem(String url, String code) async {
    final String u = cleanUrl(url);
    await _start(u, await BusinessApi(baseUrl: u).post('/auth/redeem', <String, dynamic>{'code': code.trim()}));
  }

  Future<void> signUp(String url, String name, String businessName) async {
    final String u = cleanUrl(url);
    await _start(u, await BusinessApi(baseUrl: u).post('/auth/signup', <String, dynamic>{'name': name.trim(), 'businessName': businessName.trim()}));
  }

  Future<void> selectBusiness(String id) async {
    businessId = id;
    await _services.settings.repository.set(_bizKey, id);
    notifyListeners();
  }

  Future<void> signOut() async {
    await _services.secrets.delete(_tokenKey);
    api = null;
    me = null;
    notifyListeners();
  }
}
