import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/json_utils.dart';
import '../../core/utils/logger.dart';
import '../../data/repositories/approval_repository.dart';
import '../../data/repositories/execution_repository.dart';
import '../../domain/engine/approval_request.dart';
import '../../domain/engine/engine_ports.dart';
import '../../domain/models/execution.dart';
import '../db/app_database.dart';

/// Durable duplicate guard (spec §21).
///
/// The claim is a row insert against a column with a UNIQUE index, so two
/// alarms racing for the same slot cannot both win — the loser gets a
/// `DatabaseException` and the engine records a SKIP.
class SqlIdempotencyStore implements IdempotencyStore {
  SqlIdempotencyStore(this.db);

  final AppDatabase db;
  final Logger _log = Logger.withTag(LogTags.engine);

  @override
  Future<bool> claim(String key, {required String executionId}) async {
    try {
      await db.database.insert(
        'idempotency_keys',
        <String, Object?>{
          'key': key,
          'execution_id': executionId,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return true;
    } on DatabaseException catch (error) {
      _log.info('Idempotency claim rejected for ${_tail(key)}: $error');
      return false;
    }
  }

  @override
  Future<bool> isClaimed(String key) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      'idempotency_keys',
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> release(String key) => db.database.delete(
        'idempotency_keys',
        where: 'key = ?',
        whereArgs: <Object?>[key],
      );

  /// Drops claims older than [olderThan] so the table cannot grow forever.
  Future<int> prune({Duration olderThan = const Duration(days: 60)}) {
    final int cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    return db.database.delete(
      'idempotency_keys',
      where: 'created_at < ?',
      whereArgs: <Object?>[cutoff],
    );
  }

  static String _tail(String key) => key.length <= 16 ? key : key.substring(key.length - 16);
}

/// Persists engine output into SQLite.
class SqlEngineSink implements EngineSink {
  SqlEngineSink({required this.executions, required this.approvals});

  final ExecutionRepository executions;
  final ApprovalRepository approvals;

  @override
  Future<void> onExecutionStart(ExecutionRecord record) => executions.insert(record);

  @override
  Future<void> onExecutionUpdate(ExecutionRecord record) => executions.update(record);

  @override
  Future<void> onApprovalRequested(dynamic ticket) async {
    if (ticket is ApprovalTicket) await approvals.insert(ticket);
  }
}

/// In-memory twin of the SQL guard, used by tests and by the headless isolate
/// before the database is open.
class MemoryIdempotencyStore implements IdempotencyStore {
  final Map<String, String> _claims = <String, String>{};

  @override
  Future<bool> claim(String key, {required String executionId}) async =>
      _claims.putIfAbsent(key, () => executionId) == executionId;

  @override
  Future<bool> isClaimed(String key) async => _claims.containsKey(key);

  @override
  Future<void> release(String key) async => _claims.remove(key);

  int get size => _claims.length;
}

/// Convenience accessor used by the developer screen.
Future<List<Map<String, Object?>>> readIdempotencyRows(AppDatabase db) =>
    db.database.query('idempotency_keys', orderBy: 'created_at DESC', limit: 100);

/// Extracts a status summary for the dashboard without loading every row.
Future<Map<String, int>> countExecutionsByStatus(AppDatabase db) async {
  final List<Map<String, Object?>> rows = await db.database.rawQuery(
    'SELECT status, COUNT(*) AS n FROM ${Tables.executions} WHERE dry_run = 0 GROUP BY status',
  );
  return <String, int>{
    for (final Map<String, Object?> row in rows)
      asString(row['status']): asInt(row['n']),
  };
}
