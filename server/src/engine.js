// Conversation workflow engine.
//
// A flow = trigger + ordered list of nodes. Each node runs, then moves to
// node.next, or (if unset) the next node in the list. Questions pause the
// flow until the customer answers; delays pause it until a job fires.
// Every run keeps a trace (node, outcome, detail) for debugging.
import { J } from './db.js';
import { newId } from './crypto.js';
import { isOpen } from './hours.js';
import { NODE_FEATURE, TRIGGER_FEATURE } from './plans.js';
import { can, planOf } from './entitlements.js';

export const NODE_TYPES = Object.keys(NODE_FEATURE);
export const TRIGGER_TYPES = Object.keys(TRIGGER_FEATURE);
const MAX_STEPS = 60;
const MAX_ATTEMPTS = 3;
const AWAY_COOLDOWN_MS = 12 * 3600e3;
const WINDOW_MS = 24 * 3600e3; // WhatsApp customer-service window
const CANCEL_WORDS = ['cancel', 'stop', 'restart', 'reset'];

export const norm = (s) => String(s ?? '').toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N}\s]/gu, ' ').replace(/\s+/g, ' ').trim();

export function keywordMatch(text, keywords = [], mode = 'contains') {
  const t = norm(text);
  if (!t) return false;
  return keywords.map(norm).filter(Boolean).some((k) =>
    mode === 'exact' ? t === k : mode === 'starts' ? t.startsWith(k) : (` ${t} `).includes(` ${k} `));
}

