import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createApp } from '../src/app.js';
import { openDb } from '../src/db.js';
import { RecordingSender } from '../src/whatsapp.js';

const ENV = { ADMIN_KEY: 'adm', META_APP_SECRET: 'appsecret', WEBHOOK_VERIFY_TOKEN: 'vt', SECRET_KEY: 'k'.repeat(32) };

async function setup({ now = Date.parse('2026-10-05T10:00:00Z') } = {}) {
  const clock = { t: now };
  const sender = new RecordingSender();
  sender.verify = async () => ({ display_phone_number: '+234 800 000 0000', verified_name: 'Mama Put' });
  const app = createApp({ db: openDb(':memory:'), env: ENV, sender, clock: () => clock.t });
  const srv = app.server().listen(0);
  await new Promise((r) => srv.once('listening', r));
  const base = `http://127.0.0.1:${srv.address().port}`;
  const call = async (method, path, body, token, headers = {}) => {
    const res = await fetch(base + path, { method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body) });
    const txt = await res.text();
    let json; try { json = JSON.parse(txt); } catch { json = txt; }
    return { status: res.status, body: json };
  };
  const t = async (...a) => { const r = await call(...a); if (r.status !== 200) throw new Error(`${a[0]} ${a[1]} → ${r.status} ${JSON.stringify(r.body)}`); return r.body; };
  const close = () => srv.close();
  const webhook = async (payload, secret = ENV.META_APP_SECRET) => {
    const raw = JSON.stringify(payload);
    return call('POST', '/webhook', raw, null, { 'x-hub-signature-256': `sha256=${createHmac('sha256', secret).update(raw).digest('hex')}` });
  };
  let n = 0;
  const say = (from, text, extra = {}) => webhook({ entry: [{ changes: [{ value: { metadata: { phone_number_id: '1234567890' }, contacts: [{ wa_id: from, profile: { name: 'Ada' } }], messages: [{ from, id: `wamid.in${++n}`, type: 'text', text: { body: text }, ...extra }] } }] }] });
  return { app, sender, clock, call, t, close, webhook, say, base };
}

async function onboard(s, plan = 'pro', templates = []) {
  const acc = await s.t('POST', '/admin/accounts', { ownerName: 'Ngozi', businessName: 'Mama Put', plan, templates, starterFaqs: true }, null, { 'x-admin-key': 'adm' });
  const { token } = await s.t('POST', '/auth/redeem', { code: acc.onboardingCode });
  await s.t('POST', `/businesses/${acc.businessId}/connect`, { phoneNumberId: '1234567890', accessToken: 'EAAG-test' }, token);
  return { ...acc, token };
}

test('restaurant order template runs end to end over the webhook', async () => {
  const s = await setup();
  try {
    const { token, businessId } = await onboard(s, 'pro', ['restaurant_order', 'fallback']);
    assert.equal((await s.say('2348011111111', 'Hi, can I see the menu?')).status, 200);
    assert.match(s.sender.sent[0].text, /Our menu/);
    assert.deepEqual(s.sender.sent[1].choices.map((c) => c.title), ['Yes, order', 'Not now']);
    // Interactive button reply
    await s.webhook({ entry: [{ changes: [{ value: { metadata: { phone_number_id: '1234567890' }, messages: [{ from: '2348011111111', id: 'wamid.btn', type: 'interactive', interactive: { type: 'button_reply', button_reply: { id: s.sender.sent[1].choices[0].id, title: 'Yes, order' } } }] } }] }] });
    await s.say('2348011111111', 'Jollof rice');
    await s.say('2348011111111', 'lots');            // invalid number → re-asked
    assert.match(s.sender.sent.at(-1).text, /number|How many/i);
    await s.say('2348011111111', '2');
    await s.say('2348011111111', '1');               // choice by number → Delivery
    await s.say('2348011111111', '12 Aba Road, Port Harcourt');
    const summary = s.sender.sent.find((m) => /Order summary/.test(m.text || ''));
    assert.match(summary.text, /Jollof rice/);
    assert.match(summary.text, /Quantity: 2/);
    assert.match(summary.text, /12 Aba Road/);
    await s.say('2348011111111', 'Confirm');
    assert.match(s.sender.sent.at(-1).text, /order is in/);

    const convs = await s.t('GET', `/businesses/${businessId}/conversations?status=needs_human`, undefined, token);
    assert.equal(convs.length, 1);
    assert.deepEqual(convs[0].tags.sort(), ['customer', 'ordered']);
    assert.equal(convs[0].fields.address, '12 Aba Road, Port Harcourt');

    // Customer waits for a human → automation stays quiet
    const before = s.sender.sent.length;
    await s.say('2348011111111', 'hello?');
    assert.equal(s.sender.sent.length, before);

    // Staff replies, then resolves
    s.clock.t += 90_000;
    await s.t('POST', `/customers/${convs[0].id}/reply`, { text: 'Total is ₦7,000, 30 mins' }, token);
    await s.t('PATCH', `/customers/${convs[0].id}`, { status: 'open' }, token);

    const a = await s.t('GET', `/businesses/${businessId}/analytics`, undefined, token);
    assert.equal(a.totals.ordersStarted, 1);
    assert.equal(a.totals.ordersCompleted, 1);
    assert.equal(a.totals.handoffs, 1);
    assert.equal(a.orderConversion, 100);
    assert.ok(a.responseTimes.staffFirstReplyMs >= 90_000);
    assert.equal(a.topFlows[0].name, 'Food order');

    const runs = await s.t('GET', `/businesses/${businessId}/runs`, undefined, token);
    const run = await s.t('GET', `/runs/${runs[0].id}`, undefined, token);
    assert.equal(run.status, 'handoff');
    assert.ok(run.trace.some((st) => st.node === 'qty' && /retry|invalid/i.test(JSON.stringify(st))));
  } finally { s.close(); }
});

