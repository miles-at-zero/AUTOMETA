import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/json_utils.dart';
import '../../core/utils/logger.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_status.dart';
import '../db/app_database.dart';

/// Execution history (spec §19) and the durable duplicate guard (spec §21).
class ExecutionRepository {
  ExecutionRepository(this.db);

  final AppDatabase db;
  final Logger _log = Logger.withTag(LogTags.db);

  static const String _table = Tables.executions;

  Future<void> insert(ExecutionRecord record) async {
    await db.database.insert(_table, _toRow(record), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> update(ExecutionRecord record) async {
    final int changed = await db.database.update(
      _table,
      _toRow(record),
      where: 'id = ?',
      whereArgs: <Object?>[record.id],
    );
    if (changed == 0) await insert(record);
  }

  Future<ExecutionRecord?> byId(String id) async {
    final List<Map<String, Object?>> rows =
        await db.database.query(_table, where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<ExecutionRecord?> byKey(String key) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: 'idempotency_key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Whether any record (run or skip) exists for a scheduled slot key.
  Future<bool> anyForKey(String key) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      columns: <String>['id'],
      where: 'idempotency_key = ? OR idempotency_key LIKE ?',
      whereArgs: <Object?>[key, '$key#%'],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<ExecutionRecord>> recent({int limit = 50, bool includeDryRuns = false}) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: includeDryRuns ? null : 'dry_run = 0',
      orderBy: 'scheduled_for DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<List<ExecutionRecord>> forWorkflow(String workflowId, {int limit = 50}) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: 'workflow_id = ? AND dry_run = 0',
      whereArgs: <Object?>[workflowId],
      orderBy: 'scheduled_for DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Everything still parked: waiting for approval or a deferred wait.
  Future<List<ExecutionRecord>> pending() async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: "status IN ('${ExecutionStatus.pending.wire}', '${ExecutionStatus.waitingApproval.wire}',"
          " '${ExecutionStatus.running.wire}')",
      orderBy: 'scheduled_for ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<List<ExecutionRecord>> failed({int limit = 20}) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: "status = '${ExecutionStatus.failed.wire}'",
      orderBy: 'scheduled_for DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Runs on the local calendar day of [day], oldest first.
  Future<List<ExecutionRecord>> onDay(DateTime day) async {
    final DateTime start = DateTime(day.year, day.month, day.day);
    final DateTime end = start.add(const Duration(days: 1));
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: 'scheduled_for >= ? AND scheduled_for < ? AND dry_run = 0',
      whereArgs: <Object?>[start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'scheduled_for ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<ExecutionRecord?> lastForWorkflow(String workflowId) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: 'workflow_id = ? AND dry_run = 0',
      whereArgs: <Object?>[workflowId],
      orderBy: 'scheduled_for DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Deletes history older than [olderThan]; returns rows removed.
  Future<int> prune({Duration olderThan = const Duration(days: 30)}) async {
    final int cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    final int removed = await db.database.delete(
      _table,
      where: 'scheduled_for < ? AND dry_run = 1',
      whereArgs: <Object?>[cutoff],
    );
    if (removed > 0) _log.info('Pruned $removed dry-run rows');
    return removed;
  }

  Future<void> clearAll() => db.database.delete(_table);

  Map<String, Object?> _toRow(ExecutionRecord record) {
    final Map<String, dynamic> json = record.toJson();
    return <String, Object?>{
      'id': record.id,
      'workflow_id': record.workflowId,
      'workflow_name': record.workflowName,
      'idempotency_key': record.idempotencyKey,
      'scheduled_for': record.scheduledFor.millisecondsSinceEpoch,
      'status': record.status.wire,
      'source': record.source.wire,
      'started_at': record.startedAt?.millisecondsSinceEpoch,
      'finished_at': record.finishedAt?.millisecondsSinceEpoch,
      'attempt': record.attempt,
      'max_attempts': record.maxAttempts,
      'dry_run': boolToInt(record.dryRun),
      'failure_reason': record.failureReason,
      'failure_code': record.failureCode,
      'steps_json': jsonEncode(json['steps'] ?? <dynamic>[]),
      'resume_at': record.resumeAt?.millisecondsSinceEpoch,
      'resume_program': jsonEncode(
        record.resumeProgram.map((dynamic s) => s.toJson()).toList(),
      ),
      'pending_step_id': record.pendingStepId,
      'created_at': (record.createdAt ?? record.scheduledFor).millisecondsSinceEpoch,
    };
  }

  ExecutionRecord _fromRow(Map<String, Object?> row) {
    final List<dynamic> steps =
        (jsonDecode(asString(row['steps_json'], fallback: '[]')) as List<dynamic>);
    final List<dynamic> resume =
        (jsonDecode(asString(row['resume_program'], fallback: '[]')) as List<dynamic>);
    final Map<String, dynamic> base = <String, dynamic>{
      'id': row['id'],
      'workflow_id': row['workflow_id'],
      'workflow_name': row['workflow_name'],
      'idempotency_key': row['idempotency_key'],
      'scheduled_for': DateTime.fromMillisecondsSinceEpoch(asInt(row['scheduled_for'])),
      'status': row['status'],
      'source': row['source'],
      'attempt': row['attempt'],
      'max_attempts': row['max_attempts'],
      'dry_run': intToBool(row['dry_run']),
      'failure_reason': row['failure_reason'],
      'failure_code': row['failure_code'],
      'resume_program': resume,
      'pending_step_id': row['pending_step_id'],
      'created_at': row['created_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(asInt(row['created_at'])),
      'steps': steps,
    };
    final int? started = row['started_at'] as int?;
    final int? finished = row['finished_at'] as int?;
    final int? resumeAt = row['resume_at'] as int?;
    if (started != null) base['started_at'] = DateTime.fromMillisecondsSinceEpoch(started);
    if (finished != null) base['finished_at'] = DateTime.fromMillisecondsSinceEpoch(finished);
    if (resumeAt != null) base['resume_at'] = DateTime.fromMillisecondsSinceEpoch(resumeAt);
    return ExecutionRecord.fromJson(base);
  }
}
