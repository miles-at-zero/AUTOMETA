import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { createApp } from '../src/app.js';
import { openDb } from '../src/db.js';

// V1 critical scenarios: Gmail OAuth/trigger/action, reconnect, push, conditions.
const BASE_ENV = { ADMIN_KEY: 'adm', SECRET_KEY: 'k'.repeat(32), PUBLIC_URL: 'https://api.example.com' };
const GOOGLE = { GOOGLE_CLIENT_ID: 'cid.apps.googleusercontent.com', GOOGLE_CLIENT_SECRET: 'gsecret' };
const TG = '123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const SCOPES = 'https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send';

function fakes() {
  const f = { tg: [], gmailSent: [], inbox: [], refreshValid: true, codes: {}, pushes: [], calls: [] };
  const json = (status, body) => new Response(JSON.stringify(body), { status });
  f.fetch = async (url, init = {}) => {
    const u = String(url);
    f.calls.push(u);
    if (u.startsWith('https://api.telegram.org/')) {
      const m = u.match(/bot([^/]+)\/(\w+)/);
      if (m[1] !== TG) return json(401, { ok: false, description: 'Unauthorized' });
      if (m[2] === 'getMe') return json(200, { ok: true, result: { id: 1, username: 'bot', first_name: 'B' } });
      if (m[2] === 'sendMessage') { f.tg.push(JSON.parse(init.body)); return json(200, { ok: true, result: { message_id: f.tg.length } }); }
    }
    if (u === 'https://oauth2.googleapis.com/token') {
      const p = new URLSearchParams(init.body);
      if (p.get('grant_type') === 'authorization_code') {
        if (!f.codes[p.get('code')]) return json(400, { error: 'invalid_grant' });
        assert.ok(p.get('code_verifier'), 'PKCE verifier sent');
        assert.equal(p.get('redirect_uri'), 'https://api.example.com/oauth/google/callback');
        return json(200, { access_token: 'at1', refresh_token: 'rt1', expires_in: 3600, scope: SCOPES });
      }
      if (p.get('grant_type') === 'refresh_token') return f.refreshValid ? json(200, { access_token: 'at2', expires_in: 3600 }) : json(400, { error: 'invalid_grant' });
      if (p.get('grant_type').includes('jwt-bearer')) return json(200, { access_token: 'fcm-at', expires_in: 3600 });
    }
    if (u.startsWith('https://gmail.googleapis.com/gmail/v1/users/me')) {
      const auth = init.headers?.authorization;
      if (!/^Bearer at[12]$/.test(auth || '')) return json(401, { error: { message: 'bad token' } });
      const path = u.slice('https://gmail.googleapis.com/gmail/v1/users/me'.length);
      if (path === '/profile') return json(200, { emailAddress: 'ada@gmail.com' });
      if (path.startsWith('/messages?')) {
        const q = new URL(u).searchParams.get('q');
        const after = Number(q.match(/after:(\d+)/)[1]) * 1000;
        return json(200, { messages: f.inbox.filter((m) => m.internalDate >= after && (!q.includes('invoice') || /invoice/i.test(m.subject))).map((m) => ({ id: m.id })) });
      }
      if (path.startsWith('/messages/send')) { f.gmailSent.push(JSON.parse(init.body)); return json(200, { id: `sent${f.gmailSent.length}`, threadId: 't' }); }
      const id = path.match(/^\/messages\/([^?]+)/)?.[1];
      const m = f.inbox.find((x) => x.id === id);
      if (m) return json(200, { id: m.id, threadId: 't', snippet: m.snippet, internalDate: String(m.internalDate), payload: { headers: [{ name: 'From', value: m.from }, { name: 'Subject', value: m.subject }, { name: 'To', value: 'ada@gmail.com' }, { name: 'Date', value: 'x' }] } });
    }
    if (u.startsWith('https://fcm.googleapis.com/')) { f.pushes.push(JSON.parse(init.body)); return json(200, { name: 'm1' }); }
    throw new Error(`unexpected outbound call ${u}`);
  };
  return f;
}

