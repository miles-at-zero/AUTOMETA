import http from 'node:http';
import { J, openDb, tx } from './db.js';
import { decrypt, encrypt, newCode, newId, newToken, normalizeCode, sha256, verifyMetaSignature } from './crypto.js';
import { FlowEngine, validateFlow } from './engine.js';
import { CloudApiSender, parseWebhook } from './whatsapp.js';
import { AiService } from './ai.js';
import { GooglePlayVerifier, saveSubscription } from './billing.js';
import { analytics } from './analytics.js';
import { TEMPLATES, STARTER_FAQS } from './templates.js';
import { FEATURES, PLANS } from './plans.js';
import { pricing } from './pricing.js';
import { can, describePlans, effectiveSubscription, planOf, PlanError, requireFeature, requireWithin } from './entitlements.js';
import { validateHours } from './hours.js';
import { createCloud } from './cloud/api.js';

class HttpError extends Error {
  constructor(status, message, extra = {}) { super(message); this.status = status; Object.assign(this, extra); }
}

const ROLE_PERMS = {
  owner: ['*'],
  admin: ['business.write', 'flows.write', 'faqs.write', 'team.write', 'inbox', 'customers.write', 'analytics', 'billing.view', 'ai', 'audit'],
  agent: ['inbox', 'customers.write', 'ai'],
};
const allowed = (member, perm) => ROLE_PERMS[member.role]?.some((p) => p === '*' || p === perm);
const WINDOW_MS = 24 * 3600e3;

