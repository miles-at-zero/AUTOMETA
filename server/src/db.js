// SQLite storage (node:sqlite, zero dependencies). One file, WAL mode.
import { DatabaseSync } from 'node:sqlite';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at INTEGER NOT NULL,
  setup_notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS subscriptions (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  plan TEXT NOT NULL DEFAULT 'free',
  status TEXT NOT NULL DEFAULT 'active',      -- active | grace | on_hold | canceled | expired
  period_end INTEGER,                          -- ms; null = no expiry (free / manual lifetime)
  grace_until INTEGER,
  source TEXT NOT NULL DEFAULT 'none',         -- none | google_play | manual
  product_id TEXT, purchase_token TEXT,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS businesses (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL, timezone TEXT NOT NULL DEFAULT 'Africa/Lagos',
  phone_number_id TEXT UNIQUE, display_phone TEXT DEFAULT '',
  access_token_enc TEXT,                       -- AES-256-GCM, never returned by the API
  hours TEXT NOT NULL DEFAULT '{}',            -- {"mon":[["09:00","17:00"]],...}
  settings TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS members (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL, email TEXT DEFAULT '', role TEXT NOT NULL,   -- owner | admin | agent
  token_hash TEXT UNIQUE, invite_code_hash TEXT UNIQUE,
  active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS customers (
  id TEXT PRIMARY KEY, business_id TEXT NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  wa_id TEXT NOT NULL, name TEXT DEFAULT '', tags TEXT NOT NULL DEFAULT '[]',
  fields TEXT NOT NULL DEFAULT '{}', category TEXT DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',         -- open | needs_human | closed
  assigned_to TEXT, is_test INTEGER NOT NULL DEFAULT 0,
  first_seen INTEGER NOT NULL, last_inbound INTEGER, last_seen INTEGER NOT NULL,
  away_sent_at INTEGER, handoff_at INTEGER,
  UNIQUE (business_id, wa_id)
);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY, business_id TEXT NOT NULL, customer_id TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  direction TEXT NOT NULL,                     -- in | out
  text TEXT NOT NULL, wamid TEXT, status TEXT DEFAULT '',
  automated INTEGER NOT NULL DEFAULT 0, flow_id TEXT, member_id TEXT, error TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_customer ON messages(customer_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_wamid ON messages(wamid) WHERE wamid IS NOT NULL;
CREATE TABLE IF NOT EXISTS flows (
  id TEXT PRIMARY KEY, business_id TEXT NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, priority INTEGER NOT NULL DEFAULT 100,
  trigger TEXT NOT NULL, nodes TEXT NOT NULL, template_id TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS faqs (
  id TEXT PRIMARY KEY, business_id TEXT NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  keywords TEXT NOT NULL, answer TEXT NOT NULL, hits INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS sessions (
  customer_id TEXT PRIMARY KEY REFERENCES customers(id) ON DELETE CASCADE,
  flow_id TEXT NOT NULL, run_id TEXT NOT NULL, node_id TEXT NOT NULL,
  vars TEXT NOT NULL DEFAULT '{}', waiting TEXT NOT NULL,   -- answer | delay
  attempts INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY, business_id TEXT NOT NULL, customer_id TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,                          -- resume | followup
  due_at INTEGER NOT NULL, payload TEXT NOT NULL DEFAULT '{}', done INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_jobs_due ON jobs(done, due_at);
CREATE TABLE IF NOT EXISTS flow_runs (
  id TEXT PRIMARY KEY, business_id TEXT NOT NULL, flow_id TEXT NOT NULL, customer_id TEXT NOT NULL,
  status TEXT NOT NULL,                        -- running | waiting | completed | handoff | failed
  trace TEXT NOT NULL DEFAULT '[]', error TEXT, is_test INTEGER NOT NULL DEFAULT 0,
  started_at INTEGER NOT NULL, ended_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_runs_business ON flow_runs(business_id, started_at);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, business_id TEXT NOT NULL, type TEXT NOT NULL,
  customer_id TEXT, flow_id TEXT, value REAL, data TEXT, ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events ON events(business_id, ts);
CREATE TABLE IF NOT EXISTS ai_usage (business_id TEXT NOT NULL, month TEXT NOT NULL, calls INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (business_id, month));
CREATE TABLE IF NOT EXISTS ai_cache (key TEXT PRIMARY KEY, result TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS onboarding_codes (
  code_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL, member_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL, member_id TEXT, action TEXT NOT NULL,
  target TEXT, detail TEXT, ts INTEGER NOT NULL
);
`;

export function openDb(path = ':memory:') {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys = ON;');
  if (path !== ':memory:') db.exec('PRAGMA journal_mode = WAL;');
  db.exec(SCHEMA);
  return db;
}

export const J = {
  parse(s, fallback) {
    if (s == null || s === '') return fallback;
    try { return JSON.parse(s); } catch { return fallback; }
  },
  str: (v) => JSON.stringify(v ?? null),
};

/** Wraps fn in a transaction. node:sqlite has no helper, so BEGIN/COMMIT. */
export function tx(db, fn) {
  db.exec('BEGIN');
  try {
    const r = fn();
    db.exec('COMMIT');
    return r;
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
}