async function setup(env = {}) {
  const clock = { t: Date.parse('2026-10-05T05:50:00Z') };
  const f = fakes();
  const app = createApp({ db: openDb(':memory:'), env: { ...BASE_ENV, ...env }, clock: () => clock.t, fetchImpl: f.fetch });
  const srv = app.server().listen(0);
  await new Promise((r) => srv.once('listening', r));
  const base = `http://127.0.0.1:${srv.address().port}`;
  const call = async (method, path, body, token) => {
    const res = await fetch(base + path, { method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: body === undefined ? undefined : JSON.stringify(body) });
    const txt = await res.text();
    let j; try { j = JSON.parse(txt); } catch { j = txt; }
    return { status: res.status, body: j };
  };
  const t = async (...a) => { const r = await call(...a); if (r.status >= 300) throw new Error(`${a[0]} ${a[1]} → ${r.status} ${JSON.stringify(r.body)}`); return r.body; };
  const tok = (await t('POST', '/v1/auth/signup', { email: 'ada@example.com', password: 'correct horse battery', timezone: 'Africa/Lagos' })).token;
  return { app, clock, f, call, t, tok, close: () => srv.close() };
}

async function connectGmail(s, connectionId) {
  const { url } = await s.t('POST', '/v1/oauth/gmail/start', connectionId ? { connectionId } : {}, s.tok);
  const q = new URL(url).searchParams;
  assert.equal(q.get('code_challenge_method'), 'S256');
  assert.equal(q.get('access_type'), 'offline');
  s.f.codes.good = true;
  const page = await s.call('GET', `/oauth/google/callback?state=${q.get('state')}&code=good`);
  assert.match(page.body, /Gmail connected/);
  // State is single-use.
  assert.match((await s.call('GET', `/oauth/google/callback?state=${q.get('state')}&code=good`)).body, /expired/);
  return (await s.t('GET', '/v1/connections', undefined, s.tok)).find((c) => c.integration === 'gmail');
}

test('Gmail without Google credentials: listed as unavailable, cannot start OAuth (EXTERNAL CONFIG)', async () => {
  const s = await setup();
  try {
    const g = (await s.t('GET', '/v1/integrations')).find((i) => i.id === 'gmail');
    assert.equal(g.available, false);
    assert.match(g.unavailableReason, /GOOGLE_CLIENT_ID/);
    assert.equal((await s.call('POST', '/v1/oauth/gmail/start', {}, s.tok)).status, 503);
    const h = await s.t('GET', '/health');
    assert.equal(h.cloud.gmail, false);
    assert.equal(h.cloud.push, false);
    assert.equal(h.cloud.scheduler, 'not_started', 'no fake "scheduler: true" before the loop runs');
    await s.app.cloud.engine.tick();
    assert.equal((await s.t('GET', '/health')).cloud.scheduler, 'running');
    s.clock.t += 120_000;
    assert.equal((await s.t('GET', '/health')).cloud.scheduler, 'stale');
    assert.ok(!JSON.stringify(await s.t('GET', '/v1/integrations')).match(/calendar/i), 'Calendar deferred: not listed');
  } finally { s.close(); }
});

