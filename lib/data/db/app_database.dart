import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';

/// Table names.
class Tables {
  const Tables._();

  static const String workflows = 'workflows';
  static const String executions = 'executions';
  static const String approvals = 'approvals';
  static const String settings = 'settings';
  static const String contacts = 'contacts';
  static const String connections = 'connections';
  static const String variables = 'variables';
  static const String scheduleLog = 'schedule_log';
  static const String idempotencyKeys = 'idempotency_keys';
}

/// Schema for every table AUTOMETA owns.
///
/// Secrets are deliberately absent: API keys and access tokens live in
/// [SecretStore], which on Android is backed by the Keystore. The only
/// credential-adjacent column here is `contacts.phone_e164`, which is user
/// data, not a credential.
class Schema {
  const Schema._();

  static const int version = 1;

  static const String createWorkflows = '''
CREATE TABLE ${Tables.workflows} (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  enabled       INTEGER NOT NULL DEFAULT 1,
  definition    TEXT NOT NULL,
  trigger_type  TEXT NOT NULL DEFAULT 'schedule',
  next_run_at   INTEGER,
  time_zone     TEXT NOT NULL DEFAULT 'UTC',
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
)
''';

  /// The unique index below is the durable half of duplicate protection
  /// (spec §21): even if two alarms fire for the same slot, only one row wins.
  static const String createExecutions = '''
CREATE TABLE ${Tables.executions} (
  id                TEXT PRIMARY KEY,
  workflow_id       TEXT NOT NULL,
  workflow_name     TEXT NOT NULL,
  idempotency_key   TEXT NOT NULL UNIQUE,
  scheduled_for     INTEGER NOT NULL,
  status            TEXT NOT NULL,
  source            TEXT NOT NULL,
  started_at        INTEGER,
  finished_at       INTEGER,
  attempt           INTEGER NOT NULL DEFAULT 1,
  max_attempts      INTEGER NOT NULL DEFAULT 1,
  dry_run           INTEGER NOT NULL DEFAULT 0,
  failure_reason    TEXT,
  failure_code      TEXT,
  steps_json        TEXT NOT NULL DEFAULT '[]',
  resume_at         INTEGER,
  resume_program    TEXT NOT NULL DEFAULT '[]',
  pending_step_id   TEXT,
  created_at        INTEGER NOT NULL
)
''';

  static const String createApprovals = '''
CREATE TABLE ${Tables.approvals} (
  id            TEXT PRIMARY KEY,
  workflow_id   TEXT NOT NULL,
  workflow_name TEXT NOT NULL,
  execution_id  TEXT NOT NULL,
  ticket_json   TEXT NOT NULL,
  decision      TEXT NOT NULL DEFAULT 'pending',
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL,
  decided_at    INTEGER
)
''';

  static const String createSettings = '''
CREATE TABLE ${Tables.settings} (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
''';

  static const String createContacts = '''
CREATE TABLE ${Tables.contacts} (
  id           TEXT PRIMARY KEY,
  alias        TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  phone_e164   TEXT NOT NULL,
  notes        TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
)
''';

  static const String createConnections = '''
CREATE TABLE ${Tables.connections} (
  service          TEXT PRIMARY KEY,
  account_type     TEXT,
  status           TEXT NOT NULL,
  label            TEXT NOT NULL DEFAULT '',
  capabilities     TEXT NOT NULL DEFAULT '[]',
  limitations      TEXT NOT NULL DEFAULT '[]',
  metadata         TEXT NOT NULL DEFAULT '{}',
  connected_at     INTEGER,
  updated_at       INTEGER NOT NULL
)
''';

  static const String createVariables = '''
CREATE TABLE ${Tables.variables} (
  name        TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  updated_at  INTEGER NOT NULL
)
''';

  /// Durable half of duplicate protection (spec §21). The UNIQUE index on
  /// `key` is what makes two racing alarms mutually exclusive.
  static const String createIdempotencyKeys = '''
CREATE TABLE ${Tables.idempotencyKeys} (
  key           TEXT PRIMARY KEY,
  execution_id  TEXT NOT NULL,
  created_at    INTEGER NOT NULL
)
''';

