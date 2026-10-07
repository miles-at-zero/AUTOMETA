import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { openDb } from '../src/db.js';
import { guardianReport, healthOf, GUARDIAN_RULES } from '../src/cloud/guardian.js';

// Guardian: read-only health + findings from REAL stored rows. These tests
// insert rows exactly as the engine stores them and check nothing is invented.
const ENV = { ADMIN_KEY: 'adm', SECRET_KEY: 'k'.repeat(32), PUBLIC_URL: 'https://api.example.com' };
const NOW = Date.parse('2026-10-07T12:00:00Z');
const H = 3600e3;

async function setup() {
  const clock = { t: NOW };
  const app = createApp({ db: openDb(':memory:'), env: ENV, clock: () => clock.t, fetchImpl: async (u) => { throw new Error(`unexpected outbound call ${u}`); } });
  const srv = app.server().listen(0);
  await new Promise((r) => srv.once('listening', r));
  const base = `http://127.0.0.1:${srv.address().port}`;
  const call = async (method, path, body, token) => {
    const res = await fetch(base + path, { method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const signup = async (email) => (await call('POST', '/v1/auth/signup', { email, password: 'correct horse battery', timezone: 'UTC' })).body.token;
  const tok = await signup('ada@example.com');
  const ws = (await call('GET', '/v1/me', undefined, tok)).body.workspace.id;
  const db = app.db;
  let seq = 0;
  const auto = (id, fields = {}) => db.prepare(`INSERT INTO automations (id, workspace_id, name, status, status_reason, trigger, steps, next_run_at, consecutive_failures, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(id, fields.ws ?? ws, fields.name ?? id, fields.status ?? 'active', fields.reason ?? null,
    JSON.stringify(fields.trigger ?? { type: 'webhook' }), JSON.stringify(fields.steps ?? []), fields.next ?? null, fields.cf ?? 0, NOW - 30 * 24 * H, NOW - 24 * H);
  const run = (automationId, hoursAgo, status, extra = {}) => db.prepare(`INSERT INTO executions (id, seq, workspace_id, automation_id, trigger_type, scheduled_for, status, is_test, started_at, error)
    VALUES (?, ?, ?, ?, 'webhook', ?, ?, ?, ?, ?)`).run(`e${++seq}`, seq, extra.ws ?? ws, automationId, NOW - hoursAgo * H + seq, status, extra.test ? 1 : 0, NOW - hoursAgo * H, extra.error ?? null);
  const conn = (id, status, extra = {}) => db.prepare(`INSERT INTO connections (id, workspace_id, integration, label, status, last_error, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`)
    .run(id, ws, extra.integration ?? 'telegram', extra.label ?? '', status, extra.error ?? null, NOW - 48 * H);
  return { app, call, tok, ws, db, auto, run, conn, signup, close: () => srv.close() };
}

test('empty workspace: no findings, no invented health', async () => {
  const s = await setup();
  try {
    const r = (await s.call('GET', '/v1/guardian', undefined, s.tok)).body;
    assert.deepEqual(r.findings, []);
    assert.deepEqual(r.automations, []);
    assert.deepEqual(r.summary, { healthy: 0, attention: 0, critical: 0, inactive: 0, unknown: 0 });
  } finally { s.close(); }
});

test('requires auth and is scoped to the caller workspace', async () => {
  const s = await setup();
  try {
    assert.equal((await s.call('GET', '/v1/guardian')).status, 401);
    s.auto('mine', { name: 'Mine' });
    const other = await s.signup('bob@example.com');
    const otherWs = (await s.call('GET', '/v1/me', undefined, other)).body.workspace.id;
    s.auto('theirs', { ws: otherWs, status: 'error', reason: 'boom' });
    const r = (await s.call('GET', '/v1/guardian', undefined, s.tok)).body;
    assert.deepEqual(r.automations.map((a) => a.id), ['mine']);
    assert.equal(r.findings.length, 0);
  } finally { s.close(); }
});

test('health + lifetime totals come from real rows; test runs are ignored', async () => {
  const s = await setup();
  try {
    s.auto('a', { name: 'Daily report' });
    s.run('a', 50, 'success'); s.run('a', 26, 'skipped'); s.run('a', 2, 'success');
    s.run('a', 1, 'failed', { test: true, error: 'test only' });
    const a = (await s.call('GET', '/v1/guardian', undefined, s.tok)).body.automations[0];
    assert.equal(a.health.state, 'healthy');
    assert.deepEqual(a.totals, { runs: 3, succeeded: 2, failed: 0, skipped: 1 });
    assert.equal(a.lastRunAt, NOW - 2 * H);
    assert.equal(a.mode, 'cloud');
  } finally { s.close(); }
});

test('3 failures in a row -> critical finding with the real error; 1 recent failure -> attention', async () => {
  const s = await setup();
  try {
    s.auto('bad', { name: 'Lead follow-up' });
    s.run('bad', 30, 'success'); s.run('bad', 3, 'failed', { error: 'Bot was blocked by the user' });
    s.run('bad', 2, 'partial', { error: 'x' }); s.run('bad', 1, 'failed', { error: 'Bot was blocked by the user' });
    s.auto('meh', { name: 'Alerts' });
    s.run('meh', 48, 'failed', { error: 'HTTP 500' }); s.run('meh', 1, 'success');
    const r = (await s.call('GET', '/v1/guardian', undefined, s.tok)).body;
    const crit = r.findings.find((f) => f.automationId === 'bad');
    assert.equal(crit.kind, 'repeated_failures');
    assert.equal(crit.severity, 'critical');
    assert.equal(crit.certainty, 'certain');
    assert.equal(crit.title, 'The last 3 runs failed.');
    assert.equal(crit.body, 'Bot was blocked by the user');
    const att = r.findings.find((f) => f.automationId === 'meh');
    assert.equal(att.kind, 'recent_failures');
    assert.equal(att.severity, 'attention');
    assert.equal(r.findings[0].severity, 'critical', 'sorted most severe first');
    assert.equal(r.summary.critical, 1);
    assert.equal(r.summary.attention, 1);
  } finally { s.close(); }
});

test('paused by the engine (status error) -> critical with the stored reason', async () => {
  const s = await setup();
  try {
    s.auto('p', { status: 'error', reason: 'Paused after 3 failures: Telegram token revoked', cf: 3 });
    const f = (await s.call('GET', '/v1/guardian', undefined, s.tok)).body.findings[0];
    assert.equal(f.kind, 'paused_after_failures');
    assert.equal(f.body, 'Paused after 3 failures: Telegram token revoked');
    assert.equal(f.evidence.consecutiveFailures, 3);
  } finally { s.close(); }
});

test('overdue schedule is "unusual", not certain, and respects the grace period', async () => {
  const s = await setup();
  try {
    s.auto('late', { trigger: { type: 'schedule' }, next: NOW - 40 * 60e3 });
    s.auto('ontime', { trigger: { type: 'schedule' }, next: NOW - 5 * 60e3 });
    s.auto('paused', { status: 'paused', trigger: { type: 'schedule' }, next: NOW - 10 * H });
    const fs = (await s.call('GET', '/v1/guardian', undefined, s.tok)).body.findings;
    assert.equal(fs.length, 1);
    assert.equal(fs[0].automationId, 'late');
    assert.equal(fs[0].kind, 'overdue_schedule');
    assert.equal(fs[0].certainty, 'unusual');
    assert.equal(fs[0].evidence.minutesLate, 40);
    assert.match(fs[0].title, /looks overdue/);
  } finally { s.close(); }
});

test('unusually quiet: only with enough history and well beyond its own rhythm', async () => {
  const s = await setup();
  try {
    // Ran every ~2h, then silent for 30h -> unusual.
    s.auto('hook', { name: 'Website leads' });
    for (const h of [30, 32, 34, 36, 38, 40]) s.run('hook', h, 'success');
    // Same rhythm but only 3 runs -> not enough evidence.
    s.auto('young');
    for (const h of [30, 32, 34]) s.run('young', h, 'success');
    // Normally daily, silent for 2 days -> within 3× rhythm, nothing to say.
    s.auto('daily');
    for (const d of [2, 3, 4, 5, 6, 7]) s.run('daily', d * 24, 'success');
    const fs = (await s.call('GET', '/v1/guardian', undefined, s.tok)).body.findings;
    assert.deepEqual(fs.map((f) => f.automationId), ['hook']);
    assert.equal(fs[0].kind, 'unusually_quiet');
    assert.equal(fs[0].severity, 'info');
    assert.equal(fs[0].certainty, 'unusual');
    assert.match(fs[0].body, /may be expected/);
  } finally { s.close(); }
});

test('connections needing reauth are flagged and linked to the automations that use them', async () => {
  const s = await setup();
  try {
    s.conn('c1', 'needs_reauth', { integration: 'gmail', label: 'Gmail', error: 'Token revoked' });
    s.conn('c2', 'connected');
    s.conn('c3', 'disconnected');
    s.auto('uses', { name: 'Invoice alert', trigger: { type: 'gmail', connectionId: 'c1' } });
    s.auto('other', { name: 'Unrelated', steps: [{ connectionId: 'c2' }] });
    const fs = (await s.call('GET', '/v1/guardian', undefined, s.tok)).body.findings;
    assert.equal(fs.length, 1);
    assert.equal(fs[0].kind, 'connection_attention');
    assert.equal(fs[0].title, 'Gmail needs to be reconnected');
    assert.equal(fs[0].body, 'Token revoked');
    assert.deepEqual(fs[0].evidence.affectedAutomations, [{ id: 'uses', name: 'Invoice alert' }]);
  } finally { s.close(); }
});

test('healthOf: inactive / unknown / skips never count as failures', () => {
  assert.equal(healthOf({ status: 'paused', runs: [], now: NOW }).state, 'inactive');
  assert.equal(healthOf({ status: 'active', runs: [], now: NOW }).state, 'unknown');
  assert.equal(healthOf({ status: 'active', runs: [{ status: 'skipped', started_at: NOW }], now: NOW }).state, 'unknown');
  const old = healthOf({ status: 'active', runs: [{ status: 'success', started_at: NOW - H }, { status: 'failed', started_at: NOW - 10 * 24 * H }], now: NOW });
  assert.equal(old.state, 'healthy');
  assert.equal(GUARDIAN_RULES.criticalStreak, 3);
});

test('guardianReport has no side effects', async () => {
  const s = await setup();
  try {
    s.auto('x', { status: 'error', reason: 'r' });
    s.conn('c', 'needs_reauth');
    const before = s.db.prepare('SELECT (SELECT COUNT(*) FROM notifications) n, (SELECT COUNT(*) FROM executions) e').get();
    guardianReport(s.db, s.ws, NOW);
    const after = s.db.prepare('SELECT (SELECT COUNT(*) FROM notifications) n, (SELECT COUNT(*) FROM executions) e').get();
    assert.deepEqual(after, before);
  } finally { s.close(); }
});