test('Gmail journey: OAuth → new email trigger + condition → Telegram → revoked → paused → reconnect → healthy', async () => {
  const s = await setup(GOOGLE);
  try {
    const gc = await connectGmail(s);
    assert.equal(gc.status, 'connected');
    assert.equal(gc.identity, 'ada@gmail.com');
    const raw = s.app.db.prepare('SELECT secret_enc FROM connections WHERE id = ?').get(gc.id).secret_enc;
    assert.ok(!raw.includes('rt1'), 'refresh token encrypted at rest');
    assert.ok(!JSON.stringify(gc).includes('rt1'));
    const tc = await s.t('POST', '/v1/connections', { integration: 'telegram', fields: { token: TG } }, s.tok);

    const auto = {
      name: 'Invoice alert',
      trigger: { integration: 'gmail', key: 'new_email', connectionId: gc.id, config: { query: 'invoice' } },
      steps: [
        { id: 'c1', type: 'condition', mode: 'all', rules: [{ field: 'email.fromEmail', op: 'contains', value: 'billing' }, { field: 'email.subject', op: 'not_contains', value: 'spam' }] },
        { id: 's1', type: 'action', integration: 'telegram', action: 'send_message', connectionId: tc.id, config: { chatId: '42', text: 'Invoice from {{email.from}}: {{email.subject}}' } },
      ],
    };
    let a = await s.t('POST', '/v1/automations', auto, s.tok);
    assert.equal(a.status, 'ready', JSON.stringify(a.validation));
    const test1 = await s.t('POST', `/v1/automations/${a.id}/test`, {}, s.tok);
    assert.equal(test1.status, 'success');
    assert.match(test1.steps.find((x) => x.kind === 'condition').detail, /✓ email.fromEmail contains "billing" \(was "billing@example.com"\)/);
    assert.equal(s.f.tg.length, 0, 'test is simulated');

    // Old mail must not trigger after activation.
    s.f.inbox.push({ id: 'old', internalDate: s.clock.t - 3600e3, from: 'Billing <billing@x.com>', subject: 'Old invoice', snippet: '' });
    a = await s.t('POST', `/v1/automations/${a.id}/activate`, {}, s.tok);
    s.clock.t += 30e3;
    await s.app.cloud.engine.drain();
    assert.equal(s.f.tg.length, 0, 'backlog skipped');

    s.f.inbox.push({ id: 'm1', internalDate: s.clock.t + 1000, from: 'Billing <billing@x.com>', subject: 'Invoice #7', snippet: 'Pay' });
    s.f.inbox.push({ id: 'm2', internalDate: s.clock.t + 2000, from: 'Mallory <m@evil.com>', subject: 'invoice spam', snippet: '' });
    s.clock.t += 61e3;
    await s.app.cloud.engine.drain();
    assert.equal(s.f.tg.length, 1, 'only the matching email passes the condition');
    assert.equal(s.f.tg[0].text, 'Invoice from Billing <billing@x.com>: Invoice #7');
    const skipped = (await s.t('GET', '/v1/executions?status=skipped', undefined, s.tok))[0];
    const sd = await s.t('GET', `/v1/executions/${skipped.id}`, undefined, s.tok);
    assert.match(sd.steps.find((x) => x.kind === 'condition').detail, /✕ email.fromEmail contains "billing"/);
    // Polling again does not re-trigger.
    s.clock.t += 61e3;
    await s.app.cloud.engine.drain();
    assert.equal(s.f.tg.length, 1);

    // Access token expired → refreshed transparently and persisted.
    s.clock.t += 3700e3;
    await s.app.cloud.engine.drain();
    assert.ok(s.f.calls.some((c) => c === 'https://oauth2.googleapis.com/token'));

    // Revoked → connection needs reauth, automation paused, notification with reconnect.
    s.f.refreshValid = false;
    s.clock.t += 3700e3;
    await s.app.cloud.engine.drain();
    a = await s.t('GET', `/v1/automations/${a.id}`, undefined, s.tok);
    assert.equal(a.status, 'error');
    const conns = await s.t('GET', '/v1/connections', undefined, s.tok);
    assert.equal(conns.find((c) => c.id === gc.id).status, 'needs_reauth');
    const n = (await s.t('GET', '/v1/notifications', undefined, s.tok)).find((x) => x.kind === 'connection_reauth');
    assert.ok(n, 'reauth notification');
    // Credential-based reconnect is refused for OAuth apps; OAuth reconnect keeps the same connection id.
    assert.equal((await s.call('POST', `/v1/connections/${gc.id}/reconnect`, { fields: {} }, s.tok)).status, 422);
    s.f.refreshValid = true;
    const again = await connectGmail(s, gc.id);
    assert.equal(again.id, gc.id);
    assert.equal(again.status, 'connected');
    a = await s.t('POST', `/v1/automations/${a.id}/activate`, {}, s.tok);
    assert.equal(a.status, 'active');
    const dash = await s.t('GET', '/v1/dashboard', undefined, s.tok);
    assert.equal(dash.totals.needsAttention, 0);
  } finally { s.close(); }
});