test('webhook rejects bad signatures and dedupes retries', async () => {
  const s = await setup();
  try {
    await onboard(s, 'free', ['greeting']);
    const payload = { entry: [{ changes: [{ value: { metadata: { phone_number_id: '1234567890' }, messages: [{ from: '234802', id: 'wamid.same', type: 'text', text: { body: 'hi' } }] } }] }] };
    assert.equal((await s.webhook(payload, 'wrong')).status, 401);
    await s.webhook(payload);
    await s.webhook(payload);
    assert.equal(s.sender.sent.length, 1);
    const v = await s.call('GET', '/webhook?hub.mode=subscribe&hub.verify_token=vt&hub.challenge=42');
    assert.equal(v.body, 42);
    assert.equal((await s.call('GET', '/webhook?hub.mode=subscribe&hub.verify_token=no&hub.challenge=42')).status, 403);
  } finally { s.close(); }
});

test('free plan gating, limits, and downgrade keeps data but pauses extras', async () => {
  const s = await setup();
  try {
    const { token, businessId, accountId } = await onboard(s, 'free');
    const tpl = await s.call('POST', `/businesses/${businessId}/templates/restaurant_order`, undefined, token);
    assert.equal(tpl.status, 402);
    assert.equal(tpl.body.requiredPlan, 'pro');
    assert.equal((await s.call('POST', '/team', { name: 'Tunde' }, token)).status, 402);
    assert.equal((await s.call('GET', `/businesses/${businessId}/analytics`, undefined, token)).status, 402);
    assert.equal((await s.call('POST', '/businesses', { name: 'Second' }, token)).status, 402);
    const question = { name: 'Q', trigger: { type: 'keyword', keywords: ['x'] }, nodes: [{ id: 'q', type: 'question', text: '?', input: 'text', saveAs: 'a' }] };
    const r = await s.call('POST', `/businesses/${businessId}/flows`, question, token);
    assert.equal(r.status, 402, 'question steps are a Pro feature');

    // Upgrade, add 5 flows, then downgrade
    await s.t('POST', `/admin/accounts/${accountId}/subscription`, { plan: 'pro', months: 1 }, null, { 'x-admin-key': 'adm' });
    for (let i = 0; i < 5; i++) await s.t('POST', `/businesses/${businessId}/flows`, { name: `K${i}`, trigger: { type: 'keyword', keywords: [`k${i}`] }, nodes: [{ id: 'm', type: 'message', text: `reply ${i}` }] }, token);
    s.clock.t += 40 * 864e5; // past period end + 7-day grace
    const me = await s.t('GET', '/me', undefined, token);
    assert.equal(me.plan.id, 'free');
    assert.ok(me.usage.overLimit.flows);
    const flows = await s.t('GET', `/businesses/${businessId}/flows`, undefined, token);
    assert.equal(flows.length, 5, 'nothing deleted');
    assert.ok(flows.some((f) => f.pausedByPlan));
    await s.say('234803', 'k4');
    assert.ok(!s.sender.sent.some((m) => m.text === 'reply 4'), 'flow beyond free limit does not run');
    await s.say('234804', 'k0');
    assert.ok(s.sender.sent.some((m) => m.text === 'reply 0'));
  } finally { s.close(); }
});

test('grace period keeps paid features', async () => {
  const s = await setup();
  try {
    const { token, accountId } = await onboard(s, 'free');
    await s.t('POST', `/admin/accounts/${accountId}/subscription`, { plan: 'business', status: 'grace', periodEnd: s.clock.t - 864e5, graceUntil: s.clock.t + 3 * 864e5 }, null, { 'x-admin-key': 'adm' });
    const me = await s.t('GET', '/me', undefined, token);
    assert.equal(me.plan.id, 'business');
    assert.equal(me.subscription.status, 'grace');
  } finally { s.close(); }
});