// ---------------------------------------------------------------- validation
export function validateFlow(flow, planId = 'business') {
  const errors = [];
  const warnings = [];
  const nodes = Array.isArray(flow?.nodes) ? flow.nodes : [];
  const trig = flow?.trigger || {};
  if (!flow?.name || !String(flow.name).trim()) errors.push('Give the workflow a name');
  if (!TRIGGER_TYPES.includes(trig.type)) errors.push(`Unknown trigger "${trig.type}"`);
  else if (!can(planId, TRIGGER_FEATURE[trig.type])) errors.push(`Trigger "${trig.type}" isn't included in ${planOf(planId).name}`);
  if ((trig.type === 'keyword' || trig.type === 'button') && !(trig.keywords || []).some((k) => norm(k))) errors.push('Add at least one keyword');
  if (nodes.length === 0) errors.push('Add at least one step');
  const limit = planOf(planId).limits.nodesPerFlow;
  if (limit != null && nodes.length > limit) errors.push(`${planOf(planId).name} allows ${limit} steps per workflow (this one has ${nodes.length})`);

  const ids = new Set();
  for (const n of nodes) {
    if (!n.id) errors.push('Every step needs an id');
    else if (ids.has(n.id)) errors.push(`Duplicate step id "${n.id}"`);
    ids.add(n.id);
  }
  const ref = (from, to, label) => { if (to != null && to !== '' && !ids.has(to)) errors.push(`Step "${from}" ${label} points to missing step "${to}"`); };
  nodes.forEach((n) => {
    const where = n.id || '?';
    if (!NODE_TYPES.includes(n.type)) { errors.push(`Step "${where}": unknown type "${n.type}"`); return; }
    if (!can(planId, NODE_FEATURE[n.type])) errors.push(`Step "${where}" (${n.type}) isn't included in ${planOf(planId).name}`);
    ref(where, n.next, 'next');
    switch (n.type) {
      case 'message': if (!String(n.text || '').trim()) errors.push(`Step "${where}": message is empty`); break;
      case 'question':
        if (!String(n.text || '').trim()) errors.push(`Step "${where}": question text is empty`);
        if (!n.saveAs || !/^[a-z_][a-z0-9_]*$/i.test(n.saveAs)) errors.push(`Step "${where}": "Save answer as" must be a simple name like item or quantity`);
        if ((n.input || 'text') === 'choice') {
          if (!(n.choices || []).length) errors.push(`Step "${where}": add choices`);
          (n.choices || []).forEach((c) => ref(where, c.next, `choice "${c.label}"`));
        }
        break;
      case 'condition':
        (n.rules || []).forEach((r, i) => ref(where, r.next, `rule ${i + 1}`));
        ref(where, n.else, 'else');
        break;
      case 'goto': if (!n.target) errors.push(`Step "${where}": choose where to go`); ref(where, n.target, 'goto'); break;
      case 'delay': case 'followup': if (!(Number(n.minutes) > 0)) errors.push(`Step "${where}": minutes must be more than 0`); break;
      case 'tag': if (!(n.tags || []).length) errors.push(`Step "${where}": add at least one tag`); break;
      case 'capture': if (!n.field) errors.push(`Step "${where}": choose a field`); break;
      case 'track': if (!n.event) errors.push(`Step "${where}": choose what to track`); break;
      case 'webhook': if (!/^https:\/\//.test(n.url || '')) errors.push(`Step "${where}": webhook URL must start with https://`); break;
      default: break;
    }
  });

  // Reachability + loops that never wait for the customer.
  if (!errors.length && nodes.length) {
    const byId = Object.fromEntries(nodes.map((n, i) => [n.id, i]));
    const succ = (n, i) => {
      if (['end', 'handoff'].includes(n.type)) return [];
      if (n.type === 'goto') return [n.target];
      const lin = n.next || nodes[i + 1]?.id;
      if (n.type === 'condition') return [...(n.rules || []).map((r) => r.next || lin), n.else || lin].filter(Boolean);
      if (n.type === 'question' && n.input === 'choice') return [...(n.choices || []).map((c) => c.next || lin)].filter(Boolean);
      return lin ? [lin] : [];
    };
    const seen = new Set();
    const stack = [nodes[0].id];
    while (stack.length) {
      const id = stack.pop();
      if (seen.has(id)) continue;
      seen.add(id);
      stack.push(...succ(nodes[byId[id]], byId[id]));
    }
    nodes.forEach((n) => { if (!seen.has(n.id)) warnings.push(`Step "${n.id}" can never be reached`); });
    // Cycle with no question/delay = infinite loop.
    const state = {};
    const visit = (id, path) => {
      const n = nodes[byId[id]];
      if (['question', 'delay'].includes(n.type)) return false;
      if (state[id] === 1) return true;
      if (state[id] === 2) return false;
      state[id] = 1;
      const loop = succ(n, byId[id]).some((s) => visit(s, path));
      state[id] = 2;
      return loop;
    };
    if (visit(nodes[0].id, [])) errors.push('This workflow can loop forever without waiting for the customer. Add a question or delay inside the loop.');
  }
  return { ok: errors.length === 0, errors, warnings };
}

// ---------------------------------------------------------------- engine
export class FlowEngine {
  /**
   * @param {object} o
   * @param {import('node:sqlite').DatabaseSync} o.db
   * @param {{send:Function, sendTemplate?:Function}} o.sender
   * @param {() => number} [o.clock]
   * @param {(accountId:string)=>string} o.planFor effective plan id
   * @param {object} [o.ai] AI service (optional)
   * @param {Function} [o.fetch] for webhook nodes
   */
  constructor({ db, sender, clock = () => Date.now(), planFor, ai = null, fetchImpl = globalThis.fetch }) {
    Object.assign(this, { db, sender, clock, planFor, ai, fetchImpl });
  }

  // ---------- persistence helpers
  business(id) {
    const b = this.db.prepare('SELECT * FROM businesses WHERE id = ?').get(id);
    if (!b) return null;
    return { ...b, hours: J.parse(b.hours, {}), settings: J.parse(b.settings, {}) };
  }
  customer(id) {
    const c = this.db.prepare('SELECT * FROM customers WHERE id = ?').get(id);
    return c ? { ...c, tags: J.parse(c.tags, []), fields: J.parse(c.fields, {}) } : null;
  }
  saveCustomer(c) {
    this.db.prepare(`UPDATE customers SET name=?, tags=?, fields=?, category=?, status=?, assigned_to=?, last_seen=?, last_inbound=?, away_sent_at=?, handoff_at=? WHERE id=?`)
      .run(c.name ?? '', J.str(c.tags), J.str(c.fields), c.category ?? '', c.status, c.assigned_to ?? null, c.last_seen, c.last_inbound ?? null, c.away_sent_at ?? null, c.handoff_at ?? null, c.id);
  }
  event(business, type, { customer, flowId, value, data } = {}) {
    if (customer?.is_test) return;
    this.db.prepare('INSERT INTO events (business_id, type, customer_id, flow_id, value, data, ts) VALUES (?,?,?,?,?,?,?)')
      .run(business.id, type, customer?.id ?? null, flowId ?? null, value ?? null, data ? J.str(data) : null, this.clock());
  }
  activeFlows(business) {
    const plan = this.planFor(business.account_id);
    const all = this.db.prepare('SELECT * FROM flows WHERE business_id = ? AND enabled = 1 ORDER BY priority ASC, created_at ASC').all(business.id)
      .map((f) => ({ ...f, trigger: J.parse(f.trigger, {}), nodes: J.parse(f.nodes, []) }));
    // Downgrade handling: extra flows stay saved but only the first N run.
    const limit = planOf(plan).limits.flows;
    return { plan, flows: limit == null ? all : all.slice(0, limit) };
  }
  flow(id) {
    const f = this.db.prepare('SELECT * FROM flows WHERE id = ?').get(id);
    return f ? { ...f, trigger: J.parse(f.trigger, {}), nodes: J.parse(f.nodes, []) } : null;
  }

  upsertCustomer(business, waId, name, isTest = false) {
    const now = this.clock();
    let c = this.db.prepare('SELECT id FROM customers WHERE business_id = ? AND wa_id = ?').get(business.id, waId);
    let isNew = false;
    if (!c) {
      const id = newId('c_');
      this.db.prepare('INSERT INTO customers (id, business_id, wa_id, name, first_seen, last_seen, is_test) VALUES (?,?,?,?,?,?,?)')
        .run(id, business.id, waId, name || '', now, now, isTest ? 1 : 0);
      c = { id };
      isNew = true;
      this.event(business, 'new_customer', { customer: { id, is_test: isTest } });
    }
    const cust = this.customer(c.id);
    if (name && !cust.name) cust.name = name;
    return { customer: cust, isNew };
  }

  // ---------- inbound entry point
  /**
   * Handles one incoming customer message. Idempotent on wamid.
   * @returns {Promise<{customer, replies: string[], runs: object[], skipped?: string}>}
   */
  async handleInbound({ businessId, waId, name = '', text = '', replyId = null, wamid = null, isTest = false }) {
    const business = this.business(businessId);
    if (!business) throw new Error('Unknown business');
    if (wamid && this.db.prepare('SELECT 1 FROM messages WHERE wamid = ?').get(wamid)) {
      return { customer: null, replies: [], runs: [], skipped: 'duplicate' };
    }
    const now = this.clock();
    const { customer, isNew } = this.upsertCustomer(business, waId, name, isTest);
    customer.last_seen = now;
    customer.last_inbound = now;
    this.saveCustomer(customer);
    this.db.prepare('INSERT INTO messages (id, business_id, customer_id, direction, text, wamid, created_at) VALUES (?,?,?,?,?,?,?)')
      .run(newId('m_'), business.id, customer.id, 'in', String(text), wamid, now);
    this.event(business, 'incoming', { customer });

    const ctx = { business, customer, replies: [], runs: [], inboundAt: now, test: isTest };
    // Rule-based categorisation (free, deterministic). AI can refine later.
    const cat = categorize(text);
    if (cat && customer.category !== cat) { customer.category = cat; this.saveCustomer(customer); }

    if (customer.status === 'needs_human') {
      this.event(business, 'waiting_human_message', { customer });
      return { customer, replies: [], runs: [], skipped: 'needs_human' };
    }

    const session = this.db.prepare('SELECT * FROM sessions WHERE customer_id = ?').get(customer.id);
    if (session && CANCEL_WORDS.includes(norm(text))) {
      this.endSession(customer.id, session.run_id, 'completed', 'Customer cancelled');
      await this.reply(ctx, business.settings.cancelText || 'Okay, cancelled. Send a message any time to start again.');
      return { customer, replies: ctx.replies, runs: ctx.runs };
    }
    if (session && session.waiting === 'answer') {
      await this.resumeWithAnswer(ctx, session, text, replyId);
      return { customer, replies: ctx.replies, runs: ctx.runs };
    }

    const { plan, flows } = this.activeFlows(business);
    const open = isOpen(business.hours, business.timezone, now);
    const hoursOk = (f) => !f.trigger.hours || f.trigger.hours === 'any' || (f.trigger.hours === 'open') === open;
    const usable = flows.filter((f) => can(plan, TRIGGER_FEATURE[f.trigger.type]) && hoursOk(f));

    let chosen = usable.find((f) => (f.trigger.type === 'keyword' || f.trigger.type === 'button')
      && (keywordMatch(text, f.trigger.keywords, f.trigger.match) || (replyId && (f.trigger.keywords || []).includes(replyId))));
    if (!chosen && isNew) chosen = usable.find((f) => f.trigger.type === 'greeting');
    if (!chosen && !open && (!customer.away_sent_at || now - customer.away_sent_at > AWAY_COOLDOWN_MS)) {
      chosen = usable.find((f) => f.trigger.type === 'away_hours');
      if (chosen) { customer.away_sent_at = now; this.saveCustomer(customer); }
    }
    if (!chosen && can(plan, 'faq')) {
      const faq = this.matchFaq(business, text, plan);
      if (faq) {
        this.db.prepare('UPDATE faqs SET hits = hits + 1 WHERE id = ?').run(faq.id);
        await this.reply(ctx, interpolate(faq.answer, ctx, {}));
        this.event(business, 'faq_answered', { customer, data: { faq: faq.id } });
        return { customer, replies: ctx.replies, runs: ctx.runs };
      }
    }
    if (!chosen) chosen = usable.find((f) => f.trigger.type === 'fallback');
    if (!chosen) return { customer, replies: [], runs: [], skipped: 'no_match' };

    await this.startFlow(ctx, chosen);
    return { customer, replies: ctx.replies, runs: ctx.runs };
  }

  matchFaq(business, text, plan) {
    const limit = planOf(plan).limits.faqs;
    const faqs = this.db.prepare('SELECT * FROM faqs WHERE business_id = ? ORDER BY rowid').all(business.id).slice(0, limit ?? undefined);
    let best = null;
    let bestScore = 0;
    for (const f of faqs) {
      const kws = J.parse(f.keywords, []);
      const score = kws.filter((k) => keywordMatch(text, [k])).length;
      if (score > bestScore) { best = f; bestScore = score; }
    }
    return best;
  }

  async startFlow(ctx, flow) {
    const runId = newId('r_');
    this.db.prepare('INSERT INTO flow_runs (id, business_id, flow_id, customer_id, status, is_test, started_at) VALUES (?,?,?,?,?,?,?)')
      .run(runId, ctx.business.id, flow.id, ctx.customer.id, 'running', ctx.test ? 1 : 0, this.clock());
    this.event(ctx.business, 'flow_started', { customer: ctx.customer, flowId: flow.id });
    const run = { id: runId, flow, vars: {}, trace: [] };
    ctx.runs.push(run);
    await this.execute(ctx, run, flow.nodes[0]?.id);
  }

  async resumeWithAnswer(ctx, session, text, replyId) {
    const flow = this.flow(session.flow_id);
    const run = { id: session.run_id, flow, vars: J.parse(session.vars, {}), trace: this.loadTrace(session.run_id) };
    ctx.runs.push(run);
    if (!flow) { this.endSession(ctx.customer.id, session.run_id, 'failed', 'Workflow was deleted'); return; }
    const idx = flow.nodes.findIndex((n) => n.id === session.node_id);
    const node = flow.nodes[idx];
    if (!node || node.type !== 'question') { this.endSession(ctx.customer.id, session.run_id, 'failed', 'Question step no longer exists'); return; }

    const parsed = parseAnswer(node, text, replyId);
    if (!parsed.ok) {
      const attempts = session.attempts + 1;
      run.trace.push({ node: node.id, type: 'question', outcome: 'invalid', detail: `"${text}" → ${parsed.reason}` });
      if (attempts >= (node.maxAttempts || MAX_ATTEMPTS)) {
        await this.reply(ctx, node.giveUpText || 'Sorry, I didn\'t get that. A team member will help you.');
        this.setHandoff(ctx, flow.id, 'Customer could not answer a question');
        this.endSession(ctx.customer.id, run.id, 'handoff', null, run.trace);
        return;
      }
      this.db.prepare('UPDATE sessions SET attempts = ?, updated_at = ? WHERE customer_id = ?').run(attempts, this.clock(), ctx.customer.id);
      await this.reply(ctx, node.invalidText || parsed.reason);
      await this.askQuestion(ctx, run, node, { repeat: true });
      this.saveTrace(run);
      return;
    }
    run.vars[node.saveAs] = parsed.value;
    if (parsed.label != null) run.vars[`${node.saveAs}_label`] = parsed.label;
    if (node.saveToCustomer) { ctx.customer.fields[node.saveAs] = parsed.label ?? parsed.value; this.saveCustomer(ctx.customer); }
    run.trace.push({ node: node.id, type: 'question', outcome: 'answered', detail: `${node.saveAs} = ${parsed.label ?? parsed.value}` });
    this.db.prepare('DELETE FROM sessions WHERE customer_id = ?').run(ctx.customer.id);
    const next = parsed.next || node.next || flow.nodes[idx + 1]?.id || null;
    await this.execute(ctx, run, next);
  }

  async resumeAfterDelay(job) {
    const p = J.parse(job.payload, {});
    const session = this.db.prepare('SELECT * FROM sessions WHERE customer_id = ?').get(job.customer_id);
    if (!session || session.run_id !== p.runId || session.waiting !== 'delay') return 'stale';
    const customer = this.customer(job.customer_id);
    const business = this.business(job.business_id);
    if (!customer || !business) return 'stale';
    if (customer.status === 'needs_human') { this.endSession(customer.id, session.run_id, 'handoff', 'Handed to staff during delay'); return 'stale'; }
    const flow = this.flow(session.flow_id);
    const ctx = { business, customer, replies: [], runs: [], test: !!customer.is_test };
    const run = { id: session.run_id, flow, vars: J.parse(session.vars, {}), trace: this.loadTrace(session.run_id) };
    this.db.prepare('DELETE FROM sessions WHERE customer_id = ?').run(customer.id);
    run.trace.push({ node: session.node_id, type: 'delay', outcome: 'resumed' });
    await this.execute(ctx, run, p.next);
    return 'resumed';
  }

  // ---------- node execution
  async execute(ctx, run, startId) {
    const { flow } = run;
    const plan = this.planFor(ctx.business.account_id);
    const index = Object.fromEntries(flow.nodes.map((n, i) => [n.id, i]));
    const linear = (i) => flow.nodes[i + 1]?.id || null;
    let id = startId;
    let steps = 0;
    try {
      while (id) {
        if (++steps > MAX_STEPS) throw new Error('Too many steps in one go (possible loop)');
        const i = index[id];
        const node = flow.nodes[i];
        if (!node) throw new Error(`Missing step "${id}"`);
        const nextDefault = node.next || linear(i);
        if (!can(plan, NODE_FEATURE[node.type])) {
          run.trace.push({ node: node.id, type: node.type, outcome: 'skipped', detail: `Not in ${planOf(plan).name} plan` });
          id = nextDefault;
          continue;
        }
        switch (node.type) {
          case 'message':
            await this.reply(ctx, interpolate(node.text, ctx, run.vars), flow.id);
            run.trace.push({ node: node.id, type: 'message', outcome: 'sent' });
            id = nextDefault;
            break;
          case 'question':
            await this.askQuestion(ctx, run, node);
            this.db.prepare(`INSERT OR REPLACE INTO sessions (customer_id, flow_id, run_id, node_id, vars, waiting, attempts, updated_at) VALUES (?,?,?,?,?,?,0,?)`)
              .run(ctx.customer.id, flow.id, run.id, node.id, J.str(run.vars), 'answer', this.clock());
            run.trace.push({ node: node.id, type: 'question', outcome: 'waiting', detail: 'Waiting for the customer\'s answer' });
            this.updateRun(run, 'waiting');
            return;
          case 'condition': {
            const matched = (node.rules || []).find((r) => this.evalRule(r.if || {}, ctx, run.vars));
            run.trace.push({ node: node.id, type: 'condition', outcome: matched ? 'matched' : 'else', detail: matched ? describeRule(matched.if) : 'No rule matched' });
            id = matched ? matched.next || nextDefault : node.else || nextDefault;
            break;
          }
          case 'delay': {
            const due = this.clock() + Number(node.minutes) * 60e3;
            if (ctx.test) {
              run.trace.push({ node: node.id, type: 'delay', outcome: 'skipped_in_test', detail: `Would wait ${node.minutes} min` });
              id = nextDefault;
              break;
            }
            this.db.prepare(`INSERT OR REPLACE INTO sessions (customer_id, flow_id, run_id, node_id, vars, waiting, attempts, updated_at) VALUES (?,?,?,?,?,?,0,?)`)
              .run(ctx.customer.id, flow.id, run.id, node.id, J.str(run.vars), 'delay', this.clock());
            this.addJob(ctx, 'resume', due, { runId: run.id, next: nextDefault });
            run.trace.push({ node: node.id, type: 'delay', outcome: 'waiting', detail: `Resumes in ${node.minutes} min` });
            this.updateRun(run, 'waiting');
            return;
          }
          case 'tag': {
            const before = new Set(ctx.customer.tags);
            for (const t of node.tags || []) before.add(String(t).trim());
            if (node.remove) for (const t of node.remove) before.delete(t);
            ctx.customer.tags = [...before].filter(Boolean);
            this.saveCustomer(ctx.customer);
            run.trace.push({ node: node.id, type: 'tag', outcome: 'tagged', detail: (node.tags || []).join(', ') });
            id = nextDefault;
            break;
          }
          case 'capture': {
            const value = interpolate(node.value ?? `{{${node.field}}}`, ctx, run.vars);
            if (node.field === 'name') ctx.customer.name = value;
            else ctx.customer.fields[node.field] = value;
            this.saveCustomer(ctx.customer);
            if (node.lead) this.event(ctx.business, 'lead_captured', { customer: ctx.customer, flowId: flow.id });
            run.trace.push({ node: node.id, type: 'capture', outcome: 'saved', detail: `${node.field} = ${value}` });
            id = nextDefault;
            break;
          }
          case 'track':
            this.event(ctx.business, node.event, { customer: ctx.customer, flowId: flow.id, value: node.value != null ? Number(interpolate(String(node.value), ctx, run.vars)) || null : null, data: { vars: run.vars } });
            run.trace.push({ node: node.id, type: 'track', outcome: 'tracked', detail: node.event });
            id = nextDefault;
            break;
          case 'assign': {
            const member = this.pickMember(ctx.business, node.to);
            if (member) { ctx.customer.assigned_to = member.id; this.saveCustomer(ctx.customer); }
            run.trace.push({ node: node.id, type: 'assign', outcome: member ? 'assigned' : 'no_staff', detail: member?.name || 'No active staff to assign' });
            id = nextDefault;
            break;
          }
          case 'followup':
            if (!ctx.test) this.addJob(ctx, 'followup', this.clock() + Number(node.minutes) * 60e3, {
              text: interpolate(node.text || '', ctx, run.vars), template: node.template || null, ifNoReply: node.ifNoReply !== false, flowId: flow.id,
            });
            run.trace.push({ node: node.id, type: 'followup', outcome: ctx.test ? 'skipped_in_test' : 'scheduled', detail: `In ${node.minutes} min${node.ifNoReply !== false ? ' if no reply' : ''}` });
            id = nextDefault;
            break;
          case 'handoff':
            if (node.text) await this.reply(ctx, interpolate(node.text, ctx, run.vars), flow.id);
            this.setHandoff(ctx, flow.id, node.reason || 'Workflow handoff');
            run.trace.push({ node: node.id, type: 'handoff', outcome: 'handed_off', detail: node.reason || '' });
            this.updateRun(run, 'handoff');
            return;
          case 'goto':
            run.trace.push({ node: node.id, type: 'goto', outcome: 'jump', detail: node.target });
            id = node.target;
            break;
          case 'ai_reply': {
            let text = node.fallbackText || '';
            if (this.ai) {
              try { text = await this.ai.draftReply(ctx.business, ctx.customer, { instructions: node.instructions }) || text; } catch (e) { run.trace.push({ node: node.id, type: 'ai_reply', outcome: 'ai_unavailable', detail: e.message }); }
            }
            if (text) await this.reply(ctx, text, flow.id);
            run.trace.push({ node: node.id, type: 'ai_reply', outcome: text ? 'sent' : 'nothing_to_send' });
            id = nextDefault;
            break;
          }
          case 'webhook': {
            let outcome = 'skipped_in_test';
            if (!ctx.test) {
              try {
                const res = await this.fetchImpl(node.url, {
                  method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(5000),
                  body: J.str({ business: ctx.business.name, customer: { wa_id: ctx.customer.wa_id, name: ctx.customer.name, tags: ctx.customer.tags, fields: ctx.customer.fields }, vars: run.vars, flow: flow.name }),
                });
                outcome = `HTTP ${res.status}`;
              } catch (e) { outcome = `failed: ${e.message}`; }
            }
            run.trace.push({ node: node.id, type: 'webhook', outcome });
            id = nextDefault;
            break;
          }
          case 'end':
            run.trace.push({ node: node.id, type: 'end', outcome: 'ended' });
            id = null;
            break;
          default:
            throw new Error(`Unknown step type ${node.type}`);
        }
      }
      this.updateRun(run, 'completed');
      this.event(ctx.business, 'flow_completed', { customer: ctx.customer, flowId: flow.id });
    } catch (e) {
      run.trace.push({ node: id, outcome: 'error', detail: e.message });
      this.updateRun(run, 'failed', e.message);
      this.db.prepare('DELETE FROM sessions WHERE customer_id = ?').run(ctx.customer.id);
      this.event(ctx.business, 'flow_failed', { customer: ctx.customer, flowId: flow.id, data: { error: e.message } });
    }
  }

  async askQuestion(ctx, run, node, { repeat = false } = {}) {
    const choices = (node.input === 'choice') ? (node.choices || []).map((c, i) => ({ id: String(c.value ?? i + 1), title: c.label })) : null;
    await this.reply(ctx, interpolate(node.text, ctx, run.vars), run.flow.id, choices);
    if (repeat) return;
  }

  evalRule(rule, ctx, vars) {
    const kind = rule.kind || 'var';
    switch (kind) {
      case 'business_hours': {
        const open = isOpen(ctx.business.hours, ctx.business.timezone, this.clock());
        return rule.value === 'closed' ? !open : open;
      }
      case 'tag': return ctx.customer.tags.includes(rule.value);
      case 'new_customer': return ctx.customer.first_seen >= this.clock() - 60e3;
      case 'var': default: {
        const raw = rule.var in vars ? vars[rule.var] : ctx.customer.fields[rule.var];
        const a = raw == null ? '' : String(raw);
        const b = String(interpolate(String(rule.value ?? ''), ctx, vars));
        switch (rule.op || 'eq') {
          case 'eq': return norm(a) === norm(b);
          case 'neq': return norm(a) !== norm(b);
          case 'contains': return keywordMatch(a, b.split(','));
          case 'gt': return Number(a) > Number(b);
          case 'lt': return Number(a) < Number(b);
          case 'gte': return Number(a) >= Number(b);
          case 'lte': return Number(a) <= Number(b);
          case 'exists': return a.trim() !== '';
          case 'empty': return a.trim() === '';
          default: return false;
        }
      }
    }
  }

  pickMember(business, to) {
    const members = this.db.prepare(`SELECT * FROM members WHERE account_id = ? AND active = 1 AND token_hash IS NOT NULL ORDER BY created_at`).all(business.account_id);
    if (!members.length) return null;
    if (to && to !== 'round_robin') return members.find((m) => m.id === to) || null;
    const agents = members.filter((m) => m.role !== 'owner');
    const pool = agents.length ? agents : members;
    const load = (m) => this.db.prepare(`SELECT COUNT(*) n FROM customers WHERE assigned_to = ? AND status != 'closed'`).get(m.id).n;
    return pool.reduce((best, m) => (load(m) < load(best) ? m : best), pool[0]);
  }

  setHandoff(ctx, flowId, reason) {
    ctx.customer.status = 'needs_human';
    ctx.customer.handoff_at = this.clock();
    if (!ctx.customer.assigned_to) {
      const m = this.pickMember(ctx.business, 'round_robin');
      if (m && m.role !== 'owner') ctx.customer.assigned_to = m.id;
    }
    this.saveCustomer(ctx.customer);
    this.event(ctx.business, 'handoff', { customer: ctx.customer, flowId, data: { reason } });
  }

  addJob(ctx, kind, due, payload) {
    this.db.prepare('INSERT INTO jobs (id, business_id, customer_id, kind, due_at, payload) VALUES (?,?,?,?,?,?)')
      .run(newId('j_'), ctx.business.id, ctx.customer.id, kind, due, J.str({ ...payload, createdAt: this.clock() }));
  }

  /** Runs due delay-resumes and follow-ups. Called by the scheduler tick. */
  async processDueJobs() {
    const due = this.db.prepare('SELECT * FROM jobs WHERE done = 0 AND due_at <= ? ORDER BY due_at LIMIT 200').all(this.clock());
    const results = [];
    for (const job of due) {
      this.db.prepare('UPDATE jobs SET done = 1 WHERE id = ?').run(job.id);
      try {
        if (job.kind === 'resume') results.push(await this.resumeAfterDelay(job));
        else if (job.kind === 'followup') results.push(await this.runFollowup(job));
      } catch (e) {
        results.push(`error: ${e.message}`);
      }
    }
    return results;
  }

  async runFollowup(job) {
    const p = J.parse(job.payload, {});
    const customer = this.customer(job.customer_id);
    const business = this.business(job.business_id);
    if (!customer || !business) return 'stale';
    if (p.ifNoReply && customer.last_inbound && customer.last_inbound > p.createdAt) return 'customer_replied';
    const ctx = { business, customer, replies: [], runs: [], test: !!customer.is_test };
    const insideWindow = customer.last_inbound && this.clock() - customer.last_inbound < WINDOW_MS;
    if (insideWindow && p.text) {
      await this.reply(ctx, p.text, p.flowId);
    } else if (p.template && this.sender.sendTemplate) {
      await this.sendSafely(ctx, () => this.sender.sendTemplate(business, customer.wa_id, p.template), `[template: ${p.template}]`, p.flowId);
    } else {
      this.event(business, 'followup_skipped', { customer, flowId: p.flowId, data: { reason: 'Outside WhatsApp 24-hour window and no approved template set' } });
      return 'outside_window';
    }
    this.event(business, 'followup_sent', { customer, flowId: p.flowId });
    return 'sent';
  }

  // ---------- sending
  async reply(ctx, text, flowId = null, choices = null) {
    if (!text) return;
    ctx.replies.push(choices ? `${text}\n${choices.map((c, i) => `  ${i + 1}. ${c.title}`).join('\n')}` : text);
    await this.sendSafely(ctx, () => this.sender.send(ctx.business, ctx.customer.wa_id, { text, choices }), text, flowId);
    const started = ctx.inboundAt;
    this.event(ctx.business, 'auto_reply', { customer: ctx.customer, flowId, value: started ? this.clock() - started : null });
  }

  async sendSafely(ctx, fn, text, flowId) {
    let wamid = null;
    let error = null;
    try {
      const r = await fn();
      wamid = r?.wamid || null;
    } catch (e) {
      error = e.message;
      this.event(ctx.business, 'send_failed', { customer: ctx.customer, flowId, data: { error } });
    }
    this.db.prepare('INSERT INTO messages (id, business_id, customer_id, direction, text, wamid, status, automated, flow_id, error, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)')
      .run(newId('m_'), ctx.business.id, ctx.customer.id, 'out', text, wamid, error ? 'failed' : 'sent', 1, flowId, error, this.clock());
    if (error) throw Object.assign(new Error(`WhatsApp send failed: ${error}`), { sendFailure: true });
  }

  // ---------- run bookkeeping
  loadTrace(runId) {
    return J.parse(this.db.prepare('SELECT trace FROM flow_runs WHERE id = ?').get(runId)?.trace, []);
  }
  saveTrace(run) {
    this.db.prepare('UPDATE flow_runs SET trace = ? WHERE id = ?').run(J.str(run.trace), run.id);
  }
  updateRun(run, status, error = null) {
    run.status = status;
    const ended = ['completed', 'failed', 'handoff'].includes(status) ? this.clock() : null;
    this.db.prepare('UPDATE flow_runs SET status = ?, trace = ?, error = ?, ended_at = ? WHERE id = ?').run(status, J.str(run.trace), error, ended, run.id);
  }
  endSession(customerId, runId, status, error, trace) {
    this.db.prepare('DELETE FROM sessions WHERE customer_id = ?').run(customerId);
    const t = trace || this.loadTrace(runId);
    this.db.prepare('UPDATE flow_runs SET status = ?, error = ?, trace = ?, ended_at = ? WHERE id = ?').run(status, error, J.str(t), this.clock(), runId);
  }
}

// ---------------------------------------------------------------- helpers
export function parseAnswer(node, text, replyId) {
  const t = String(text ?? '').trim();
  switch (node.input || 'text') {
    case 'choice': {
      const choices = node.choices || [];
      const byReply = replyId != null && choices.find((c, i) => String(c.value ?? i + 1) === String(replyId));
      const n = Number.parseInt(t, 10);
      const byNumber = String(n) === t && choices[n - 1];
      const byText = choices.find((c) => norm(c.label) === norm(t) || norm(c.value) === norm(t))
        || choices.find((c) => norm(t).length >= 3 && norm(c.label).includes(norm(t)));
      const c = byReply || byNumber || byText;
      if (!c) return { ok: false, reason: `Please choose one of: ${choices.map((x, i) => `${i + 1}. ${x.label}`).join(', ')}` };
      return { ok: true, value: String(c.value ?? c.label), label: c.label, next: c.next };
    }
    case 'number': {
      const m = t.replace(/,/g, '').match(/-?\d+(\.\d+)?/);
      const v = m ? Number(m[0]) : NaN;
      if (Number.isNaN(v)) return { ok: false, reason: 'Please reply with a number.' };
      if (node.min != null && v < node.min) return { ok: false, reason: `Please reply with ${node.min} or more.` };
      if (node.max != null && v > node.max) return { ok: false, reason: `Please reply with ${node.max} or less.` };
      return { ok: true, value: v };
    }
    case 'phone': {
      const d = t.replace(/[^\d+]/g, '');
      return d.replace('+', '').length >= 7 ? { ok: true, value: d } : { ok: false, reason: 'Please send a valid phone number.' };
    }
    default:
      if (!t) return { ok: false, reason: 'Please type a reply.' };
      if (node.minLength && t.length < node.minLength) return { ok: false, reason: `Please give a bit more detail (at least ${node.minLength} characters).` };
      return { ok: true, value: t };
  }
}

export function interpolate(template, ctx, vars = {}) {
  return String(template ?? '').replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_, key) => {
    const k = key.replace(/^(vars|customer)\./, '');
    if (key === 'name' || key === 'customer.name') return ctx.customer?.name || (vars.name ?? 'there');
    if (key === 'business') return ctx.business?.name ?? '';
    if (key === 'phone') return ctx.customer?.wa_id ? `+${ctx.customer.wa_id}` : '';
    if (k in vars) return String(vars[k]);
    if (ctx.customer?.fields && k in ctx.customer.fields) return String(ctx.customer.fields[k]);
    return '';
  });
}

function describeRule(r = {}) {
  if (r.kind === 'business_hours') return `Business is ${r.value === 'closed' ? 'closed' : 'open'}`;
  if (r.kind === 'tag') return `Customer has tag "${r.value}"`;
  if (r.kind === 'new_customer') return 'New customer';
  return `${r.var} ${r.op || 'eq'} ${r.value ?? ''}`.trim();
}

const CATEGORIES = [
  ['order', ['order', 'buy', 'menu', 'price list', 'deliver', 'delivery', 'pickup', 'want to get', 'how much']],
  ['booking', ['book', 'booking', 'appointment', 'reserve', 'reservation', 'schedule']],
  ['complaint', ['complain', 'complaint', 'bad', 'late', 'refund', 'wrong', 'angry', 'disappointed', 'not happy']],
  ['pricing', ['price', 'cost', 'how much', 'rate', 'charges', 'fee']],
  ['support', ['help', 'problem', 'issue', 'not working', 'support']],
  ['greeting', ['hi', 'hello', 'hey', 'good morning', 'good afternoon', 'good evening']],
];

/** Free, deterministic first-pass categorisation. */
export function categorize(text) {
  for (const [cat, kws] of CATEGORIES) if (keywordMatch(text, kws)) return cat;
  return '';
}
