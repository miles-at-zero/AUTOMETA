import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A transport-agnostic HTTP call description.
@immutable
class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.url,
    this.headers = const <String, String>{},
    this.body,
    this.timeout = const Duration(seconds: 30),
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
  final Duration timeout;

  /// Redacted copy for logs: never prints an Authorization value.
  String describe() {
    final Uri? uri = Uri.tryParse(url);
    return '$method ${uri == null ? url : '${uri.host}${uri.path}'}';
  }
}

@immutable
class ApiResponse {
  const ApiResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
    this.transportError,
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  /// Set when the request never reached the server (DNS, TLS, timeout).
  final String? transportError;

  bool get isSuccess => statusCode >= 200 && statusCode <= 299;

  /// `0` means no HTTP response was received at all.
  bool get reachedServer => transportError == null;

  Map<String, dynamic> get json {
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Best-effort human message. Meta, OpenAI and Anthropic all wrap errors in
  /// an `error` object; anything else falls back to the raw body.
  String get errorMessage {
    final Map<String, dynamic> payload = json;
    final Object? error = payload['error'];
    if (error is Map) {
      final Object? message = error['message'] ?? error['title'];
      if (message is String && message.isNotEmpty) return message;
    }
    if (error is String && error.isNotEmpty) return error;
    if (body.trim().isEmpty) return transportError ?? 'HTTP $statusCode';
    final String trimmed = body.trim();
    return trimmed.length > 240 ? '${trimmed.substring(0, 240)}…' : trimmed;
  }

  /// Meta surfaces machine-readable subcodes; the UI shows them so a user can
  /// search Meta's error reference.
  int? get errorCode {
    final Object? error = json['error'];
    if (error is Map) {
      final Object? code = error['code'] ?? error['error_subcode'];
      if (code is int) return code;
      if (code is String) return int.tryParse(code);
    }
    return null;
  }
}

/// HTTP port. Every outbound call in AUTOMETA goes through this so tests can
/// substitute a fake without touching integration code.
abstract class ApiClient {
  const ApiClient();

  Future<ApiResponse> send(ApiRequest request);
}

/// Default implementation backed by `package:http`.
class HttpApiClient extends ApiClient {
  HttpApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    final Uri uri = Uri.parse(request.url);
    final http.Request httpReq = http.Request(request.method.toUpperCase(), uri)
      ..headers.addAll(request.headers)
      ..persistentConnection = false;
    if (request.body != null) httpReq.body = request.body!;

    try {
      final http.StreamedResponse streamed =
          await _client.send(httpReq).timeout(request.timeout);
      final http.Response response = await http.Response.fromStream(streamed);
      return ApiResponse(
        statusCode: response.statusCode,
        body: response.body,
        headers: response.headers,
      );
    } on TimeoutException {
      return ApiResponse(
        statusCode: 0,
        body: '',
        transportError: 'Request timed out after ${request.timeout.inSeconds}s',
      );
    } catch (error) {
      return ApiResponse(statusCode: 0, body: '', transportError: '$error');
    }
  }

  void close() => _client.close();
}

/// Records every call for the developer console. Wraps any other client.
class RecordingApiClient extends ApiClient {
  RecordingApiClient(this.inner);

  final ApiClient inner;
  final List<ApiRequest> calls = <ApiRequest>[];

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    calls.add(request);
    return inner.send(request);
  }
}