test('team roles: agent cannot edit flows; invite code redeems once', async () => {
  const s = await setup();
  try {
    const { token, businessId } = await onboard(s, 'pro');
    const inv = await s.t('POST', '/team', { name: 'Tunde', role: 'agent' }, token);
    const { token: agent } = await s.t('POST', '/auth/redeem', { code: inv.inviteCode });
    assert.equal((await s.call('POST', '/auth/redeem', { code: inv.inviteCode })).status, 400);
    assert.equal((await s.call('POST', `/businesses/${businessId}/flows`, { name: 'x', trigger: { type: 'keyword', keywords: ['a'] }, nodes: [{ id: 'm', type: 'message', text: 'a' }] }, agent)).status, 403);
    assert.equal((await s.call('GET', `/businesses/${businessId}/conversations`, undefined, agent)).status, 200);
    const team = await s.t('GET', '/team', undefined, token);
    await s.t('PATCH', `/team/${team[1].id}`, { active: false }, token);
    assert.equal((await s.call('GET', '/me', undefined, agent)).status, 401);
  } finally { s.close(); }
});

test('flow test runner replays a transcript without sending or polluting data', async () => {
  const s = await setup();
  try {
    const { token, businessId } = await onboard(s, 'pro', ['restaurant_order']);
    const [flow] = await s.t('GET', `/businesses/${businessId}/flows`, undefined, token);
    const r = await s.t('POST', `/flows/${flow.id}/test`, { messages: ['menu', 'Yes, order', 'Fried rice', '3', 'Pickup', 'Confirm ✅'] }, token);
    assert.equal(r.status, 'handoff', JSON.stringify(r.trace));
    assert.ok(r.transcript.some((m) => m.from === 'business' && /Quantity: 3/.test(m.text)));
    assert.equal(s.sender.sent.length, 0);
    assert.equal((await s.t('GET', `/businesses/${businessId}/conversations`, undefined, token)).length, 0);
    assert.equal((await s.t('GET', `/businesses/${businessId}/runs`, undefined, token)).length, 0);
    const bad = await s.call('PUT', `/flows/${flow.id}`, { nodes: [{ id: 'a', type: 'goto', to: 'missing' }] }, token);
    assert.equal(bad.status, 422);
  } finally { s.close(); }
});

test('FAQ, away hours and staff 24h window', async () => {
  const s = await setup();
  try {
    const { token, businessId } = await onboard(s, 'pro', ['away']);
    await s.t('PATCH', `/businesses/${businessId}`, { hours: { mon: [['09:00', '17:00']] } }, token);
    // 2026-10-05 is a Monday; 10:00Z = 11:00 Lagos → open → FAQ answers
    await s.say('234805', 'where are you located?');
    assert.match(s.sender.sent.at(-1).text, /We're at/);
    s.clock.t = Date.parse('2026-10-05T20:00:00Z'); // 21:00 Lagos, closed
    await s.say('234806', 'hello');
    assert.match(s.sender.sent.at(-1).text, /closed right now/);
    const [c] = (await s.t('GET', `/businesses/${businessId}/conversations`, undefined, token)).filter((x) => x.waId === '234806');
    s.clock.t += 25 * 3600e3;
    const late = await s.call('POST', `/customers/${c.id}/reply`, { text: 'hi' }, token);
    assert.equal(late.status, 422);
  } finally { s.close(); }
});

test('AI is gated to Business and reports when not configured', async () => {
  const s = await setup();
  try {
    const { token, businessId } = await onboard(s, 'pro');
    assert.equal((await s.call('POST', `/businesses/${businessId}/ai/flow`, { description: 'x' }, token)).status, 402);
  } finally { s.close(); }
  const s2 = await setup();
  try {
    const { token, businessId } = await onboard(s2, 'business');
    assert.equal((await s2.call('POST', `/businesses/${businessId}/ai/flow`, { description: 'x' }, token)).status, 503);
  } finally { s2.close(); }
});

test('access token is encrypted at rest and never returned', async () => {
  const s = await setup();
  try {
    const { token, businessId } = await onboard(s, 'free');
    const row = s.app.db.prepare('SELECT access_token_enc FROM businesses WHERE id = ?').get(businessId);
    assert.ok(row.access_token_enc && !row.access_token_enc.includes('EAAG'));
    const me = await s.call('GET', '/me', undefined, token);
    assert.ok(!JSON.stringify(me.body).includes('EAAG'));
  } finally { s.close(); }
});
