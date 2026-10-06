import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { openDb } from '../src/db.js';
import { nextRun } from '../src/cloud/schedule.js';

const ENV = { ADMIN_KEY: 'adm', SECRET_KEY: 'k'.repeat(32), PUBLIC_URL: 'https://api.example.com' };
const TOKEN = '123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ';

function fakeTelegram() {
  const tg = { sent: [], tokenValid: true, failNext: 0 };
  tg.fetch = async (url, init) => {
    const m = String(url).match(/api\.telegram\.org\/bot([^/]+)\/(\w+)/);
    if (!m) throw new Error(`unexpected outbound call ${url}`);
    const json = (status, body) => new Response(JSON.stringify(body), { status });
    if (!tg.tokenValid || m[1] !== TOKEN) return json(401, { ok: false, description: 'Unauthorized' });
    if (m[2] === 'getMe') return json(200, { ok: true, result: { id: 1, username: 'autometa_test_bot', first_name: 'Bot' } });
    if (m[2] === 'getUpdates') return json(200, { ok: true, result: [{ message: { chat: { id: 42, type: 'private', first_name: 'Ada' } } }] });
    if (m[2] === 'sendMessage') {
      if (tg.failNext > 0) { tg.failNext--; return json(502, { ok: false, description: 'Bad gateway' }); }
      const p = JSON.parse(init.body);
      tg.sent.push(p);
      return json(200, { ok: true, result: { message_id: tg.sent.length, chat: { id: p.chat_id } } });
    }
    return json(404, { ok: false, description: 'nope' });
  };
  return tg;
}

async function setup({ now = Date.parse('2026-10-05T05:50:00Z') } = {}) {
  const clock = { t: now };
  const tg = fakeTelegram();
  const app = createApp({ db: openDb(':memory:'), env: ENV, clock: () => clock.t, fetchImpl: tg.fetch });
  const srv = app.server().listen(0);
  await new Promise((r) => srv.once('listening', r));
  const base = `http://127.0.0.1:${srv.address().port}`;
  const call = async (method, path, body, token, headers = {}) => {
    const res = await fetch(base + path, { method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body) });
    const txt = await res.text();
    let json; try { json = JSON.parse(txt); } catch { json = txt; }
    return { status: res.status, body: json };
  };
  const t = async (...a) => { const r = await call(...a); if (r.status >= 300) throw new Error(`${a[0]} ${a[1]} → ${r.status} ${JSON.stringify(r.body)}`); return r.body; };
  const signup = async (email = 'ada@example.com') => (await t('POST', '/v1/auth/signup', { email, password: 'correct horse battery', name: 'Ada', timezone: 'Africa/Lagos' })).token;
  return { app, base, clock, tg, call, t, signup, close: () => srv.close() };
}

const tgAutomation = (connectionId, extra = {}) => ({
  name: 'Morning Dad',
  trigger: { integration: 'autometa', key: 'schedule', schedule: { times: ['07:00'] } },
  steps: [{ id: 's1', type: 'action', integration: 'telegram', action: 'send_message', connectionId, config: { chatId: '42', text: 'Good morning Dad, it is {{weekday}}' } }],
  ...extra,
});