  /// Audit trail of every arm/disarm handed to the OS scheduler. Useful when
  /// a run does not fire and the user needs to know whether the app or the
  /// platform dropped it.
  static const String createScheduleLog = '''
CREATE TABLE ${Tables.scheduleLog} (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  workflow_id  TEXT NOT NULL,
  action       TEXT NOT NULL,
  scheduled_at INTEGER,
  detail       TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL
)
''';

  static const List<String> indexes = <String>[
    'CREATE INDEX IF NOT EXISTS idx_executions_workflow ON ${Tables.executions}(workflow_id)',
    'CREATE INDEX IF NOT EXISTS idx_executions_status ON ${Tables.executions}(status)',
    'CREATE INDEX IF NOT EXISTS idx_executions_scheduled ON ${Tables.executions}(scheduled_for)',
    'CREATE INDEX IF NOT EXISTS idx_workflows_next_run ON ${Tables.workflows}(next_run_at)',
    'CREATE INDEX IF NOT EXISTS idx_approvals_decision ON ${Tables.approvals}(decision)',
  ];
}

/// Owns the SQLite connection and its migrations.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;
  static final Logger _log = Logger.withTag(LogTags.db);

  Database get database => _db;

  /// Opens (and migrates) the on-device database.
  static Future<AppDatabase> open({String? path, int? version}) async {
    final String resolved = path ?? await _defaultPath();
    _log.info('Opening database at $resolved');
    final Database db = await openDatabase(
      resolved,
      version: version ?? Schema.version,
      onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createAll,
      onUpgrade: _upgrade,
      onDowngrade: onDatabaseDowngradeDelete,
    );
    return AppDatabase._(db);
  }

  /// In-memory database for tests and for the headless isolate's fallback.
  static Future<AppDatabase> openInMemory({DatabaseFactory? factory}) async {
    final Database db = await (factory ?? databaseFactory).openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: Schema.version,
        onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createAll,
      ),
    );
    return AppDatabase._(db);
  }

  static Future<String> _defaultPath() async {
    // Imported lazily so tests never touch path_provider.
    final String dir = await getDatabasesPath();
    return '$dir/autometa.db';
  }

  static Future<void> _createAll(Database db, int version) async {
    final Batch batch = db.batch();
    batch.execute(Schema.createWorkflows);
    batch.execute(Schema.createExecutions);
    batch.execute(Schema.createApprovals);
    batch.execute(Schema.createSettings);
    batch.execute(Schema.createContacts);
    batch.execute(Schema.createConnections);
    batch.execute(Schema.createVariables);
    batch.execute(Schema.createScheduleLog);
    batch.execute(Schema.createIdempotencyKeys);
    for (final String index in Schema.indexes) {
      batch.execute(index);
    }
    await batch.commit(noResult: true);
    _log.info('Created schema v$version');
  }

  static Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    _log.info('Migrating schema $oldVersion -> $newVersion');
    // Future migrations land here, one `if (oldVersion < n)` block per version.
    // v1 is the baseline, so there is nothing to migrate yet.
  }

  Future<void> close() => _db.close();

  Future<T> transaction<T>(Future<T> Function(AppDatabase db) action) =>
      _db.transaction((Transaction txn) async => action(AppDatabase._(_db)));
}

/// Re-exported so callers do not need to import `sqflite` directly for the
/// in-memory test factory.
typedef DatabaseFactoryAlias = DatabaseFactory;

/// Small helper: `1`/`0` <-> `bool`, used by every repository.
int boolToInt(bool value) => value ? 1 : 0;
bool intToBool(Object? value) => value is int ? value != 0 : '$value' == 'true';

/// Keeps the compiler honest about the unused import in non-test builds.
@visibleForTesting
String debugSchemaVersion() => '${Schema.version}';