test('Gmail send_email action: validates recipients, sends RFC 2822 message, not idempotent', async () => {
  const s = await setup(GOOGLE);
  try {
    const gc = await connectGmail(s);
    const mk = (to) => ({ name: 'Mail', trigger: { integration: 'autometa', key: 'schedule', schedule: { times: ['07:00'] } }, steps: [{ id: 's1', type: 'action', integration: 'gmail', action: 'send_email', connectionId: gc.id, config: { to, subject: 'Hi Dad', body: 'Good morning ({{weekday}})' } }] });
    const bad = await s.t('POST', '/v1/automations', mk('not-an-email'), s.tok);
    assert.equal(bad.status, 'draft');
    const a = await s.t('POST', '/v1/automations', mk('dad@example.com'), s.tok);
    assert.equal(a.status, 'ready');
    await s.t('POST', `/v1/automations/${a.id}/test`, { live: true, confirm: true }, s.tok);
    assert.equal(s.f.gmailSent.length, 1);
    const mime = Buffer.from(s.f.gmailSent[0].raw, 'base64url').toString();
    assert.match(mime, /^To: dad@example.com\r\nSubject: Hi Dad/);
    assert.match(mime, /Good morning \(Monday\)/);
  } finally { s.close(); }
});

test('push: devices register; failures push with deep link; successes never push; prefs respected', async () => {
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const sa = JSON.stringify({ project_id: 'autometa-test', client_email: 'push@autometa-test.iam.gserviceaccount.com', private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }) });
  const s = await setup({ FCM_SERVICE_ACCOUNT_JSON: sa });
  try {
    assert.equal((await s.call('POST', '/v1/devices', { token: 'short' }, s.tok)).status, 422);
    const reg = await s.t('POST', '/v1/devices', { token: 'fcm-device-token-aaaaaaaaaaaaaaaa' }, s.tok);
    assert.equal(reg.pushConfigured, true);
    const tc = await s.t('POST', '/v1/connections', { integration: 'telegram', fields: { token: TG } }, s.tok);
    const a = await s.t('POST', '/v1/automations', { name: 'Ping', trigger: { integration: 'autometa', key: 'schedule', schedule: { times: ['07:00'] } }, steps: [{ id: 's1', type: 'action', integration: 'telegram', action: 'send_message', connectionId: tc.id, config: { chatId: '42', text: 'hi' } }] }, s.tok);
    await s.t('POST', `/v1/automations/${a.id}/activate`, {}, s.tok);
    s.clock.t = Date.parse('2026-10-05T06:00:10Z');
    await s.app.cloud.engine.drain();
    assert.equal(s.f.tg.length, 1);
    assert.equal(s.f.pushes.length, 0, 'success → no push');

    // Break the connection: next run fails with auth → push with reconnect deep link.
    s.app.db.prepare('UPDATE connections SET secret_enc = ? WHERE id = ?').run(null, tc.id);
    s.clock.t = Date.parse('2026-10-06T06:00:10Z');
    await s.app.cloud.engine.drain();
    assert.equal(s.f.pushes.length, 1);
    const m = s.f.pushes[0].message;
    assert.equal(m.token, 'fcm-device-token-aaaaaaaaaaaaaaaa');
    assert.ok(['reconnect', 'execution'].includes(m.data.actionType));
    assert.equal(m.data.automationId, a.id);

    // Opt out of failure pushes.
    await s.t('POST', '/v1/devices', { token: 'fcm-device-token-aaaaaaaaaaaaaaaa', prefs: { failures: false } }, s.tok);
    s.app.cloud.engine.notify(JSON.parse(JSON.stringify(s.app.db.prepare('SELECT workspace_id FROM automations').get())).workspace_id, { kind: 'automation_failed', severity: 'error', title: 'x', body: 'y' });
    await s.app.cloud.engine.flushPush();
    assert.equal(s.f.pushes.length, 1, 'preference respected');
    await s.t('DELETE', '/v1/devices', { token: 'fcm-device-token-aaaaaaaaaaaaaaaa' }, s.tok);
  } finally { s.close(); }
});