test('auth: signup, login, wrong password, logout, reset via admin link, delete', async () => {
  const s = await setup();
  try {
    const token = await s.signup();
    assert.equal((await s.call('POST', '/v1/auth/signup', { email: 'ada@example.com', password: 'correct horse battery' })).status, 409);
    assert.equal((await s.call('POST', '/v1/auth/signup', { email: 'b@example.com', password: 'short' })).status, 422);
    assert.equal((await s.call('POST', '/v1/auth/login', { email: 'ada@example.com', password: 'wrong password!!' })).status, 401);
    const { token: t2 } = await s.t('POST', '/v1/auth/login', { email: 'ADA@example.com', password: 'correct horse battery' });
    const me = await s.t('GET', '/v1/me', undefined, t2);
    assert.equal(me.user.timezone, 'Africa/Lagos');
    assert.equal(me.workspace.plan, 'free');
    await s.t('POST', '/v1/auth/logout', {}, t2);
    assert.equal((await s.call('GET', '/v1/me', undefined, t2)).status, 401);
    // Forgot never reveals whether the account exists.
    const f1 = await s.t('POST', '/v1/auth/forgot', { email: 'ada@example.com' });
    const f2 = await s.t('POST', '/v1/auth/forgot', { email: 'nobody@example.com' });
    assert.equal(f1.message, f2.message);
    const users = await s.t('GET', '/v1/admin/users', undefined, null, { 'x-admin-key': 'adm' });
    const link = await s.t('POST', `/v1/admin/users/${users[0].id}/reset-link`, {}, null, { 'x-admin-key': 'adm' });
    await s.t('POST', '/v1/auth/reset', { token: link.token, password: 'a brand new password' });
    assert.equal((await s.call('GET', '/v1/me', undefined, token)).status, 401, 'reset signs out all sessions');
    assert.equal((await s.call('POST', '/v1/auth/reset', { token: link.token, password: 'another new password' })).status, 400, 'reset link is single-use');
    const { token: t3 } = await s.t('POST', '/v1/auth/login', { email: 'ada@example.com', password: 'a brand new password' });
    assert.equal((await s.call('DELETE', '/v1/me', { password: 'nope' }, t3)).status, 401);
    await s.t('DELETE', '/v1/me', { password: 'a brand new password' }, t3);
    assert.equal((await s.call('POST', '/v1/auth/login', { email: 'ada@example.com', password: 'a brand new password' })).status, 401);
  } finally { s.close(); }
});

test('password reset email link opens a working HTML form (GET/POST /reset)', async () => {
  const s = await setup();
  try {
    await s.t('POST', '/v1/auth/signup', { email: 'rose@example.com', password: 'correct horse battery', name: 'Rose' });
    const users = await s.t('GET', '/v1/admin/users', undefined, null, { 'x-admin-key': 'adm' });
    const link = await s.t('POST', `/v1/admin/users/${users[0].id}/reset-link`, {}, null, { 'x-admin-key': 'adm' });
    assert.match(link.link, /\/reset\?token=/);
    const form = await fetch(`${s.base}/reset?token=${encodeURIComponent(link.token)}`);
    assert.equal(form.status, 200);
    const html = await form.text();
    assert.match(html, /<form method="post" action="\/reset"/);
    assert.ok(!/<script/i.test(html), 'no scripts on the reset page');
    const post = (password) => fetch(`${s.base}/reset`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ token: link.token, password }).toString() });
    const weak = await (await post('short')).text();
    assert.match(weak, /Password not changed/);
    const ok = await (await post('a brand new password')).text();
    assert.match(ok, /Password changed/);
    await s.t('POST', '/v1/auth/login', { email: 'rose@example.com', password: 'a brand new password' });
    assert.match(await (await post('another new password')).text(), /invalid or expired/, 'single-use');
    assert.match(await (await fetch(`${s.base}/reset`)).text(), /incomplete/);
  } finally { s.close(); }
});

test('login is rate limited', async () => {
  const s = await setup();
  try {
    await s.signup();
    let last;
    for (let i = 0; i < 11; i++) last = await s.call('POST', '/v1/auth/login', { email: 'ada@example.com', password: 'wrong password!!' });
    assert.equal(last.status, 429);
  } finally { s.close(); }
});

