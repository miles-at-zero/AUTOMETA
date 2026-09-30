import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/json_utils.dart';
import '../../domain/engine/approval_request.dart';
import '../db/app_database.dart';

/// Persisted approvals (spec §23).
///
/// Approvals outlive the process: if the app is killed while one is waiting,
/// it is still on the list at the next launch, and an expired one is marked
/// expired rather than silently dropped or silently acted on.
class ApprovalRepository {
  ApprovalRepository(this.db);

  final AppDatabase db;

  static const String _table = Tables.approvals;

  Future<void> insert(ApprovalTicket ticket) => db.database.insert(
        _table,
        <String, Object?>{
          'id': ticket.id,
          'workflow_id': ticket.workflowId,
          'workflow_name': ticket.workflowName,
          'execution_id': ticket.executionId,
          'ticket_json': jsonEncode(ticket.toJson()),
          'decision': 'pending',
          'created_at': ticket.createdAt.millisecondsSinceEpoch,
          'expires_at': ticket.expiresAt.millisecondsSinceEpoch,
          'decided_at': null,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<ApprovalTicket>> pending({DateTime? now}) async {
    final DateTime moment = now ?? DateTime.now();
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: "decision = 'pending' AND expires_at > ?",
      whereArgs: <Object?>[moment.millisecondsSinceEpoch],
      orderBy: 'created_at ASC',
    );
    return rows.map(_fromRow).whereType<ApprovalTicket>().toList(growable: false);
  }

  Future<List<ApprovalTicket>> expired({DateTime? now}) async {
    final DateTime moment = now ?? DateTime.now();
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: "decision = 'pending' AND expires_at <= ?",
      whereArgs: <Object?>[moment.millisecondsSinceEpoch],
      orderBy: 'created_at DESC',
    );
    return rows.map(_fromRow).whereType<ApprovalTicket>().toList(growable: false);
  }

  Future<List<ApprovalTicket>> history({int limit = 30}) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).whereType<ApprovalTicket>().toList(growable: false);
  }

  Future<ApprovalTicket?> byId(String id) async {
    final List<Map<String, Object?>> rows =
        await db.database.query(_table, where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<ApprovalTicket?> byExecution(String executionId) async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: "execution_id = ? AND decision = 'pending'",
      whereArgs: <Object?>[executionId],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<void> decide(String id, ApprovalDecision decision, {DateTime? at}) => db.database.update(
        _table,
        <String, Object?>{
          'decision': decision.name,
          'decided_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );

  /// Marks stale tickets expired and returns how many were affected.
  Future<int> expireStale({DateTime? now}) async {
    final DateTime moment = now ?? DateTime.now();
    return db.database.update(
      _table,
      <String, Object?>{
        'decision': ApprovalDecision.expired.name,
        'decided_at': moment.millisecondsSinceEpoch,
      },
      where: "decision = 'pending' AND expires_at <= ?",
      whereArgs: <Object?>[moment.millisecondsSinceEpoch],
    );
  }

  Future<void> deleteForWorkflow(String workflowId) => db.database.delete(
        _table,
        where: 'workflow_id = ?',
        whereArgs: <Object?>[workflowId],
      );

  Future<void> clear() => db.database.delete(_table);

  ApprovalTicket? _fromRow(Map<String, Object?> row) {
    try {
      return ApprovalTicket.fromJson(jsonDecode(asString(row['ticket_json'])));
    } catch (_) {
      return null;
    }
  }
}
