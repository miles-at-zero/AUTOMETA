import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/app_constants.dart';
import '../utils/logger.dart';

/// Where credentials live.
///
/// Rules (spec §28, §31):
///  * Values are written to platform secure storage — on Android that is
///    EncryptedSharedPreferences backed by the Keystore.
///  * Values are never written to SQLite, never printed, and never included in
///    an error message. [redact] is applied before anything reaches a log.
///  * A missing value is `null`, not an empty string, so callers can tell
///    "never configured" apart from "configured as empty".
abstract class SecretStore {
  const SecretStore();

  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<bool> contains(String key);

  Future<void> clear();

  /// `abc••••yz` — safe to display in the UI next to a saved credential.
  static String redact(String? value) => Logger.redact(value);
}

/// Production implementation backed by `flutter_secure_storage`.
class SecureSecretStore extends SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;
  final Logger _log = Logger.withTag('SECRET');

  /// In-process cache. Secrets are read on the engine's background isolate
  /// where re-entering the platform channel is expensive; the cache is dropped
  /// on write/delete so it can never go stale.
  final Map<String, String> _cache = <String, String>{};

  @override
  Future<String?> read(String key) async {
    final String? cached = _cache[key];
    if (cached != null) return cached;
    try {
      final String? value = await _storage.read(key: key);
      if (value != null) _cache[key] = value;
      return value;
    } catch (error) {
      _log.warn('Secure storage read failed for $key', error);
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      _cache[key] = value;
      _log.info('Stored secret ${_label(key)} (${Logger.redact(value)})');
    } catch (error) {
      _log.error('Secure storage write failed for $key', error);
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    _cache.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (error) {
      _log.warn('Secure storage delete failed for $key', error);
    }
  }

  @override
  Future<bool> contains(String key) async => (await read(key))?.isNotEmpty ?? false;

  @override
  Future<void> clear() async {
    _cache.clear();
    try {
      await _storage.deleteAll();
    } catch (error) {
      _log.warn('Secure storage clear failed', error);
    }
  }

  /// Logs the *category* of a secret, never its value.
  String _label(String key) {
    if (key.contains('token')) return 'token';
    if (key.contains('api_key')) return 'api key';
    if (key.contains('secret')) return 'app secret';
    return 'credential';
  }
}

/// Test/preview implementation. Clearly named so it can never be mistaken for
/// real protection in production code review.
class InMemorySecretStore extends SecretStore {
  InMemorySecretStore([Map<String, String>? seed]) : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<bool> contains(String key) async => (_values[key]?.isNotEmpty ?? false);

  @override
  Future<void> clear() async => _values.clear();

  @visibleForTesting
  Map<String, String> get snapshot => Map<String, String>.unmodifiable(_values);
}
