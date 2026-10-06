import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/json_utils.dart';
import '../../services/connections/connection_state.dart';
import '../db/app_database.dart';

/// Persisted connection metadata (spec §30).
///
/// Only non-secret metadata is stored: which account type, which capabilities
/// were verified, when it was connected. Tokens stay in the secret store.
class ConnectionRepository {
  ConnectionRepository(this.db);

  final AppDatabase db;

  static const String _table = Tables.connections;

  Future<List<ConnectionRecord>> all() async {
    final List<Map<String, Object?>> rows = await db.database.query(_table);
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<ConnectionRecord?> byService(String service) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: 'service = ?',
      whereArgs: <Object?>[service],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<void> save(ConnectionRecord record) => db.database.insert(
        _table,
        <String, Object?>{
          'service': record.service,
          'account_type': record.accountType,
          'status': record.status.wire,
          'label': record.label,
          'capabilities': jsonEncode(record.capabilities),
          'limitations': jsonEncode(record.limitations),
          'metadata': jsonEncode(record.metadata),
          'connected_at': record.connectedAt?.millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> delete(String service) =>
      db.database.delete(_table, where: 'service = ?', whereArgs: <Object?>[service]);

  Future<void> clear() => db.database.delete(_table);

  ConnectionRecord _fromRow(Map<String, Object?> row) {
    final List<dynamic> capabilities =
        jsonDecode(asString(row['capabilities'], fallback: '[]')) as List<dynamic>;
    final List<dynamic> limitations =
        jsonDecode(asString(row['limitations'], fallback: '[]')) as List<dynamic>;
    return ConnectionRecord(
      service: asString(row['service']),
      accountType: asStringOrNull(row['account_type']),
      status: ConnectionStatus.fromWire(row['status']),
      label: asString(row['label']),
      capabilities: capabilities.map((Object? e) => asString(e)).toList(growable: false),
      limitations: limitations.map((Object? e) => asString(e)).toList(growable: false),
      metadata: asStringMap(jsonDecode(asString(row['metadata'], fallback: '{}'))),
      connectedAt: row['connected_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(asInt(row['connected_at'])),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(asInt(row['updated_at'])),
    );
  }
}