test('push without provider: notifications stored, push logged as not configured (no fake success)', async () => {
  const s = await setup();
  try {
    const reg = await s.t('POST', '/v1/devices', { token: 'fcm-device-token-bbbbbbbbbbbbbbbb' }, s.tok);
    assert.equal(reg.pushConfigured, false);
    const ws = s.app.db.prepare('SELECT id FROM workspaces').get().id;
    s.app.cloud.engine.notify(ws, { kind: 'automation_paused', severity: 'error', title: 'x', body: 'y' });
    await s.app.cloud.engine.flushPush();
    assert.equal(s.f.pushes.length, 0);
    assert.equal(s.app.db.prepare('SELECT status FROM push_log').get().status, 'not_configured');
  } finally { s.close(); }
});

test('conditions: eq / neq / contains / AND / OR, invalid variable, unsupported op, empty', async () => {
  const s = await setup();
  try {
    const tc = await s.t('POST', '/v1/connections', { integration: 'telegram', fields: { token: TG } }, s.tok);
    const wh = await s.t('POST', '/v1/webhooks', { name: 'In' }, s.tok);
    const r0 = (field, op, value) => ({ field, op, value });
    const r = r0;
    const mk = (cond) => ({ name: 'C', trigger: { integration: 'webhook', key: 'received', config: { webhookId: wh.id } }, steps: [{ id: 'c1', type: 'condition', ...cond }, { id: 's1', type: 'action', integration: 'telegram', action: 'send_message', connectionId: tc.id, config: { chatId: '42', text: 'ok' } }] });
    const base = await s.t('POST', '/v1/automations', mk({ rules: [r0('payload.x', 'eq', '1')] }), s.tok);
    const put = (cond) => s.t('PUT', `/v1/automations/${base.id}`, mk(cond), s.tok);
    const run = async (cond, payload) => {
      const a = await put(cond);
      assert.equal(a.status, 'ready', JSON.stringify(a.validation?.checks?.filter((c) => !c.ok)));
      return s.t('POST', `/v1/automations/${a.id}/test`, { payload }, s.tok);
    };
    assert.equal((await run({ rules: [r('payload.status', 'eq', 'PAID')] }, { status: 'paid' })).status, 'success');
    assert.equal((await run({ rules: [r('payload.status', 'neq', 'paid')] }, { status: 'paid' })).status, 'skipped');
    assert.equal((await run({ rules: [r('payload.note', 'contains', 'urgent')] }, { note: 'Very URGENT' })).status, 'success');
    const and = await run({ mode: 'all', rules: [r('payload.a', 'eq', '1'), r('payload.b', 'eq', '2')] }, { a: '1', b: '3' });
    assert.equal(and.status, 'skipped');
    assert.match(and.steps.find((x) => x.kind === 'condition').detail, /✓ .* AND ✕/);
    const or = await run({ mode: 'any', rules: [r('payload.a', 'eq', '1'), r('payload.b', 'eq', '2')] }, { a: '1', b: '3' });
    assert.equal(or.status, 'success');
    const missing = await run({ rules: [r('payload.nope', 'eq', 'x')] }, {});
    assert.match(missing.steps.find((x) => x.kind === 'condition').detail, /field not available in this run/);

    const check = async (cond) => (await put(cond)).validation.checks.filter((c) => !c.ok).map((c) => c.label).join(' | ');
    assert.match(await check({ rules: [r('emial.subject', 'eq', 'x')] }), /Unknown variable "emial.subject"/);
    assert.match(await check({ rules: [r('steps.s1.messageId', 'eq', 'x')] }), /doesn't run before/);
    assert.match(await check({ rules: [r('payload.a', 'regex', 'x')] }), /comparison "regex" isn't supported/);
    assert.match(await check({ rules: [] }), /add at least one condition/);
    assert.match(await check({ mode: 'xor', rules: [r('payload.a', 'eq', '1')] }), /match mode/);
    assert.match(await check({ rules: [r('payload.a', 'eq', '{{bogus}}')] }), /Unknown variable "bogus"/);
    assert.match(await check({ rules: [1, 2, 3, 4].map((i) => r(`payload.a${i}`, 'eq', '1')) }), /need Plus/);
  } finally { s.close(); }
});

test('canonical {{weekday}} (with {{day}} compatibility alias): validator → engine → result', async () => {
  const s = await setup(); // clock: Monday 2026-10-05, 06:50 Africa/Lagos
  try {
    const tc = await s.t('POST', '/v1/connections', { integration: 'telegram', fields: { token: TG } }, s.tok);
    const mk = (field, value, text) => ({ name: 'W', trigger: { integration: 'autometa', key: 'schedule', schedule: { times: ['18:00'] } },
      steps: [{ id: 'c1', type: 'condition', rules: [{ field, op: 'eq', value }] }, { id: 's1', type: 'action', integration: 'telegram', action: 'send_message', connectionId: tc.id, config: { chatId: '42', text } }] });
    const a = await s.t('POST', '/v1/automations', mk('weekday', 'Monday', 'Today is {{weekday}}'), s.tok);
    assert.equal(a.status, 'ready', JSON.stringify(a.validation?.checks?.filter((c) => !c.ok)));
    const out = async () => { const r = await s.t('POST', `/v1/automations/${a.id}/test`, {}, s.tok); return { status: r.status, text: r.steps.find((x) => x.stepId === 's1')?.output?.text }; };
    assert.deepEqual(await out(), { status: 'success', text: 'Today is Monday' });
    const legacy = await s.t('PUT', `/v1/automations/${a.id}`, mk('day', 'monday', 'Happy {{day}}'), s.tok);
    assert.equal(legacy.status, 'ready', 'legacy {{day}} is accepted as an alias');
    assert.deepEqual(await out(), { status: 'success', text: 'Happy Monday' });
    await s.t('PUT', `/v1/automations/${a.id}`, mk('weekday', 'Sunday', 'x'), s.tok);
    assert.equal((await s.t('POST', `/v1/automations/${a.id}/test`, {}, s.tok)).status, 'skipped');
    const bad = await s.t('PUT', `/v1/automations/${a.id}`, mk('day.name', 'x', 'x'), s.tok);
    assert.notEqual(bad.status, 'ready', 'only the bare alias is mapped');
  } finally { s.close(); }
});

test('/health exposes no secret values even when every secret is configured', async () => {
  const sa = JSON.stringify({ client_email: 'push@p.iam.gserviceaccount.com', private_key: 'PRIVATE-KEY-MATERIAL', project_id: 'p' });
  const secrets = { ...GOOGLE, FCM_SERVICE_ACCOUNT_JSON: sa, META_APP_SECRET: 'meta-app-secret-value', OPENAI_API_KEY: 'sk-test-secret', RESEND_API_KEY: 're_secret', WEBHOOK_VERIFY_TOKEN: 'verify-secret' };
  const s = await setup(secrets);
  try {
    const body = JSON.stringify(await s.t('GET', '/health'));
    for (const v of [BASE_ENV.SECRET_KEY, BASE_ENV.ADMIN_KEY, ...Object.values(secrets), 'PRIVATE-KEY-MATERIAL', 'push@p.iam']) {
      assert.ok(!body.includes(v), `health leaks ${v.slice(0, 12)}`);
    }
  } finally { s.close(); }
});
