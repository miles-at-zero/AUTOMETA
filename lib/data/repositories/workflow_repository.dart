import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:flutter/foundation.dart';

import '../../core/utils/json_utils.dart';
import '../../core/utils/logger.dart';
import '../../core/constants/app_constants.dart';
import '../../domain/models/workflow.dart';
import '../db/app_database.dart';

/// CRUD for workflow definitions.
///
/// The full JSON definition is the source of truth; the flat columns exist so
/// the dashboard can query "what runs next" without parsing every row.
class WorkflowRepository {
  WorkflowRepository(this.db);

  final AppDatabase db;
  final Logger _log = Logger.withTag(LogTags.db);

  static const String _table = Tables.workflows;

  Future<List<Workflow>> getAll() async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      orderBy: 'sort_order ASC, name COLLATE NOCASE ASC',
    );
    return rows.map(_fromRow).whereType<Workflow>().toList(growable: false);
  }

  Future<List<Workflow>> getEnabled() async {
    final List<Map<String, Object?>> rows = await db.database.query(
      _table,
      where: 'enabled = 1',
      orderBy: 'next_run_at ASC',
    );
    return rows.map(_fromRow).whereType<Workflow>().toList(growable: false);
  }

  Future<Workflow?> byId(String id) async {
    final List<Map<String, Object?>> rows =
        await db.database.query(_table, where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<Workflow> save(Workflow workflow) async {
    final DateTime now = DateTime.now();
    final Map<String, Object?> row = <String, Object?>{
      'id': workflow.id,
      'name': workflow.name,
      'enabled': boolToInt(workflow.enabled),
      'definition': jsonEncode(workflow.toJson()),
      'trigger_type': workflow.trigger.type.wire,
      'time_zone': workflow.timeZone,
      'created_at': (workflow.createdAt ?? now).millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    };
    await db.database.insert(_table, row, conflictAlgorithm: ConflictAlgorithm.replace);
    _log.info('Saved workflow "${workflow.name}"');
    return workflow.copyWith(updatedAt: now);
  }

  Future<void> delete(String id) async {
    await db.database.delete(_table, where: 'id = ?', whereArgs: <Object?>[id]);
    _log.info('Deleted workflow $id');
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await db.database.update(
      _table,
      <String, Object?>{'enabled': boolToInt(enabled), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Stores when the OS scheduler will next wake for this workflow.
  Future<void> setNextRun(String id, DateTime? nextRunAt) async {
    await db.database.update(
      _table,
      <String, Object?>{'next_run_at': nextRunAt?.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> clearAllNextRuns() =>
      db.database.update(_table, <String, Object?>{'next_run_at': null});

  Future<int> countEnabled() async {
    final List<Map<String, Object?>> rows = await db.database.rawQuery(
      'SELECT COUNT(*) AS n FROM $_table WHERE enabled = 1',
    );
    return asInt(rows.first['n']);
  }

  /// Persists an ordering chosen in the UI.
  Future<void> reorder(List<String> orderedIds) async {
    final Batch batch = db.database.batch();
    for (int i = 0; i < orderedIds.length; i++) {
      batch.update(
        _table,
        <String, Object?>{'sort_order': i},
        where: 'id = ?',
        whereArgs: <Object?>[orderedIds[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  Workflow? _fromRow(Map<String, Object?> row) {
    try {
      final Workflow workflow = Workflow.fromJson(jsonDecode(asString(row['definition'])));
      return workflow.copyWith(
        enabled: intToBool(row['enabled']),
        createdAt: DateTime.fromMillisecondsSinceEpoch(asInt(row['created_at'])),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(asInt(row['updated_at'])),
      );
    } catch (error) {
      _log.error('Stored workflow ${row['id']} could not be parsed', error);
      return null;
    }
  }
}

/// Reads the next-run column without loading definitions.
@immutable
class NextRunRow {
  const NextRunRow({required this.workflowId, required this.name, required this.nextRunAt});

  final String workflowId;
  final String name;
  final DateTime nextRunAt;
}
