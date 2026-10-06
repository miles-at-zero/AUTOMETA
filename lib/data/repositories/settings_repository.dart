import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/json_utils.dart';
import '../db/app_database.dart';
import 'recipient.dart';

/// Key/value app settings.
///
/// Only non-sensitive values live here. Anything that authenticates the user
/// to an external service goes through [SecretStore].
class SettingsRepository {
  SettingsRepository(this.db);

  final AppDatabase db;

  static const String _table = Tables.settings;

  Future<Map<String, String>> all() async {
    final List<Map<String, Object?>> rows = await db.database.query(_table);
    return <String, String>{
      for (final Map<String, Object?> row in rows)
        asString(row['key']): asString(row['value']),
    };
  }

  Future<String?> get(String key) async {
    final List<Map<String, Object?>> rows =
        await db.database.query(_table, where: 'key = ?', whereArgs: <Object?>[key], limit: 1);
    return rows.isEmpty ? null : asStringOrNull(rows.first['value']);
  }

  Future<bool> getBool(String key, {bool fallback = false}) async {
    final String? raw = await get(key);
    return raw == null ? fallback : asBool(raw, fallback: fallback);
  }

  Future<void> set(String key, String value) => db.database.insert(
        _table,
        <String, Object?>{'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> setBool(String key, bool value) => set(key, value ? 'true' : 'false');

  Future<void> setInt(String key, int value) => set(key, '$value');

  Future<void> setDouble(String key, double value) => set(key, value.toString());

  Future<void> remove(String key) =>
      db.database.delete(_table, where: 'key = ?', whereArgs: <Object?>[key]);
}

/// User-defined `{{variables}}` (spec §14).
class VariableRepository {
  VariableRepository(this.db);

  final AppDatabase db;

  static const String _table = Tables.variables;

  Future<Map<String, String>> all() async {
    final List<Map<String, Object?>> rows = await db.database.query(_table);
    return <String, String>{
      for (final Map<String, Object?> row in rows)
        asString(row['name']): asString(row['value']),
    };
  }

  Future<void> put(String name, String value, {String description = ''}) => db.database.insert(
        _table,
        <String, Object?>{
          'name': name.trim(),
          'value': value,
          'description': description,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> delete(String name) =>
      db.database.delete(_table, where: 'name = ?', whereArgs: <Object?>[name]);

  Future<void> clear() => db.database.delete(_table);
}

/// Recipient aliases.
///
/// A workflow always names a contact by alias ("Dad"); the phone number is
/// resolved at execution time. That keeps numbers out of workflow definitions,
/// out of exports and out of logs (spec §5, §31).
class ContactRepository {
  ContactRepository(this.db);

  final AppDatabase db;

  static const String _table = Tables.contacts;

  Future<List<Recipient>> all() async {
    final List<Map<String, Object?>> rows =
        await db.database.query(_table, orderBy: 'alias COLLATE NOCASE ASC');
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<Recipient?> byAlias(String alias) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: 'alias = ? COLLATE NOCASE',
      whereArgs: <Object?>[alias.trim()],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<Recipient?> byId(String id) async {
    final List<Map<String, Object?>> rows =
        await db.database.query(_table, where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<void> save(Recipient contact) => db.database.insert(
        _table,
        <String, Object?>{
          'id': contact.id,
          'alias': contact.alias.trim(),
          'display_name': contact.displayName.trim(),
          'phone_e164': contact.phoneE164.trim(),
          'notes': contact.notes,
          'created_at': (contact.createdAt ?? DateTime.now()).millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> delete(String id) =>
      db.database.delete(_table, where: 'id = ?', whereArgs: <Object?>[id]);

  Recipient _fromRow(Map<String, Object?> row) => Recipient(
        id: asString(row['id']),
        alias: asString(row['alias']),
        displayName: asString(row['display_name']),
        phoneE164: asString(row['phone_e164']),
        notes: asString(row['notes']),
        createdAt: row['created_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(asInt(row['created_at'])),
      );
}
