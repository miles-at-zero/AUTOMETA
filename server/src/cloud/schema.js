// Cloud automation platform schema. Every tenant row hangs off workspaces;
// all queries go through workspace-scoped helpers (see scope.js) because
// SQLite has no row-level security. Moving to Postgres RLS later only
// changes the storage layer, not the API.
export const CLOUD_SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE COLLATE NOCASE, name TEXT NOT NULL DEFAULT '',
  password_hash TEXT NOT NULL, timezone TEXT NOT NULL DEFAULT 'UTC',
  disabled INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, settings TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS user_sessions (
  token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, last_seen INTEGER NOT NULL, agent TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS password_resets (
  token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS workspaces (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan TEXT NOT NULL DEFAULT 'free', plan_status TEXT NOT NULL DEFAULT 'active', plan_period_end INTEGER,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS workspace_members (
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'owner', PRIMARY KEY (workspace_id, user_id)
);
CREATE TABLE IF NOT EXISTS connections (
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  integration TEXT NOT NULL, label TEXT NOT NULL DEFAULT '', identity TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'connected',      -- connected | needs_reauth | error | disconnected
  scopes TEXT NOT NULL DEFAULT '[]', secret_enc TEXT, meta TEXT NOT NULL DEFAULT '{}',
  last_ok_at INTEGER, last_error TEXT, created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS automations (
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft',         -- draft | ready | active | paused | error | archived
  status_reason TEXT, trigger TEXT NOT NULL DEFAULT '{}', steps TEXT NOT NULL DEFAULT '[]',
  timezone TEXT NOT NULL DEFAULT 'UTC', retry TEXT NOT NULL DEFAULT '{"policy":"none"}',
  on_failure TEXT NOT NULL DEFAULT 'pause_after_3', max_runs_per_day INTEGER,
  next_run_at INTEGER, consecutive_failures INTEGER NOT NULL DEFAULT 0, template_id TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_auto_due ON automations(status, next_run_at);
CREATE TABLE IF NOT EXISTS executions (
  id TEXT PRIMARY KEY, seq INTEGER NOT NULL, workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  automation_id TEXT NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
  trigger_type TEXT NOT NULL, trigger_data TEXT NOT NULL DEFAULT '{}', scheduled_for INTEGER,
  status TEXT NOT NULL,                          -- running | success | failed | partial | cancelled | skipped
  is_test INTEGER NOT NULL DEFAULT 0, live INTEGER NOT NULL DEFAULT 1,
  started_at INTEGER NOT NULL, ended_at INTEGER, error TEXT, retry_count INTEGER NOT NULL DEFAULT 0,
  vars TEXT NOT NULL DEFAULT '{}', cursor INTEGER NOT NULL DEFAULT 0,
  UNIQUE (automation_id, scheduled_for)
);
CREATE INDEX IF NOT EXISTS idx_exec_ws ON executions(workspace_id, started_at);
CREATE TABLE IF NOT EXISTS execution_steps (
  id INTEGER PRIMARY KEY AUTOINCREMENT, execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
  step_id TEXT NOT NULL, idx INTEGER NOT NULL, kind TEXT NOT NULL, label TEXT NOT NULL,
  status TEXT NOT NULL, detail TEXT, output TEXT, error TEXT, fix TEXT,
  attempts INTEGER NOT NULL DEFAULT 0, started_at INTEGER NOT NULL, ended_at INTEGER
);
CREATE TABLE IF NOT EXISTS step_receipts (
  key TEXT PRIMARY KEY, output TEXT, created_at INTEGER NOT NULL  -- idempotency: executionId:stepId
);
CREATE TABLE IF NOT EXISTS cloud_jobs (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, execution_id TEXT REFERENCES executions(id) ON DELETE CASCADE,
  due_at INTEGER NOT NULL, locked_until INTEGER, attempts INTEGER NOT NULL DEFAULT 0,
  done INTEGER NOT NULL DEFAULT 0, last_error TEXT, created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cloud_jobs ON cloud_jobs(done, due_at);
CREATE TABLE IF NOT EXISTS webhooks (
  id TEXT PRIMARY KEY, public_id TEXT NOT NULL UNIQUE, workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  automation_id TEXT REFERENCES automations(id) ON DELETE SET NULL, name TEXT NOT NULL,
  secret_hash TEXT, enabled INTEGER NOT NULL DEFAULT 1, request_count INTEGER NOT NULL DEFAULT 0,
  last_received_at INTEGER, created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS webhook_requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT, webhook_id TEXT NOT NULL REFERENCES webhooks(id) ON DELETE CASCADE,
  received_at INTEGER NOT NULL, status INTEGER NOT NULL, outcome TEXT NOT NULL, headers TEXT, payload TEXT,
  execution_id TEXT, is_test INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS notifications (
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, severity TEXT NOT NULL DEFAULT 'info', title TEXT NOT NULL, body TEXT NOT NULL,
  action TEXT, target TEXT, read INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS usage_records (
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE, month TEXT NOT NULL,
  metric TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (workspace_id, month, metric)
);
CREATE TABLE IF NOT EXISTS cloud_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT, workspace_id TEXT, user_id TEXT, action TEXT NOT NULL,
  target TEXT, detail TEXT, ip TEXT, ts INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS oauth_states (
  state TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, user_id TEXT NOT NULL, integration TEXT NOT NULL,
  verifier TEXT, redirect TEXT, expires_at INTEGER NOT NULL
);
`;