export function createApp({ db = openDb(':memory:'), env = process.env, sender, clock = () => Date.now(), fetchImpl = globalThis.fetch } = {}) {
  const secret = env.SECRET_KEY || (env.NODE_ENV === 'production' ? null : 'dev-only-secret-key-change-me');
  if (!secret) throw new Error('SECRET_KEY is required in production');
  const tokenFor = (b) => (b.access_token_enc ? decrypt(b.access_token_enc, secret) : null);
  const waSender = sender || new CloudApiSender({ version: env.GRAPH_VERSION || 'v26.0', tokenFor, fetchImpl });

  const subOf = (accountId) => db.prepare('SELECT * FROM subscriptions WHERE account_id = ?').get(accountId);
  const planFor = (accountId) => effectiveSubscription(subOf(accountId), clock()).plan;
  const ai = new AiService({ db, planFor, env, fetchImpl, clock });
  const engine = new FlowEngine({ db, sender: waSender, clock, planFor, ai, fetchImpl });
  const play = new GooglePlayVerifier({ env, fetchImpl });
  const cloud = createCloud({ db, env, secret, clock, fetchImpl });

  const audit = (member, action, target, detail) => {
    db.prepare('INSERT INTO audit (account_id, member_id, action, target, detail, ts) VALUES (?,?,?,?,?,?)')
      .run(member.account_id, member.id, action, target ?? null, detail ? J.str(detail) : null, clock());
  };

  // ---------------------------------------------------------------- helpers
  function auth(req) {
    const h = req.headers.authorization || '';
    const token = h.startsWith('Bearer ') ? h.slice(7) : null;
    if (!token) throw new HttpError(401, 'Sign in required');
    const m = db.prepare('SELECT * FROM members WHERE token_hash = ? AND active = 1').get(sha256(token));
    if (!m) throw new HttpError(401, 'Session expired. Sign in again.');
    return m;
  }
  const need = (member, perm) => { if (!allowed(member, perm)) throw new HttpError(403, 'Your role can\'t do that'); };
  function ownBusiness(member, id) {
    const b = db.prepare('SELECT * FROM businesses WHERE id = ? AND account_id = ?').get(id, member.account_id);
    if (!b) throw new HttpError(404, 'Business not found');
    return b;
  }
  function ownCustomer(member, id) {
    const c = db.prepare('SELECT c.* FROM customers c JOIN businesses b ON b.id = c.business_id WHERE c.id = ? AND b.account_id = ?').get(id, member.account_id);
    if (!c) throw new HttpError(404, 'Customer not found');
    if (member.role === 'agent' && agentsRestricted(member) && c.assigned_to && c.assigned_to !== member.id) throw new HttpError(403, 'This conversation is assigned to someone else');
    return c;
  }
  function ownFlow(member, id) {
    const f = db.prepare('SELECT f.* FROM flows f JOIN businesses b ON b.id = f.business_id WHERE f.id = ? AND b.account_id = ?').get(id, member.account_id);
    if (!f) throw new HttpError(404, 'Workflow not found');
    return f;
  }
  const agentsRestricted = (member) => {
    if (!can(planFor(member.account_id), 'advancedPermissions')) return false;
    const b = db.prepare('SELECT settings FROM businesses WHERE account_id = ? LIMIT 1').get(member.account_id);
    return !!J.parse(b?.settings, {}).agentsSeeAssignedOnly;
  };
  const publicBusiness = (b) => ({
    id: b.id, name: b.name, timezone: b.timezone, phoneNumberId: b.phone_number_id, displayPhone: b.display_phone,
    connected: !!(b.phone_number_id && b.access_token_enc), hours: J.parse(b.hours, {}), settings: J.parse(b.settings, {}), createdAt: b.created_at,
  });
  const publicFlow = (f) => ({ id: f.id, businessId: f.business_id, name: f.name, enabled: !!f.enabled, priority: f.priority, trigger: J.parse(f.trigger, {}), nodes: J.parse(f.nodes, []), templateId: f.template_id, updatedAt: f.updated_at });
  const publicMember = (m) => ({ id: m.id, name: m.name, email: m.email, role: m.role, active: !!m.active, joined: !!m.token_hash });
  const publicCustomer = (c) => ({
    id: c.id, waId: c.wa_id, name: c.name, tags: J.parse(c.tags, []), fields: J.parse(c.fields, {}), category: c.category, status: c.status,
    assignedTo: c.assigned_to, firstSeen: c.first_seen, lastSeen: c.last_seen, lastInbound: c.last_inbound,
    canReply: !!c.last_inbound && clock() - c.last_inbound < WINDOW_MS,
  });

  function usage(accountId) {
    const n = (sql, ...a) => db.prepare(sql).get(...a).n;
    const plan = planFor(accountId);
    const flows = n('SELECT COUNT(*) n FROM flows f JOIN businesses b ON b.id=f.business_id WHERE b.account_id = ? AND f.enabled = 1', accountId);
    const u = {
      businesses: n('SELECT COUNT(*) n FROM businesses WHERE account_id = ?', accountId),
      members: n('SELECT COUNT(*) n FROM members WHERE account_id = ? AND active = 1', accountId),
      flows,
      faqs: n('SELECT COUNT(*) n FROM faqs f JOIN businesses b ON b.id=f.business_id WHERE b.account_id = ?', accountId),
      customers: n('SELECT COUNT(*) n FROM customers c JOIN businesses b ON b.id=c.business_id WHERE b.account_id = ? AND c.is_test = 0', accountId),
    };
    const limits = planOf(plan).limits;
    const overLimit = Object.fromEntries(Object.entries(u).filter(([k, v]) => limits[k] != null && v > limits[k]).map(([k, v]) => [k, { used: v, limit: limits[k] }]));
    return { ...u, limits, overLimit };
  }

  function createAccount({ accountName, ownerName, email = '', businessName, timezone = 'Africa/Lagos', notes = '' }) {
    if (!accountName || !ownerName || !businessName) throw new HttpError(400, 'Account name, your name and business name are required');
    return tx(db, () => {
      const accountId = newId('a_');
      const memberId = newId('u_');
      const businessId = newId('b_');
      const now = clock();
      db.prepare('INSERT INTO accounts (id, name, created_at, setup_notes) VALUES (?,?,?,?)').run(accountId, accountName, now, notes);
      db.prepare('INSERT INTO subscriptions (account_id, plan, status, source, updated_at) VALUES (?,?,?,?,?)').run(accountId, 'free', 'active', 'none', now);
      db.prepare('INSERT INTO members (id, account_id, name, email, role, created_at) VALUES (?,?,?,?,?,?)').run(memberId, accountId, ownerName, email, 'owner', now);
      db.prepare('INSERT INTO businesses (id, account_id, name, timezone, created_at) VALUES (?,?,?,?,?)').run(businessId, accountId, businessName, timezone, now);
      return { accountId, memberId, businessId };
    });
  }
  const issueToken = (memberId) => {
    const token = newToken();
    db.prepare('UPDATE members SET token_hash = ?, invite_code_hash = NULL WHERE id = ?').run(sha256(token), memberId);
    return token;
  };
  const issueCode = (accountId, memberId, days = 14) => {
    const code = newCode();
    db.prepare('INSERT INTO onboarding_codes (code_hash, account_id, member_id, expires_at) VALUES (?,?,?,?)').run(sha256(normalizeCode(code)), accountId, memberId, clock() + days * 864e5);
    return code;
  };

  // Valid on a higher plan but not this one → 402 upgrade prompt, not a 422.
  function checkFlow(flow, plan) {
    const v = validateFlow(flow, plan);
    if (v.ok) return v;
    const up = ['pro', 'business'].find((p) => PLANS[p] && validateFlow(flow, p).ok && p !== plan);
    if (up && Object.keys(PLANS).indexOf(up) > Object.keys(PLANS).indexOf(plan)) {
      throw new PlanError(`${v.errors[0]}. Upgrade to ${PLANS[up].name} to use it.`, { requiredPlan: up });
    }
    throw new HttpError(422, v.errors[0], { errors: v.errors, warnings: v.warnings });
  }
  function insertFlow(business, flow, plan, templateId = null) {
    const v = checkFlow(flow, plan);
    const id = newId('f_');
    const now = clock();
    db.prepare('INSERT INTO flows (id, business_id, name, enabled, priority, trigger, nodes, template_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)')
      .run(id, business.id, flow.name, flow.enabled === false ? 0 : 1, flow.priority ?? 100, J.str(flow.trigger), J.str(flow.nodes), templateId, now, now);
    return { id, warnings: v.warnings };
  }
  function applyTemplate(member, business, templateId, plan) {
    const t = TEMPLATES.find((x) => x.id === templateId);
    if (!t) throw new HttpError(404, 'Template not found');
    requireFeature(plan, t.requires);
    if (!['greeting', 'awayHours', 'handoff'].includes(t.requires)) requireFeature(plan, 'templates');
    requireWithin(plan, 'flows', usage(member.account_id).flows, 'workflows');
    return insertFlow(business, structuredClone(t.flow), plan, t.id);
  }

  async function testFlow(member, flowRow, messages) {
    const business = db.prepare('SELECT * FROM businesses WHERE id = ?').get(flowRow.business_id);
    const flow = publicFlow(flowRow);
    const waId = `test-${member.id}-${Date.now()}`;
    const transcript = [];
    // Run against a throwaway test customer with a capturing sender: nothing
    // reaches WhatsApp and nothing counts in analytics.
    const testEngine = new FlowEngine({ db, sender: { send: async () => ({ wamid: null }), sendTemplate: async () => ({ wamid: null }) }, clock, planFor, ai: null, fetchImpl });
    const { customer } = testEngine.upsertCustomer({ ...business, hours: J.parse(business.hours, {}), settings: J.parse(business.settings, {}) }, waId, member.name, true);
    let runId = null;
    try {
      for (const [i, text] of messages.entries()) {
        transcript.push({ from: 'customer', text });
        const ctx = { business: testEngine.business(business.id), customer: testEngine.customer(customer.id), replies: [], runs: [], test: true, inboundAt: clock() };
        const session = db.prepare('SELECT * FROM sessions WHERE customer_id = ?').get(customer.id);
        db.prepare('INSERT INTO messages (id, business_id, customer_id, direction, text, created_at) VALUES (?,?,?,?,?,?)').run(newId('m_'), business.id, customer.id, 'in', text, clock());
        if (session) await testEngine.resumeWithAnswer(ctx, session, text, null);
        else if (i === 0) await testEngine.startFlow(ctx, flow);
        else { transcript.push({ from: 'system', text: 'Workflow already finished. Later messages would go to other workflows.' }); break; }
        runId = ctx.runs[0]?.id || runId;
        for (const r of ctx.replies) transcript.push({ from: 'business', text: r });
      }
      const run = runId ? db.prepare('SELECT * FROM flow_runs WHERE id = ?').get(runId) : null;
      const vars = J.parse(db.prepare('SELECT vars FROM sessions WHERE customer_id = ?').get(customer.id)?.vars, {});
      const c = testEngine.customer(customer.id);
      return { transcript, status: run?.status || 'not_started', trace: J.parse(run?.trace, []), error: run?.error || null, waitingFor: vars, customerAfter: { tags: c.tags, fields: c.fields, status: c.status } };
    } finally {
      db.prepare('DELETE FROM flow_runs WHERE customer_id = ?').run(customer.id);
      db.prepare('DELETE FROM customers WHERE id = ?').run(customer.id);
    }
  }

  // ---------------------------------------------------------------- routes
  const routes = [];
  const route = (method, path, handler, opts = {}) => {
    const keys = [];
    const re = new RegExp(`^${path.replace(/:(\w+)/g, (_, k) => { keys.push(k); return '([^/]+)'; })}$`);
    routes.push({ method, re, keys, handler, ...opts });
  };

  route('GET', '/health', () => ({ ok: true, time: clock(), whatsapp: !!env.META_APP_SECRET, ai: ai.configured, googlePlay: play.configured, cloud: cloud.health() }), { public: true });
  route('GET', '/plans', () => ({ plans: describePlans(), features: FEATURES, pricing: pricing(env) }), { public: true });

  // --- WhatsApp webhook (Meta) ---
  route('GET', '/webhook', ({ query }) => {
    if (query.get('hub.mode') === 'subscribe' && env.WEBHOOK_VERIFY_TOKEN && query.get('hub.verify_token') === env.WEBHOOK_VERIFY_TOKEN) {
      return { __raw: query.get('hub.challenge') || '' };
    }
    throw new HttpError(403, 'Verification failed');
  }, { public: true });
  route('POST', '/webhook', async ({ raw, req }) => {
    if (!verifyMetaSignature(raw, req.headers['x-hub-signature-256'], env.META_APP_SECRET)) throw new HttpError(401, 'Bad signature');
    const { inbound, statuses } = parseWebhook(J.parse(raw.toString('utf8'), {}));
    const results = [];
    for (const m of inbound) {
      const b = db.prepare('SELECT id FROM businesses WHERE phone_number_id = ?').get(m.phoneNumberId);
      if (!b) { results.push('unknown_number'); continue; }
      try {
        const r = await engine.handleInbound({ businessId: b.id, waId: m.waId, name: m.name, text: m.text, replyId: m.replyId, wamid: m.wamid });
        results.push(r.skipped || 'handled');
      } catch (e) {
        results.push(`error: ${e.message}`);
      }
    }
    for (const s of statuses) {
      db.prepare('UPDATE messages SET status = ?, error = COALESCE(?, error) WHERE wamid = ?').run(s.status, s.error, s.wamid);
      if (s.status === 'failed') {
        const msg = db.prepare('SELECT business_id, customer_id, flow_id FROM messages WHERE wamid = ?').get(s.wamid);
        if (msg) db.prepare('INSERT INTO events (business_id, type, customer_id, flow_id, data, ts) VALUES (?,?,?,?,?,?)').run(msg.business_id, 'send_failed', msg.customer_id, msg.flow_id, J.str({ error: s.error }), clock());
      }
    }
    return { ok: true, results };
  }, { public: true, raw: true });

  // --- auth ---
  route('POST', '/auth/signup', ({ body }) => {
    if (env.ALLOW_SIGNUP === 'false') throw new HttpError(403, 'Sign-up is by invitation. Ask for a setup code.');
    const { accountId, memberId, businessId } = createAccount({ accountName: body.businessName, ownerName: body.name, email: body.email, businessName: body.businessName, timezone: body.timezone });
    return { token: issueToken(memberId), accountId, businessId };
  }, { public: true });
  route('POST', '/auth/redeem', ({ body }) => {
    const row = db.prepare('SELECT * FROM onboarding_codes WHERE code_hash = ?').get(sha256(normalizeCode(body.code)));
    if (row && !row.used && row.expires_at > clock()) {
      db.prepare('UPDATE onboarding_codes SET used = 1 WHERE code_hash = ?').run(row.code_hash);
      return { token: issueToken(row.member_id) };
    }
    const invite = db.prepare('SELECT * FROM members WHERE invite_code_hash = ? AND active = 1').get(sha256(normalizeCode(body.code)));
    if (invite) return { token: issueToken(invite.id) };
    throw new HttpError(400, 'That code is invalid or has expired');
  }, { public: true });

  route('GET', '/me', ({ member }) => {
    const account = db.prepare('SELECT id, name FROM accounts WHERE id = ?').get(member.account_id);
    const sub = effectiveSubscription(subOf(member.account_id), clock());
    const plan = planOf(sub.plan);
    return {
      member: publicMember(member), account, subscription: sub,
      plan: { id: plan.id, name: plan.name, features: plan.features, limits: plan.limits },
      permissions: ROLE_PERMS[member.role],
      businesses: db.prepare('SELECT * FROM businesses WHERE account_id = ? ORDER BY created_at').all(member.account_id).map(publicBusiness),
      usage: usage(member.account_id),
    };
  });

  // --- businesses ---
  route('POST', '/businesses', ({ member, body }) => {
    need(member, '*');
    const plan = planFor(member.account_id);
    if (usage(member.account_id).businesses >= 1) requireFeature(plan, 'multiBusiness');
    requireWithin(plan, 'businesses', usage(member.account_id).businesses, 'businesses');
    const id = newId('b_');
    db.prepare('INSERT INTO businesses (id, account_id, name, timezone, created_at) VALUES (?,?,?,?,?)').run(id, member.account_id, body.name || 'New business', body.timezone || 'Africa/Lagos', clock());
    audit(member, 'business.create', id);
    return publicBusiness(db.prepare('SELECT * FROM businesses WHERE id = ?').get(id));
  });
  route('GET', '/businesses/:id', ({ member, p }) => publicBusiness(ownBusiness(member, p.id)));
  route('PATCH', '/businesses/:id', ({ member, p, body }) => {
    need(member, 'business.write');
    const b = ownBusiness(member, p.id);
    if (body.hours) { const errs = validateHours(body.hours); if (errs.length) throw new HttpError(422, errs[0], { errors: errs }); }
    const settings = { ...J.parse(b.settings, {}), ...(body.settings || {}) };
    if (settings.agentsSeeAssignedOnly) requireFeature(planFor(member.account_id), 'advancedPermissions');
    db.prepare('UPDATE businesses SET name = ?, timezone = ?, hours = ?, settings = ? WHERE id = ?')
      .run(body.name ?? b.name, body.timezone ?? b.timezone, body.hours ? J.str(body.hours) : b.hours, J.str(settings), b.id);
    audit(member, 'business.update', b.id, Object.keys(body));
    return publicBusiness(db.prepare('SELECT * FROM businesses WHERE id = ?').get(b.id));
  });
  route('POST', '/businesses/:id/connect', async ({ member, p, body }) => {
    need(member, 'business.write');
    const b = ownBusiness(member, p.id);
    const phoneNumberId = String(body.phoneNumberId || '').trim();
    const token = String(body.accessToken || '').trim() || tokenFor(b);
    if (!/^\d{5,}$/.test(phoneNumberId)) throw new HttpError(422, 'Phone number ID should be the long number from Meta\'s API Setup page');
    if (!token) throw new HttpError(422, 'Paste your access token');
    const taken = db.prepare('SELECT id FROM businesses WHERE phone_number_id = ? AND id != ?').get(phoneNumberId, b.id);
    if (taken) throw new HttpError(409, 'That number is already connected to another business');
    let info = {};
    if (waSender.verify) {
      try { info = await waSender.verify(phoneNumberId, token); } catch (e) { throw new HttpError(422, `Meta rejected these details: ${e.message}`); }
    }
    db.prepare('UPDATE businesses SET phone_number_id = ?, access_token_enc = ?, display_phone = ? WHERE id = ?')
      .run(phoneNumberId, encrypt(token, secret), info.display_phone_number || body.displayPhone || '', b.id);
    audit(member, 'business.connect', b.id);
    return { ...publicBusiness(db.prepare('SELECT * FROM businesses WHERE id = ?').get(b.id)), verifiedName: info.verified_name || null, quality: info.quality_rating || null };
  });

  // --- flows ---
  route('GET', '/businesses/:id/flows', ({ member, p }) => {
    const b = ownBusiness(member, p.id);
    const limit = planOf(planFor(member.account_id)).limits.flows;
    return db.prepare('SELECT * FROM flows WHERE business_id = ? ORDER BY priority, created_at').all(b.id).map((f, i, all) => {
      const enabledIndex = all.filter((x) => x.enabled).indexOf(f);
      return { ...publicFlow(f), pausedByPlan: !!f.enabled && limit != null && enabledIndex >= limit,
        stats: db.prepare(`SELECT COUNT(*) runs, SUM(status='completed') completed, SUM(status='failed') failed FROM flow_runs WHERE flow_id = ? AND is_test = 0`).get(f.id) };
    });
  });
  route('POST', '/businesses/:id/flows', ({ member, p, body }) => {
    need(member, 'flows.write');
    const b = ownBusiness(member, p.id);
    const plan = planFor(member.account_id);
    requireWithin(plan, 'flows', usage(member.account_id).flows, 'workflows');
    const r = insertFlow(b, body, plan);
    audit(member, 'flow.create', r.id, { name: body.name });
    return { ...publicFlow(db.prepare('SELECT * FROM flows WHERE id = ?').get(r.id)), warnings: r.warnings };
  });
  route('POST', '/businesses/:id/flows/validate', ({ member, p, body }) => { ownBusiness(member, p.id); return validateFlow(body, planFor(member.account_id)); });
  route('GET', '/flows/:fid', ({ member, p }) => publicFlow(ownFlow(member, p.fid)));
  route('PUT', '/flows/:fid', ({ member, p, body }) => {
    need(member, 'flows.write');
    const f = ownFlow(member, p.fid);
    const plan = planFor(member.account_id);
    const merged = { name: body.name ?? f.name, trigger: body.trigger ?? J.parse(f.trigger, {}), nodes: body.nodes ?? J.parse(f.nodes, []) };
    const v = checkFlow(merged, plan);
    const enabling = body.enabled === true && !f.enabled;
    if (enabling) requireWithin(plan, 'flows', usage(member.account_id).flows, 'active workflows');
    db.prepare('UPDATE flows SET name = ?, trigger = ?, nodes = ?, enabled = ?, priority = ?, updated_at = ? WHERE id = ?')
      .run(merged.name, J.str(merged.trigger), J.str(merged.nodes), body.enabled == null ? f.enabled : body.enabled ? 1 : 0, body.priority ?? f.priority, clock(), f.id);
    audit(member, 'flow.update', f.id);
    return { ...publicFlow(db.prepare('SELECT * FROM flows WHERE id = ?').get(f.id)), warnings: v.warnings };
  });
  route('DELETE', '/flows/:fid', ({ member, p }) => {
    need(member, 'flows.write');
    const f = ownFlow(member, p.fid);
    db.prepare('DELETE FROM flows WHERE id = ?').run(f.id);
    db.prepare('DELETE FROM sessions WHERE flow_id = ?').run(f.id);
    audit(member, 'flow.delete', f.id, { name: f.name });
    return { ok: true };
  });
  route('POST', '/flows/:fid/test', async ({ member, p, body }) => {
    const f = ownFlow(member, p.fid);
    const msgs = (body.messages || []).map(String).slice(0, 40);
    if (!msgs.length) throw new HttpError(400, 'Type a message to test with');
    return testFlow(member, f, msgs);
  });

  // --- templates & FAQs ---
  route('GET', '/templates', ({ member }) => {
    const plan = planFor(member.account_id);
    return TEMPLATES.map((t) => ({ id: t.id, name: t.name, category: t.category, description: t.description, steps: t.flow.nodes.length,
      locked: !can(plan, t.requires) || (!['greeting', 'awayHours', 'handoff'].includes(t.requires) && !can(plan, 'templates')), flow: t.flow }));
  });
  route('POST', '/businesses/:id/templates/:tid', ({ member, p }) => {
    need(member, 'flows.write');
    const b = ownBusiness(member, p.id);
    const r = applyTemplate(member, b, p.tid, planFor(member.account_id));
    audit(member, 'flow.from_template', r.id, { template: p.tid });
    return publicFlow(db.prepare('SELECT * FROM flows WHERE id = ?').get(r.id));
  });
  route('GET', '/businesses/:id/faqs', ({ member, p }) => db.prepare('SELECT * FROM faqs WHERE business_id = ? ORDER BY rowid').all(ownBusiness(member, p.id).id).map((f) => ({ id: f.id, keywords: J.parse(f.keywords, []), answer: f.answer, hits: f.hits })));
  route('POST', '/businesses/:id/faqs', ({ member, p, body }) => {
    need(member, 'faqs.write');
    const b = ownBusiness(member, p.id);
    requireWithin(planFor(member.account_id), 'faqs', usage(member.account_id).faqs, 'FAQs');
    const kws = (body.keywords || []).map((k) => String(k).trim()).filter(Boolean);
    if (!kws.length || !String(body.answer || '').trim()) throw new HttpError(422, 'Add keywords and an answer');
    const id = newId('q_');
    db.prepare('INSERT INTO faqs (id, business_id, keywords, answer) VALUES (?,?,?,?)').run(id, b.id, J.str(kws), body.answer.trim());
    return { id, keywords: kws, answer: body.answer.trim(), hits: 0 };
  });
  route('PUT', '/faqs/:qid', ({ member, p, body }) => {
    need(member, 'faqs.write');
    const f = db.prepare('SELECT q.* FROM faqs q JOIN businesses b ON b.id=q.business_id WHERE q.id = ? AND b.account_id = ?').get(p.qid, member.account_id);
    if (!f) throw new HttpError(404, 'FAQ not found');
    db.prepare('UPDATE faqs SET keywords = ?, answer = ? WHERE id = ?').run(J.str(body.keywords ?? J.parse(f.keywords, [])), body.answer ?? f.answer, f.id);
    return { ok: true };
  });
  route('DELETE', '/faqs/:qid', ({ member, p }) => {
    need(member, 'faqs.write');
    db.prepare('DELETE FROM faqs WHERE id = ? AND business_id IN (SELECT id FROM businesses WHERE account_id = ?)').run(p.qid, member.account_id);
    return { ok: true };
  });

  // --- inbox / customers ---
  route('GET', '/businesses/:id/conversations', ({ member, p, query }) => {
    need(member, 'inbox');
    const b = ownBusiness(member, p.id);
    const status = query.get('status') || 'all';
    const q = `%${(query.get('q') || '').toLowerCase()}%`;
    const tag = query.get('tag');
    const mine = member.role === 'agent' && agentsRestricted(member);
    const rows = db.prepare(`SELECT c.*, (SELECT text FROM messages WHERE customer_id = c.id ORDER BY created_at DESC LIMIT 1) last_text,
        (SELECT direction FROM messages WHERE customer_id = c.id ORDER BY created_at DESC LIMIT 1) last_dir
      FROM customers c WHERE c.business_id = ? AND c.is_test = 0 ${status !== 'all' ? 'AND c.status = ?' : ''}
      AND (lower(c.name) LIKE ? OR c.wa_id LIKE ?) ${mine ? 'AND (c.assigned_to = ? OR c.assigned_to IS NULL)' : ''}
      ORDER BY CASE c.status WHEN 'needs_human' THEN 0 ELSE 1 END, c.last_seen DESC LIMIT 200`)
      .all(...[b.id, ...(status !== 'all' ? [status] : []), q, q, ...(mine ? [member.id] : [])]);
    return rows.filter((r) => !tag || J.parse(r.tags, []).includes(tag)).map((r) => ({ ...publicCustomer(r), lastText: r.last_text, lastDirection: r.last_dir }));
  });
  route('GET', '/customers/:cid', ({ member, p }) => {
    need(member, 'inbox');
    const c = ownCustomer(member, p.cid);
    return {
      ...publicCustomer(c),
      messages: db.prepare('SELECT id, direction, text, status, automated, flow_id flowId, member_id memberId, error, created_at createdAt FROM messages WHERE customer_id = ? ORDER BY created_at DESC LIMIT 200').all(c.id).reverse(),
      runs: db.prepare('SELECT r.id, r.status, r.error, r.started_at startedAt, f.name flow FROM flow_runs r LEFT JOIN flows f ON f.id = r.flow_id WHERE r.customer_id = ? ORDER BY r.started_at DESC LIMIT 20').all(c.id),
    };
  });
  route('PATCH', '/customers/:cid', ({ member, p, body }) => {
    need(member, 'customers.write');
    const c = ownCustomer(member, p.cid);
    const plan = planFor(member.account_id);
    if (body.tags) requireFeature(plan, 'tagging');
    if (body.assignedTo !== undefined) requireFeature(plan, 'team');
    if (body.fields) requireFeature(plan, 'customerCapture');
    const status = body.status ?? c.status;
    if (!['open', 'needs_human', 'closed'].includes(status)) throw new HttpError(422, 'Unknown status');
    db.prepare('UPDATE customers SET name = ?, tags = ?, fields = ?, status = ?, assigned_to = ? WHERE id = ?')
      .run(body.name ?? c.name, body.tags ? J.str(body.tags) : c.tags, body.fields ? J.str({ ...J.parse(c.fields, {}), ...body.fields }) : c.fields, status, body.assignedTo !== undefined ? body.assignedTo : c.assigned_to, c.id);
    if (status !== 'needs_human' && c.status === 'needs_human') db.prepare('DELETE FROM sessions WHERE customer_id = ?').run(c.id);
    audit(member, 'customer.update', c.id, Object.keys(body));
    return publicCustomer(db.prepare('SELECT * FROM customers WHERE id = ?').get(c.id));
  });
  route('POST', '/customers/:cid/reply', async ({ member, p, body }) => {
    need(member, 'inbox');
    const c = ownCustomer(member, p.cid);
    const text = String(body.text || '').trim();
    if (!text) throw new HttpError(400, 'Type a message');
    if (!c.last_inbound || clock() - c.last_inbound >= WINDOW_MS) throw new HttpError(422, 'More than 24 hours since the customer last wrote. WhatsApp only allows approved templates now.');
    const b = db.prepare('SELECT * FROM businesses WHERE id = ?').get(c.business_id);
    let wamid = null;
    let error = null;
    try { wamid = (await waSender.send(b, c.wa_id, { text }))?.wamid || null; } catch (e) { error = e.message; }
    db.prepare('INSERT INTO messages (id, business_id, customer_id, direction, text, wamid, status, automated, member_id, error, created_at) VALUES (?,?,?,?,?,?,?,0,?,?,?)')
      .run(newId('m_'), b.id, c.id, 'out', text, wamid, error ? 'failed' : 'sent', member.id, error, clock());
    if (error) throw new HttpError(502, `WhatsApp didn't accept the message: ${error}`);
    // First staff reply after a handoff/inbound → response time metric.
    const lastOut = db.prepare(`SELECT MAX(created_at) t FROM messages WHERE customer_id = ? AND direction='out' AND automated = 0 AND created_at < ?`).get(c.id, clock()).t;
    const since = c.handoff_at || c.last_inbound;
    if (since && (!lastOut || lastOut < since)) {
      db.prepare('INSERT INTO events (business_id, type, customer_id, value, ts) VALUES (?,?,?,?,?)').run(b.id, 'staff_reply', c.id, clock() - since, clock());
    }
    return { ok: true, wamid };
  });

  // --- runs (debugging) ---
  route('GET', '/businesses/:id/runs', ({ member, p, query }) => {
    const b = ownBusiness(member, p.id);
    const flow = query.get('flow');
    const status = query.get('status');
    return db.prepare(`SELECT r.id, r.flow_id flowId, f.name flow, r.customer_id customerId, c.name customer, c.wa_id waId, r.status, r.error, r.started_at startedAt, r.ended_at endedAt
      FROM flow_runs r LEFT JOIN flows f ON f.id = r.flow_id LEFT JOIN customers c ON c.id = r.customer_id
      WHERE r.business_id = ? AND r.is_test = 0 ${flow ? 'AND r.flow_id = ?' : ''} ${status ? 'AND r.status = ?' : ''} ORDER BY r.started_at DESC LIMIT 100`)
      .all(...[b.id, ...(flow ? [flow] : []), ...(status ? [status] : [])]);
  });
  route('GET', '/runs/:rid', ({ member, p }) => {
    const r = db.prepare('SELECT r.* FROM flow_runs r JOIN businesses b ON b.id = r.business_id WHERE r.id = ? AND b.account_id = ?').get(p.rid, member.account_id);
    if (!r) throw new HttpError(404, 'Run not found');
    return { id: r.id, flowId: r.flow_id, status: r.status, error: r.error, trace: J.parse(r.trace, []), startedAt: r.started_at, endedAt: r.ended_at };
  });

  // --- analytics ---
  route('GET', '/businesses/:id/analytics', ({ member, p, query }) => {
    need(member, 'analytics');
    const b = ownBusiness(member, p.id);
    const plan = planFor(member.account_id);
    requireFeature(plan, 'analytics');
    const days = Math.min(Math.max(Number(query.get('days')) || 30, 1), can(plan, 'advancedAnalytics') ? 365 : 30);
    return analytics(db, b.id, { days, now: clock(), advanced: can(plan, 'advancedAnalytics') });
  });

  // --- team ---
  route('GET', '/team', ({ member }) => db.prepare('SELECT * FROM members WHERE account_id = ? ORDER BY created_at').all(member.account_id).map(publicMember));
  route('POST', '/team', ({ member, body }) => {
    need(member, 'team.write');
    const plan = planFor(member.account_id);
    requireFeature(plan, 'team');
    requireWithin(plan, 'members', usage(member.account_id).members, 'team members');
    const role = ['admin', 'agent'].includes(body.role) ? body.role : 'agent';
    if (role === 'admin' && member.role !== 'owner') throw new HttpError(403, 'Only the owner can add admins');
    if (!String(body.name || '').trim()) throw new HttpError(422, 'Name is required');
    const id = newId('u_');
    const code = newCode();
    db.prepare('INSERT INTO members (id, account_id, name, email, role, invite_code_hash, created_at) VALUES (?,?,?,?,?,?,?)')
      .run(id, member.account_id, body.name.trim(), body.email || '', role, sha256(normalizeCode(code)), clock());
    audit(member, 'team.invite', id, { role });
    return { member: publicMember(db.prepare('SELECT * FROM members WHERE id = ?').get(id)), inviteCode: code };
  });
  route('PATCH', '/team/:mid', ({ member, p, body }) => {
    need(member, 'team.write');
    const m = db.prepare('SELECT * FROM members WHERE id = ? AND account_id = ?').get(p.mid, member.account_id);
    if (!m) throw new HttpError(404, 'Member not found');
    if (m.role === 'owner') throw new HttpError(403, 'The owner can\'t be changed here');
    if (body.role === 'admin' && member.role !== 'owner') throw new HttpError(403, 'Only the owner can make admins');
    db.prepare('UPDATE members SET role = ?, active = ? WHERE id = ?').run(body.role && ['admin', 'agent'].includes(body.role) ? body.role : m.role, body.active == null ? m.active : body.active ? 1 : 0, m.id);
    if (body.active === false) db.prepare('UPDATE members SET token_hash = NULL WHERE id = ?').run(m.id);
    audit(member, 'team.update', m.id, body);
    return publicMember(db.prepare('SELECT * FROM members WHERE id = ?').get(m.id));
  });

  // --- AI ---
  const aiGate = (member, business) => { need(member, 'ai'); requireFeature(planFor(member.account_id), 'ai'); return business; };
  route('POST', '/customers/:cid/ai/:task', async ({ member, p }) => {
    const c = ownCustomer(member, p.cid);
    const b = aiGate(member, db.prepare('SELECT * FROM businesses WHERE id = ?').get(c.business_id));
    const cust = { ...c, tags: J.parse(c.tags, []), fields: J.parse(c.fields, {}) };
    if (p.task === 'draft') return { text: await ai.draftReply(b, cust) };
    if (p.task === 'summary') return { text: await ai.summarize(b, cust) };
    if (p.task === 'followup') return { text: await ai.suggestFollowup(b, cust) };
    throw new HttpError(404, 'Unknown AI task');
  });
  route('POST', '/businesses/:id/ai/flow', async ({ member, p, body }) => aiGate(member, ownBusiness(member, p.id)) && ai.flowFromText(ownBusiness(member, p.id), body.description || ''));
  route('POST', '/businesses/:id/ai/faqs', async ({ member, p }) => ({ faqs: await ai.suggestFaqs(aiGate(member, ownBusiness(member, p.id))) }));
  route('GET', '/businesses/:id/ai/usage', ({ member, p }) => ({ ...ai.usage(ownBusiness(member, p.id)), configured: ai.configured }));

  // --- billing ---
  route('GET', '/billing', ({ member }) => ({ subscription: effectiveSubscription(subOf(member.account_id), clock()), plans: describePlans(), features: FEATURES, pricing: pricing(env), usage: usage(member.account_id), googlePlay: play.configured }));
  const verifyAndSave = async (member, token) => {
    const r = await play.verify(token);
    const owner = db.prepare('SELECT account_id FROM subscriptions WHERE purchase_token = ? AND account_id != ?').get(token, member.account_id);
    if (owner) throw new HttpError(409, 'This purchase belongs to another account');
    saveSubscription(db, member.account_id, { ...r, source: 'google_play', purchaseToken: token }, clock);
    audit(member, 'billing.google_play', null, { plan: r.plan, status: r.status });
    return effectiveSubscription(subOf(member.account_id), clock());
  };
  route('POST', '/billing/google/verify', async ({ member, body }) => { need(member, '*'); return { subscription: await verifyAndSave(member, String(body.purchaseToken || '')) }; });
  route('POST', '/billing/restore', async ({ member, body }) => {
    need(member, '*');
    let last = effectiveSubscription(subOf(member.account_id), clock());
    const errors = [];
    for (const t of (body.purchaseTokens || []).slice(0, 10)) {
      try { last = await verifyAndSave(member, String(t)); } catch (e) { errors.push(e.message); }
    }
    return { subscription: last, errors };
  });
  route('POST', '/billing/google/rtdn', async ({ body, query }) => {
    if (!env.RTDN_TOKEN || query.get('token') !== env.RTDN_TOKEN) throw new HttpError(403, 'Forbidden');
    const data = J.parse(Buffer.from(body?.message?.data || '', 'base64').toString('utf8'), {});
    const token = data?.subscriptionNotification?.purchaseToken;
    if (!token) return { ok: true, ignored: true };
    const row = db.prepare('SELECT account_id FROM subscriptions WHERE purchase_token = ?').get(token);
    if (!row) return { ok: true, unknown: true };
    const r = await play.verify(token);
    saveSubscription(db, row.account_id, { ...r, source: 'google_play', purchaseToken: token }, clock);
    return { ok: true };
  }, { public: true });

  route('GET', '/audit', ({ member }) => {
    need(member, 'audit');
    requireFeature(planFor(member.account_id), 'audit');
    return db.prepare('SELECT a.action, a.target, a.detail, a.ts, m.name member FROM audit a LEFT JOIN members m ON m.id = a.member_id WHERE a.account_id = ? ORDER BY a.ts DESC LIMIT 200').all(member.account_id)
      .map((r) => ({ ...r, detail: J.parse(r.detail, null) }));
  });

  // --- operator / setup service (X-Admin-Key) ---
  const adminRoute = (m, path, h) => route(m, path, h, { public: true });
  const adminOnly = (req) => { if (!env.ADMIN_KEY || req.headers['x-admin-key'] !== env.ADMIN_KEY) throw new HttpError(403, 'Admin key required'); };
  adminRoute('POST', '/admin/accounts', ({ req, body }) => {
    adminOnly(req);
    const ids = createAccount({ accountName: body.accountName || body.businessName, ownerName: body.ownerName, email: body.email, businessName: body.businessName, timezone: body.timezone, notes: body.notes });
    if (body.plan && body.plan !== 'free') {
      if (!PLANS[body.plan]) throw new HttpError(422, 'Unknown plan');
      saveSubscription(db, ids.accountId, { plan: body.plan, status: 'active', periodEnd: body.months ? clock() + body.months * 30 * 864e5 : null, source: 'manual' }, clock);
    }
    if (body.hours) db.prepare('UPDATE businesses SET hours = ? WHERE id = ?').run(J.str(body.hours), ids.businessId);
    const fakeMember = { id: ids.memberId, account_id: ids.accountId, role: 'owner', name: body.ownerName };
    const business = db.prepare('SELECT * FROM businesses WHERE id = ?').get(ids.businessId);
    const plan = planFor(ids.accountId);
    const applied = [];
    for (const t of body.templates || []) { try { applyTemplate(fakeMember, business, t, plan); applied.push(t); } catch (e) { applied.push(`${t}: ${e.message}`); } }
    if (body.starterFaqs) for (const f of STARTER_FAQS) db.prepare('INSERT INTO faqs (id, business_id, keywords, answer) VALUES (?,?,?,?)').run(newId('q_'), ids.businessId, J.str(f.keywords), f.answer);
    return { ...ids, onboardingCode: issueCode(ids.accountId, ids.memberId), templates: applied };
  });
  adminRoute('GET', '/admin/accounts', ({ req }) => {
    adminOnly(req);
    return db.prepare('SELECT a.id, a.name, a.setup_notes notes, a.created_at createdAt, s.plan, s.status, s.period_end periodEnd, s.source FROM accounts a LEFT JOIN subscriptions s ON s.account_id = a.id ORDER BY a.created_at DESC').all()
      .map((a) => ({ ...a, effective: effectiveSubscription(subOf(a.id), clock()).plan }));
  });
  adminRoute('POST', '/admin/accounts/:aid/subscription', ({ req, p, body }) => {
    adminOnly(req);
    if (!PLANS[body.plan]) throw new HttpError(422, 'Unknown plan');
    saveSubscription(db, p.aid, { plan: body.plan, status: body.status || 'active', periodEnd: body.months ? clock() + body.months * 30 * 864e5 : body.periodEnd ?? null, graceUntil: body.graceUntil ?? null, source: 'manual' }, clock);
    return effectiveSubscription(subOf(p.aid), clock());
  });
  adminRoute('POST', '/admin/accounts/:aid/code', ({ req, p }) => {
    adminOnly(req);
    const owner = db.prepare(`SELECT id FROM members WHERE account_id = ? AND role = 'owner'`).get(p.aid);
    if (!owner) throw new HttpError(404, 'Account not found');
    return { onboardingCode: issueCode(p.aid, owner.id) };
  });

  // ---------------------------------------------------------------- server
  async function handle(req, res) {
    const url = new URL(req.url, 'http://x');
    if (await cloud.handle(req, res, url)) return;
    const send = (status, body) => {
      if (body && body.__raw !== undefined) { res.writeHead(status, { 'content-type': 'text/plain' }); res.end(String(body.__raw)); return; }
      res.writeHead(status, { 'content-type': 'application/json', 'access-control-allow-origin': env.CORS_ORIGIN || '*', 'access-control-allow-headers': 'authorization, content-type, x-admin-key', 'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS' });
      res.end(JSON.stringify(body));
    };
    if (req.method === 'OPTIONS') return send(204, null);
    const r = routes.find((x) => x.method === req.method && x.re.test(url.pathname));
    if (!r) return send(404, { error: 'Not found' });
    try {
      const chunks = [];
      let size = 0;
      for await (const c of req) { size += c.length; if (size > 1e6) throw new HttpError(413, 'Body too large'); chunks.push(c); }
      const raw = Buffer.concat(chunks);
      const body = r.raw ? null : raw.length ? J.parse(raw.toString('utf8'), null) : {};
      if (!r.raw && body === null) throw new HttpError(400, 'Invalid JSON');
      const m = url.pathname.match(r.re);
      const p = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])]));
      const member = r.public ? null : auth(req);
      const out = await r.handler({ req, body, raw, p, query: url.searchParams, member });
      send(200, out ?? { ok: true });
    } catch (e) {
      if (e instanceof PlanError) return send(402, { error: e.message, code: e.code, feature: e.feature, limit: e.limit, requiredPlan: e.requiredPlan });
      const status = e.status || 500;
      if (status >= 500) console.error(e);
      send(status, { error: status >= 500 && !e.status ? 'Something went wrong' : e.message, ...(e.errors ? { errors: e.errors, warnings: e.warnings } : {}) });
    }
  }

  return { db, engine, ai, cloud, handle, server: () => http.createServer(handle), planFor };
}
