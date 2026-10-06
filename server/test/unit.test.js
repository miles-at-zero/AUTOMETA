import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isOpen, validateHours } from '../src/hours.js';
import { effectiveSubscription } from '../src/entitlements.js';
import { mapPlayState } from '../src/billing.js';
import { parseWebhook } from '../src/whatsapp.js';
import { validateFlow, FlowEngine } from '../src/engine.js';
import { openDb, J } from '../src/db.js';
import { RecordingSender } from '../src/whatsapp.js';

test('overnight hours and validation', () => {
  const h = { fri: [['18:00', '02:00']] };
  assert.equal(isOpen(h, 'Africa/Lagos', Date.parse('2026-10-02T22:00:00Z')), true);  // Fri 23:00
  assert.equal(isOpen(h, 'Africa/Lagos', Date.parse('2026-10-03T00:30:00Z')), true);  // Sat 01:30
  assert.equal(isOpen(h, 'Africa/Lagos', Date.parse('2026-10-03T02:00:00Z')), false); // Sat 03:00
  assert.ok(validateHours({ mon: [['25:00', '10:00']] }).length);
});

test('subscription states', () => {
  const now = 1e12;
  assert.equal(effectiveSubscription({ plan: 'pro', status: 'on_hold', period_end: now + 1 }, now).plan, 'free');
  assert.equal(effectiveSubscription({ plan: 'pro', status: 'canceled', period_end: now + 1 }, now).plan, 'pro');
  assert.equal(effectiveSubscription({ plan: 'pro', status: 'active', period_end: now - 1 }, now).status, 'grace');
  assert.equal(mapPlayState('SUBSCRIPTION_STATE_IN_GRACE_PERIOD'), 'grace');
});

test('webhook parse: list reply and failed status', () => {
  const r = parseWebhook({ entry: [{ changes: [{ value: { metadata: { phone_number_id: '9' },
    messages: [{ from: '1', id: 'w', type: 'interactive', interactive: { list_reply: { id: 'c2', title: 'Pickup' } } }],
    statuses: [{ id: 'x', status: 'failed', errors: [{ title: 'Re-engagement message' }] }] } }] }] });
  assert.equal(r.inbound[0].replyId, 'c2');
  assert.equal(r.statuses[0].error, 'Re-engagement message');
});

test('validator catches loops and unreachable steps', () => {
  const v = validateFlow({ name: 'x', trigger: { type: 'keyword', keywords: ['a'] }, nodes: [{ id: 'a', type: 'goto', to: 'b' }, { id: 'b', type: 'goto', to: 'a' }, { id: 'c', type: 'message', text: 'hi' }] });
  assert.equal(v.ok, false);
});

test('delay and no-reply follow-up run from the job queue', async () => {
  const db = openDb();
  const clock = { t: Date.parse('2026-10-05T10:00:00Z') };
  const sender = new RecordingSender();
  db.prepare("INSERT INTO accounts VALUES ('a','A',0,'')").run();
  db.prepare("INSERT INTO businesses (id, account_id, name, created_at) VALUES ('b','a','Shop',0)").run();
  const nodes = [{ id: 'm1', type: 'message', text: 'one' }, { id: 'd', type: 'delay', minutes: 10 }, { id: 'm2', type: 'message', text: 'two' }, { id: 'f', type: 'followup', minutes: 60, ifNoReply: true, text: 'still there?' }];
  db.prepare("INSERT INTO flows (id, business_id, name, trigger, nodes, created_at, updated_at) VALUES ('f','b','F',?,?,0,0)").run(J.str({ type: 'keyword', keywords: ['go'] }), J.str(nodes));
  const e = new FlowEngine({ db, sender, clock: () => clock.t, planFor: () => 'business' });
  await e.handleInbound({ businessId: 'b', waId: '1', text: 'go', wamid: 'w1' });
  assert.deepEqual(sender.sent.map((m) => m.text), ['one']);
  clock.t += 11 * 60e3; await e.processDueJobs();
  assert.deepEqual(sender.sent.map((m) => m.text), ['one', 'two']);
  clock.t += 61 * 60e3; await e.processDueJobs();
  assert.equal(sender.sent.at(-1).text, 'still there?');
});