test('journey: connect Telegram → build → test (simulated) → activate → scheduled run → token revoked → paused → reconnect → healthy', async () => {
  const s = await setup();
  try {
    const tok = await s.signup();
    assert.equal((await s.call('POST', '/v1/connections', { integration: 'telegram', fields: { token: 'bad' } }, tok)).status, 422);
    const conn = await s.t('POST', '/v1/connections', { integration: 'telegram', fields: { token: TOKEN } }, tok);
    assert.equal(conn.status, 'connected');
    assert.equal(conn.identity, '@autometa_test_bot');
    assert.ok(!JSON.stringify(conn).includes(TOKEN), 'token never returned');
    const chats = await s.t('GET', `/v1/connections/${conn.id}/chats`, undefined, tok);
    assert.equal(String(chats[0].id), '42');

    // Draft with missing chat → validator explains the fix.
    const bad = tgAutomation(conn.id);
    bad.steps[0].config.chatId = '';
    let a = await s.t('POST', '/v1/automations', bad, tok);
    assert.equal(a.status, 'draft');
    assert.ok(a.validation.checks.some((c) => !c.ok && c.fix));
    assert.equal((await s.call('POST', `/v1/automations/${a.id}/activate`, {}, tok)).status, 422);
    a = await s.t('PUT', `/v1/automations/${a.id}`, tgAutomation(conn.id), tok);
    assert.equal(a.status, 'ready');

    // Test without live: nothing is sent.
    const test1 = await s.t('POST', `/v1/automations/${a.id}/test`, {}, tok);
    assert.equal(test1.status, 'success');
    assert.equal(s.tg.sent.length, 0);
    assert.match(test1.notice, /No live action/);
    assert.equal(test1.steps.find((x) => x.kind === 'action').status, 'simulated');
    // Live test requires explicit confirmation.
    assert.equal((await s.call('POST', `/v1/automations/${a.id}/test`, { live: true }, tok)).status, 400);
    await s.t('POST', `/v1/automations/${a.id}/test`, { live: true, confirm: true }, tok);
    assert.equal(s.tg.sent.length, 1);

    a = await s.t('POST', `/v1/automations/${a.id}/activate`, {}, tok);
    assert.equal(a.status, 'active');
    assert.equal(new Date(a.nextRunAt).toISOString(), '2026-10-05T06:00:00.000Z', '07:00 Lagos = 06:00Z');

    // Server-side scheduler fires.
    s.clock.t = Date.parse('2026-10-05T06:00:10Z');
    await s.app.cloud.engine.tick();
    assert.equal(s.tg.sent.length, 2);
    assert.match(s.tg.sent[1].text, /Monday/);
    // Ticking again does not double-send.
    await s.app.cloud.engine.tick();
    assert.equal(s.tg.sent.length, 2);

    // Token revoked → auth failure → paused immediately, notification, reconnect offered.
    s.tg.tokenValid = false;
    s.clock.t = Date.parse('2026-10-06T06:00:30Z');
    await s.app.cloud.engine.tick();
    a = await s.t('GET', `/v1/automations/${a.id}`, undefined, tok);
    assert.equal(a.status, 'error');
    const conns = await s.t('GET', '/v1/connections', undefined, tok);
    assert.equal(conns[0].status, 'needs_reauth');
    const failed = (await s.t('GET', '/v1/executions?status=failed', undefined, tok))[0];
    const detail = await s.t('GET', `/v1/executions/${failed.id}`, undefined, tok);
    assert.equal(detail.actions.reconnect.connectionId, conn.id);
    assert.ok(detail.steps.some((x) => x.fix && /Reconnect/.test(x.fix)));
    const notes = await s.t('GET', '/v1/notifications', undefined, tok);
    assert.ok(notes.length >= 1);

    s.tg.tokenValid = true;
    const rc = await s.t('POST', `/v1/connections/${conn.id}/reconnect`, { fields: { token: TOKEN } }, tok);
    assert.equal(rc.pausedAutomations.length, 1);
    await s.t('POST', `/v1/automations/${a.id}/activate`, {}, tok);
    const retried = await s.t('POST', `/v1/executions/${failed.id}/retry`, {}, tok);
    assert.equal(retried.status, 'success');
    assert.equal(s.tg.sent.length, 3);
    const dash = await s.t('GET', '/v1/dashboard', undefined, tok);
    assert.equal(dash.totals.needsAttention, 0);
    assert.equal(dash.totals.connectedApps, 1);
  } finally { s.close(); }
});

