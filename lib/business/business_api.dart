import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

typedef Json = Map<String, dynamic>;

Json asMap(Object? o) => o is Map ? o.map((Object? k, Object? v) => MapEntry<String, dynamic>('$k', v)) : <String, dynamic>{};
List<Json> asList(Object? o) => o is List ? o.map(asMap).toList() : <Json>[];
List<String> asStrings(Object? o) => o is List ? o.map((Object? e) => '$e').toList() : <String>[];
String str(Object? o) => o == null ? '' : '$o';
int intOf(Object? o) => o is num ? o.toInt() : int.tryParse('$o') ?? 0;
bool boolOf(Object? o) => o == true;

/// Error from the AUTOMETA Business server, with a human message.
class BusinessApiException implements Exception {
  BusinessApiException(this.status, this.message, {this.requiredPlan, this.errors = const <String>[]});

  final int status;
  final String message;
  final String? requiredPlan;
  final List<String> errors;

  bool get isUpgrade => status == 402;

  @override
  String toString() => message;
}

/// Thin JSON client for the server in /server. All requests are HTTPS in
/// production; the token is a revocable member session, never a Meta token.
class BusinessApi {
  BusinessApi({required this.baseUrl, this.token, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  String? token;
  final http.Client _client;

  Future<Object?> call(String method, String path, [Object? body]) async {
    final http.Request req = http.Request(method, Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path'));
    req.headers['content-type'] = 'application/json';
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    late http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 25)));
    } on TimeoutException {
      throw BusinessApiException(0, 'The server took too long to answer. Check your connection.');
    } catch (_) {
      throw BusinessApiException(0, 'Can\'t reach the server. Check the address and your internet connection.');
    }
    Object? decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    if (res.statusCode != 200) {
      final Json m = asMap(decoded);
      throw BusinessApiException(
        res.statusCode,
        str(m['error']).isEmpty ? 'Request failed (${res.statusCode})' : str(m['error']),
        requiredPlan: m['requiredPlan'] == null ? null : str(m['requiredPlan']),
        errors: asStrings(m['errors']),
      );
    }
    return decoded;
  }

  Future<Json> get(String path) async => asMap(await call('GET', path));
  Future<List<Json>> list(String path) async => asList(await call('GET', path));
  Future<Json> post(String path, [Object? body]) async => asMap(await call('POST', path, body ?? <String, dynamic>{}));
  Future<Json> put(String path, Object body) async => asMap(await call('PUT', path, body));
  Future<Json> patch(String path, Object body) async => asMap(await call('PATCH', path, body));
  Future<void> delete(String path) async => call('DELETE', path);
}