test('isolation: another account cannot see or touch my resources', async () => {
  const s = await setup();
  try {
    const a = await s.signup('a@example.com');
    const b = await s.signup('b@example.com');
    const conn = await s.t('POST', '/v1/connections', { integration: 'telegram', fields: { token: TOKEN } }, a);
    const auto = await s.t('POST', '/v1/automations', tgAutomation(conn.id), a);
    const hook = await s.t('POST', '/v1/webhooks', { name: 'mine' }, a);
    for (const [m, p] of [['GET', `/v1/automations/${auto.id}`], ['PUT', `/v1/automations/${auto.id}`], ['DELETE', `/v1/automations/${auto.id}`], ['POST', `/v1/automations/${auto.id}/run`],
      ['POST', `/v1/connections/${conn.id}/test`], ['DELETE', `/v1/connections/${conn.id}`], ['GET', `/v1/webhooks/${hook.id}`], ['POST', `/v1/webhooks/${hook.id}/secret`]]) {
      assert.equal((await s.call(m, p, m === 'GET' ? undefined : {}, b)).status, 404, `${m} ${p}`);
    }
    // B can't attach A's connection to its own automation.
    const bAuto = await s.t('POST', '/v1/automations', tgAutomation(conn.id), b);
    assert.equal(bAuto.status, 'draft');
    assert.deepEqual(await s.t('GET', '/v1/automations', undefined, b).then((x) => x.map((y) => y.id)), [bAuto.id]);
    assert.equal((await s.t('GET', '/v1/search?q=morning', undefined, b)).results.filter((r) => r.type === 'automation').length, 1);
    assert.equal((await s.call('GET', '/v1/admin/users', undefined, a)).status, 403);
  } finally { s.close(); }
});

test('webhooks: secret, payload conditions, history, rotate, disable', async () => {
  const s = await setup();
  try {
    const tok = await s.signup();
    const hook = await s.t('POST', '/v1/webhooks', { name: 'Leads' }, tok);
    assert.ok(hook.secret && hook.url.startsWith('https://api.example.com/hooks/'));
    const tpl = await s.t('POST', '/v1/templates/webhook_notify/install', {}, tok);
    assert.equal(tpl.trigger.config.webhookId, hook.id);
    await s.t('POST', `/v1/automations/${tpl.id}/activate`, {}, tok);
    const path = new URL(hook.url).pathname;
    assert.equal((await s.call('POST', path, { priority: 'high' })).status, 401);
    let r = await s.call('POST', path, { event: 'lead', name: 'Jane', priority: 'high' }, null, { 'x-autometa-secret': hook.secret });
    assert.equal(r.status, 202);
    assert.equal(r.body.executionIds.length, 1);
    r = await s.call('POST', path, { event: 'lead', priority: 'low' }, null, { 'x-autometa-secret': hook.secret });
    const runs = await s.t('GET', `/v1/executions?automation=${tpl.id}`, undefined, tok);
    assert.deepEqual(runs.map((x) => x.status).sort(), ['skipped', 'success']);
    const notes = await s.t('GET', '/v1/notifications', undefined, tok);
    assert.ok(notes.some((n) => n.title === 'High priority: lead'));
    const d = await s.t('GET', `/v1/webhooks/${hook.id}`, undefined, tok);
    assert.equal(d.requests.length, 3);
    assert.ok(!JSON.stringify(d.requests).includes(hook.secret), 'secret header is never stored');
    const rot = await s.t('POST', `/v1/webhooks/${hook.id}/secret`, {}, tok);
    assert.equal((await s.call('POST', path, {}, null, { 'x-autometa-secret': hook.secret })).status, 401);
    assert.equal((await s.call('POST', path, {}, null, { 'x-autometa-secret': rot.secret })).status, 202);
    const moved = await s.t('POST', `/v1/webhooks/${hook.id}/rotate-url`, {}, tok);
    assert.equal((await s.call('POST', path, {}, null, { 'x-autometa-secret': rot.secret })).status, 404);
    await s.t('PATCH', `/v1/webhooks/${hook.id}`, { enabled: false }, tok);
    assert.equal((await s.call('POST', new URL(moved.url).pathname, {}, null, { 'x-autometa-secret': rot.secret })).status, 410);
  } finally { s.close(); }
});

test('limits: free plan caps automations and monthly executions server-side', async () => {
  const s = await setup();
  try {
    const tok = await s.signup();
    const ws = s.app.db.prepare('SELECT * FROM workspaces').get();
    const lim = (await s.t('GET', '/v1/usage', undefined, tok)).automations.limit;
    for (let i = 0; i < lim; i++) await s.t('POST', '/v1/automations', { name: `a${i}` }, tok);
    const over = await s.call('POST', '/v1/automations', { name: 'too many' }, tok);
    assert.equal(over.status, 402);
    assert.ok(over.body.requiredPlan);
    // Exhaust executions: further runs are recorded as skipped with a clear reason.
    const execLimit = (await s.t('GET', '/v1/usage', undefined, tok)).executions.limit;
    s.app.db.prepare('INSERT INTO usage_records (workspace_id, month, metric, count) VALUES (?,?,?,?) ON CONFLICT DO UPDATE SET count = excluded.count').run(ws.id, '2026-10', 'executions', execLimit);
    const hook = await s.t('POST', '/v1/webhooks', { requireSecret: false }, tok);
    assert.equal((await s.call('POST', new URL(hook.url).pathname, {})).status, 429);
    await s.t('POST', `/v1/admin/workspaces/${ws.id}/plan`, { plan: 'pro' }, null, { 'x-admin-key': 'adm' });
    await s.t('POST', '/v1/automations', { name: 'now allowed' }, tok);
  } finally { s.close(); }
});

test('retries: transient failure retried per policy; receipts prevent duplicate sends', async () => {
  const s = await setup();
  try {
    const tok = await s.signup();
    await s.t('POST', `/v1/admin/workspaces/${s.app.db.prepare('SELECT id FROM workspaces').get().id}/plan`, { plan: 'pro' }, null, { 'x-admin-key': 'adm' });
    const conn = await s.t('POST', '/v1/connections', { integration: 'telegram', fields: { token: TOKEN } }, tok);
    const a = await s.t('POST', '/v1/automations', { ...tgAutomation(conn.id), trigger: { integration: 'autometa', key: 'manual' }, retry: { policy: 'three' } }, tok);
    s.tg.failNext = 1;
    let ex = await s.t('POST', `/v1/automations/${a.id}/run`, {}, tok);
    assert.equal(ex.status, 'running', 'waiting for retry');
    s.clock.t += 5 * 60e3;
    await s.app.cloud.engine.tick();
    ex = await s.t('GET', `/v1/executions/${ex.id}`, undefined, tok);
    assert.equal(ex.status, 'success');
    assert.equal(s.tg.sent.length, 1);
    // Re-running the same execution never re-sends a step that has a receipt.
    await s.app.cloud.engine.runExecution(ex.id);
    assert.equal(s.tg.sent.length, 1);
  } finally { s.close(); }
});

test('schedule: timezones, weekdays and DST', () => {
  const after = Date.parse('2026-10-05T12:00:00Z'); // Monday
  assert.equal(new Date(nextRun({ times: ['07:00'] }, 'Africa/Lagos', after)).toISOString(), '2026-10-06T06:00:00.000Z');
  assert.equal(new Date(nextRun({ times: ['18:00'], days: [0] }, 'Africa/Lagos', after)).toISOString(), '2026-10-11T17:00:00.000Z');
  assert.equal(new Date(nextRun({ cron: '30 9 * * 1-5' }, 'UTC', Date.parse('2026-10-09T10:00:00Z'))).toISOString(), '2026-10-12T09:30:00.000Z');
  // London leaves BST on 25 Oct 2026: 07:00 local becomes 07:00Z.
  assert.equal(new Date(nextRun({ times: ['07:00'] }, 'Europe/London', Date.parse('2026-10-25T00:00:00Z'))).toISOString(), '2026-10-25T07:00:00.000Z');
});

test('the integration catalog only lists real, implemented capabilities', async () => {
  const s = await setup();
  try {
    const cat = await s.t('GET', '/v1/integrations');
    const ids = cat.map((i) => i.id);
    for (const id of ['autometa', 'webhook', 'telegram', 'whatsapp']) assert.ok(ids.includes(id), id);
    for (const i of cat) for (const a of i.actions) assert.ok(a.label && Array.isArray(a.config), `${i.id}.${a.key}`);
  } finally { s.close(); }
});
