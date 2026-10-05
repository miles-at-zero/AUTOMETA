import { J, tx } from '../db.js';
import { decrypt, encrypt, newId } from '../crypto.js';
import { pollNewEmails } from './integrations/gmail.js';
import { PushService } from './push.js';
import { INTEGRATIONS } from './integrations/index.js';
import { ActionError } from './integrations/base.js';
import { cloudPlan, effectiveCloudPlan } from './plans.js';
import { nextRun } from './schedule.js';

const MISSED_GRACE_MS = 60 * 60e3;   // later than this → recorded as skipped, not run
const JOB_LOCK_MS = 5 * 60e3;
const RETRY = { none: 0, once: 1, three: 3, exponential: 5 };

export const month = (ms) => new Date(ms).toISOString().slice(0, 7);

/** Resolves a condition field; `found` is false when the path doesn't exist. */
export function resolveField(field, vars) {
  const path = String(field).replace(/^\{\{\s*|\s*\}\}$/g, '');
  let o = vars; let found = true;
  for (const k of path.split('.')) { if (o == null || typeof o !== 'object' || !(k in o)) { found = false; o = undefined; break; } o = o[k]; }
  return { found, value: o };
}

export function getPath(obj, path) {
  return String(path).split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

/** {{payload.name}}, {{steps.s1.messageId}}, {{date}}, … Unknown → empty. */
export function interpolate(value, vars) {
  if (typeof value === 'string') return value.replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (_, p) => { const v = getPath(vars, p); return v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v); });
  if (Array.isArray(value)) return value.map((v) => interpolate(v, vars));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, interpolate(v, vars)]));
  return value;
}

export function evalRule(rule, vars) {
  const raw = getPath(vars, String(rule.field).replace(/^\{\{\s*|\s*\}\}$/g, ''));
  const a = raw == null ? '' : typeof raw === 'object' ? JSON.stringify(raw) : String(raw);
  const b = String(interpolate(rule.value ?? '', vars));
  const lc = (s) => s.toLowerCase();
  switch (rule.op || 'eq') {
    case 'eq': return lc(a) === lc(b);
    case 'neq': return lc(a) !== lc(b);
    case 'contains': return lc(a).includes(lc(b));
    case 'not_contains': return !lc(a).includes(lc(b));
    case 'starts_with': return lc(a).startsWith(lc(b));
    case 'gt': return Number(a) > Number(b);
    case 'lt': return Number(a) < Number(b);
    case 'exists': return a.trim() !== '';
    case 'not_exists': return a.trim() === '';
    default: return false;
  }
}

export function describeRule(r) {
  const op = { eq: 'is', neq: 'is not', contains: 'contains', not_contains: 'doesn\'t contain', starts_with: 'starts with', gt: '>', lt: '<', exists: 'is filled', not_exists: 'is empty' }[r.op || 'eq'];
  return `${r.field} ${op}${['exists', 'not_exists'].includes(r.op) ? '' : ` "${r.value ?? ''}"`}`;
}

export class CloudEngine {
  constructor({ db, env = process.env, secret, clock = () => Date.now(), fetchImpl = globalThis.fetch }) {
    Object.assign(this, { db, env, secret, clock, fetch: fetchImpl });
    this.push = new PushService({ db, env, fetchImpl, clock });
    this.pushQueue = [];
  }

  // ------------------------------------------------------------ helpers
  ws(id) { return this.db.prepare('SELECT * FROM workspaces WHERE id = ?').get(id); }
  planOf(wsId) { return cloudPlan(effectiveCloudPlan(this.ws(wsId), this.clock())); }
  automation(id) {
    const a = this.db.prepare('SELECT * FROM automations WHERE id = ?').get(id);
    return a && { ...a, trigger: J.parse(a.trigger, {}), steps: J.parse(a.steps, []), retry: J.parse(a.retry, { policy: 'none' }) };
  }
  connection(id, wsId) {
    const c = this.db.prepare('SELECT * FROM connections WHERE id = ? AND workspace_id = ?').get(id, wsId);
    return c && { ...c, meta: J.parse(c.meta, {}), secret: c.secret_enc ? decrypt(c.secret_enc, this.secret) : null };
  }
  usage(wsId, metric, ms = this.clock()) {
    return this.db.prepare('SELECT count FROM usage_records WHERE workspace_id = ? AND month = ? AND metric = ?').get(wsId, month(ms), metric)?.count || 0;
  }
  bump(wsId, metric, n = 1) {
    this.db.prepare('INSERT INTO usage_records (workspace_id, month, metric, count) VALUES (?,?,?,?) ON CONFLICT(workspace_id, month, metric) DO UPDATE SET count = count + excluded.count').run(wsId, month(this.clock()), metric, n);
  }
  notify(wsId, { kind, severity = 'info', title, body, action = null, target = null }, { dedupeMs = 0 } = {}) {
    if (dedupeMs) {
      const recent = this.db.prepare('SELECT 1 FROM notifications WHERE workspace_id = ? AND kind = ? AND COALESCE(target, \'\') = ? AND created_at > ?').get(wsId, kind, target || '', this.clock() - dedupeMs);
      if (recent) return;
    }
    const id = newId('n_');
    this.db.prepare('INSERT INTO notifications (id, workspace_id, kind, severity, title, body, action, target, created_at) VALUES (?,?,?,?,?,?,?,?,?)')
      .run(id, wsId, kind, severity, title, body, action ? J.str(action) : null, target, this.clock());
    // Push is sent outside the DB write path (flushPush), never blocking execution.
    this.pushQueue.push({ wsId, n: { id, kind, severity, title, body, action, target } });
  }
  async flushPush() {
    const q = this.pushQueue.splice(0);
    for (const { wsId, n } of q) await this.push.dispatch(wsId, n);
    return q.length;
  }
  saveSecret(connId, plain) {
    this.db.prepare('UPDATE connections SET secret_enc = ? WHERE id = ?').run(encrypt(plain, this.secret), connId);
  }
  addJob(kind, executionId, dueAt) {
    this.db.prepare('INSERT INTO cloud_jobs (id, kind, execution_id, due_at, created_at) VALUES (?,?,?,?,?)').run(newId('j_'), kind, executionId, dueAt, this.clock());
  }
  stepRow(execId, step, idx, kind, label) {
    const existing = this.db.prepare('SELECT * FROM execution_steps WHERE execution_id = ? AND step_id = ? ORDER BY id DESC LIMIT 1').get(execId, step.id);
    if (existing && ['retrying', 'waiting'].includes(existing.status)) return existing.id;
    return Number(this.db.prepare('INSERT INTO execution_steps (execution_id, step_id, idx, kind, label, status, started_at) VALUES (?,?,?,?,?,?,?)').run(execId, step.id, idx, kind, label, 'running', this.clock()).lastInsertRowid);
  }
  finishStep(rowId, status, { detail = null, output = null, error = null, fix = null, attemptsInc = 0 } = {}) {
    this.db.prepare('UPDATE execution_steps SET status = ?, detail = ?, output = ?, error = ?, fix = ?, attempts = attempts + ?, ended_at = ? WHERE id = ?')
      .run(status, detail, output == null ? null : J.str(output), error, fix, attemptsInc, ['retrying', 'waiting'].includes(status) ? null : this.clock(), rowId);
  }

  // ------------------------------------------------------------ start
  /**
   * Creates an execution and queues it. Returns the execution row (or the
   * existing one for a duplicate scheduled slot).
   */
  start(automation, { triggerType, data = {}, scheduledFor = null, isTest = false, live = true }) {
    const a = typeof automation === 'string' ? this.automation(automation) : automation;
    const now = this.clock();
    const plan = this.planOf(a.workspace_id);
    const seq = (this.db.prepare('SELECT MAX(seq) m FROM executions WHERE workspace_id = ?').get(a.workspace_id).m || 0) + 1;
    const id = newId('x_');
    const d = new Date(now);
    const vars = {
      trigger: data, payload: data.payload ?? data, headers: data.headers ?? {}, steps: {},
      ...(data.email ? { email: data.email } : {}),
      automation: a.name, date: d.toLocaleDateString('en-GB', { timeZone: a.timezone }), time: d.toLocaleTimeString('en-GB', { timeZone: a.timezone, hour: '2-digit', minute: '2-digit' }),
      weekday: d.toLocaleDateString('en-GB', { timeZone: a.timezone, weekday: 'long' }), execution: { id, number: seq, test: isTest },
    };
    vars.day = vars.weekday; // compatibility alias (VARIABLE_ALIASES in validate.js)
    let skipReason = null;
    if (!isTest) {
      const used = this.usage(a.workspace_id, 'executions');
      const limit = plan.limits.executionsPerMonth;
      if (limit != null && used >= limit) skipReason = `Monthly limit reached (${limit} executions on ${plan.name}).`;
      else if (a.max_runs_per_day) {
        const today = this.db.prepare(`SELECT COUNT(*) n FROM executions WHERE automation_id = ? AND started_at > ? AND status != 'skipped' AND is_test = 0`).get(a.id, now - 864e5).n;
        if (today >= a.max_runs_per_day) skipReason = `Daily run limit reached (${a.max_runs_per_day}).`;
      }
    }
    try {
      this.db.prepare('INSERT INTO executions (id, seq, workspace_id, automation_id, trigger_type, trigger_data, scheduled_for, status, is_test, live, started_at, vars, error, ended_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)')
        .run(id, seq, a.workspace_id, a.id, triggerType, J.str(data), scheduledFor, skipReason ? 'skipped' : 'running', isTest ? 1 : 0, live ? 1 : 0, now, J.str(vars), skipReason, skipReason ? now : null);
    } catch (e) {
      if (/UNIQUE/.test(e.message)) return this.db.prepare('SELECT * FROM executions WHERE automation_id = ? AND scheduled_for = ?').get(a.id, scheduledFor);
      throw e;
    }
    if (skipReason) {
      this.notify(a.workspace_id, { kind: 'usage_limit', severity: 'warning', title: 'Execution limit reached', body: `${a.name} didn't run. ${skipReason} Upgrade to keep automations running this month.`, action: { type: 'billing' } }, { dedupeMs: 864e5 });
    } else {
      if (!isTest) {
        this.bump(a.workspace_id, 'executions');
        const used = this.usage(a.workspace_id, 'executions');
        const limit = plan.limits.executionsPerMonth;
        if (limit && used === Math.ceil(limit * 0.8)) this.notify(a.workspace_id, { kind: 'usage_warning', severity: 'warning', title: '80% of executions used', body: `${used} / ${limit} executions used this month.`, action: { type: 'billing' } });
      }
      this.addJob('run', id, now);
    }
    return this.db.prepare('SELECT * FROM executions WHERE id = ?').get(id);
  }

  // ------------------------------------------------------------ run
  async runExecution(execId) {
    const ex = this.db.prepare('SELECT * FROM executions WHERE id = ?').get(execId);
    if (!ex || ex.status !== 'running') return;
    const a = this.automation(ex.automation_id);
    if (!a) return;
    const vars = J.parse(ex.vars, {});
    const isTest = !!ex.is_test;
    const live = !!ex.live;
    let actionsDone = this.db.prepare(`SELECT COUNT(*) n FROM execution_steps WHERE execution_id = ? AND kind = 'action' AND status IN ('success','simulated')`).get(ex.id).n;
    if (ex.cursor === 0 && !this.db.prepare('SELECT 1 FROM execution_steps WHERE execution_id = ? AND step_id = ?').get(ex.id, '_trigger')) {
      const r = this.stepRow(ex.id, { id: '_trigger' }, -1, 'trigger', this.triggerLabel(a));
      this.finishStep(r, 'success', { detail: ex.trigger_type === 'schedule' ? 'Schedule fired' : ex.trigger_type === 'webhook' ? 'Webhook received' : ex.trigger_type === 'test' ? 'Test run started' : 'Started manually' });
    }
    const save = (patch) => {
      const cols = Object.keys(patch);
      this.db.prepare(`UPDATE executions SET ${cols.map((c) => `${c} = ?`).join(', ')} WHERE id = ?`).run(...cols.map((c) => patch[c]), ex.id);
    };
    for (let i = ex.cursor; i < a.steps.length; i++) {
      const step = a.steps[i];
      const label = this.stepLabel(step);
      if (step.enabled === false) {
        const r = this.stepRow(ex.id, step, i, step.type, label);
        this.finishStep(r, 'skipped', { detail: 'Step is turned off' });
        continue;
      }
      if (step.type === 'condition') {
        const r = this.stepRow(ex.id, step, i, 'condition', label);
        const results = (step.rules || []).map((rule) => {
          const f = resolveField(rule.field, vars);
          const shown = f.value == null ? '' : typeof f.value === 'object' ? JSON.stringify(f.value) : String(f.value);
          return { rule, ok: evalRule(rule, vars), note: f.found ? `(was "${shown.slice(0, 60)}")` : '(field not available in this run)' };
        });
        const pass = step.mode === 'any' ? results.some((x) => x.ok) : results.every((x) => x.ok);
        this.finishStep(r, pass ? 'success' : 'stopped', { detail: results.map((x) => `${x.ok ? '✓' : '✕'} ${describeRule(x.rule)} ${x.note}`).join(step.mode === 'any' ? ' OR ' : ' AND ') });
        if (!pass) {
          save({ status: actionsDone ? 'success' : 'skipped', ended_at: this.clock(), cursor: i + 1, vars: J.str(vars), error: actionsDone ? null : 'Conditions not met' });
          return this.afterFinish(a, ex.id);
        }
        continue;
      }
      if (step.type === 'delay') {
        const r = this.stepRow(ex.id, step, i, 'delay', label);
        if (isTest) { this.finishStep(r, 'skipped', { detail: `Test run: ${step.minutes} min wait skipped` }); continue; }
        const row = this.db.prepare('SELECT status FROM execution_steps WHERE id = ?').get(r);
        if (row.status === 'waiting') { this.finishStep(r, 'success', { detail: `Waited ${step.minutes} min` }); continue; }
        this.finishStep(r, 'waiting', { detail: `Waiting ${step.minutes} min` });
        save({ cursor: i, vars: J.str(vars) });
        this.addJob('resume', ex.id, this.clock() + Number(step.minutes) * 60e3);
        return;
      }
      // ---- action
      const r = this.stepRow(ex.id, step, i, 'action', label);
      const integ = INTEGRATIONS[step.integration];
      const def = integ?.actions?.[step.action];
      try {
        if (!def) throw new ActionError('This action no longer exists.', { kind: 'config', fix: 'Edit the automation and choose another action.' });
        let conn = null;
        if (integ.auth.type !== 'none') {
          conn = step.connectionId ? this.connection(step.connectionId, a.workspace_id) : null;
          if (!conn || conn.status === 'disconnected') throw new ActionError(`${integ.name} isn't connected.`, { kind: 'auth', fix: `Connect ${integ.name} and select it in this step.` });
          if (conn.status === 'needs_reauth') throw new ActionError(`${integ.name} needs to be reconnected.`, { kind: 'auth', fix: `Reconnect ${integ.name}.` });
        }
        const cfg = interpolate(step.config || {}, vars);
        if (isTest && !live) {
          const out = def.simulate(cfg);
          vars.steps[step.id] = out;
          this.finishStep(r, 'simulated', { detail: 'Simulated: no live action was performed', output: out });
          actionsDone++;
          continue;
        }
        const key = `${ex.id}:${step.id}`;
        const receipt = this.db.prepare('SELECT output FROM step_receipts WHERE key = ?').get(key);
        let out;
        if (receipt) out = J.parse(receipt.output, {});
        else {
          out = await def.execute(cfg, conn, { fetch: this.fetch, env: this.env, now: this.clock, automation: a, execution: ex, idempotencyKey: key, notify: (n) => this.notify(a.workspace_id, n), saveSecret: (p) => conn && this.saveSecret(conn.id, p) });
          this.db.prepare('INSERT OR IGNORE INTO step_receipts (key, output, created_at) VALUES (?,?,?)').run(key, J.str(out), this.clock());
          if (!isTest) this.bump(a.workspace_id, 'actions');
          if (conn) this.db.prepare('UPDATE connections SET last_ok_at = ?, last_error = NULL WHERE id = ?').run(this.clock(), conn.id);
        }
        vars.steps[step.id] = out;
        this.finishStep(r, 'success', { detail: receipt ? 'Already done earlier in this run (not repeated)' : 'Done', output: out, attemptsInc: 1 });
        actionsDone++;
        save({ cursor: i + 1, vars: J.str(vars) });
      } catch (err) {
        const e = err instanceof ActionError ? err : new ActionError(err.message || 'Unexpected error', { kind: 'transient' });
        const attempts = (this.db.prepare('SELECT attempts FROM execution_steps WHERE id = ?').get(r).attempts || 0) + 1;
        const policy = a.retry?.policy || 'none';
        const max = RETRY[policy] ?? 0;
        const idempotent = def?.idempotentFor ? def.idempotentFor(step.config || {}) : !!def?.idempotent;
        const canRetry = (e.retryable || (e.kind === 'ambiguous' && idempotent)) && attempts <= max;
        if (canRetry) {
          const backoff = policy === 'exponential' ? 30e3 * 2 ** (attempts - 1) : 60e3;
          this.finishStep(r, 'retrying', { error: e.message, detail: `Attempt ${attempts} failed; retrying`, attemptsInc: 1 });
          save({ cursor: i, vars: J.str(vars), retry_count: ex.retry_count + 1 });
          this.addJob('resume', ex.id, this.clock() + Math.max(backoff, e.retryAfterMs || 0));
          return;
        }
        const why = e.kind === 'ambiguous' && !idempotent && max > 0 ? ' Not retried automatically because the provider may already have received it (retrying could send a duplicate).' : '';
        this.finishStep(r, 'failed', { error: e.message + why, fix: e.fix, attemptsInc: 1, detail: e.kind });
        save({ status: actionsDone ? 'partial' : 'failed', ended_at: this.clock(), error: `${label}: ${e.message}`, cursor: i, vars: J.str(vars) });
        this.onFailure(a, ex, step, integ, e);
        return this.afterFinish(a, ex.id);
      }
    }
    save({ status: 'success', ended_at: this.clock(), cursor: a.steps.length, vars: J.str(vars) });
    if (!isTest) this.db.prepare('UPDATE automations SET consecutive_failures = 0 WHERE id = ?').run(a.id);
    this.afterFinish(a, ex.id);
  }

  afterFinish() { /* hook for push/websocket later */ }

  onFailure(a, ex, step, integ, e) {
    if (ex.is_test) return;
    if (e.kind === 'auth' && step.connectionId) {
      this.db.prepare(`UPDATE connections SET status = 'needs_reauth', last_error = ? WHERE id = ? AND workspace_id = ?`).run(e.message, step.connectionId, a.workspace_id);
      this.db.prepare(`UPDATE automations SET status = 'error', status_reason = ?, next_run_at = NULL WHERE id = ?`).run(`${integ?.name || 'A connection'} needs to be reconnected.`, a.id);
      this.notify(a.workspace_id, { kind: 'connection_reauth', severity: 'error', title: `${integ?.name} needs attention`, body: `"${a.name}" failed: ${e.message} It has been paused to prevent repeated failures. Reconnect ${integ?.name} to resume.`, action: { type: 'reconnect', connectionId: step.connectionId }, target: a.id });
      return;
    }
    const fails = this.db.prepare('UPDATE automations SET consecutive_failures = consecutive_failures + 1 WHERE id = ? RETURNING consecutive_failures').get(a.id).consecutive_failures;
    const pauseAt = a.on_failure === 'pause_after_1' ? 1 : a.on_failure === 'never_pause' ? Infinity : 3;
    if (fails >= pauseAt) {
      this.db.prepare(`UPDATE automations SET status = 'error', status_reason = ?, next_run_at = NULL WHERE id = ?`).run(`Paused after ${fails} failed run${fails > 1 ? 's' : ''} in a row. Last error: ${e.message}`, a.id);
      this.notify(a.workspace_id, { kind: 'automation_paused', severity: 'error', title: `${a.name} was paused`, body: `It failed ${fails} time${fails > 1 ? 's' : ''} in a row. Reason: ${e.message}${e.fix ? ` Fix: ${e.fix}` : ''}`, action: { type: 'execution', executionId: ex.id }, target: a.id });
    } else {
      this.notify(a.workspace_id, { kind: 'automation_failed', severity: 'error', title: `${a.name} failed`, body: `${e.message}${e.fix ? ` ${e.fix}` : ''}`, action: { type: 'execution', executionId: ex.id }, target: a.id }, { dedupeMs: 30 * 60e3 });
    }
  }

  triggerLabel(a) {
    const t = a.trigger || {};
    return INTEGRATIONS[t.integration]?.triggers?.[t.key]?.label || 'Trigger';
  }
  stepLabel(s) {
    if (s.label) return s.label;
    if (s.type === 'condition') return 'Condition';
    if (s.type === 'delay') return `Wait ${s.minutes} min`;
    const i = INTEGRATIONS[s.integration];
    return i?.actions?.[s.action] ? `${i.name}: ${i.actions[s.action].label}` : 'Action';
  }

  // ------------------------------------------------------------ scheduler + queue
  schedule(a, from = this.clock()) {
    const t = typeof a.trigger === 'string' ? J.parse(a.trigger, {}) : a.trigger;
    if (t.integration !== 'autometa' || t.key !== 'schedule') return null;
    return nextRun(t.schedule, a.timezone, from);
  }

  /** One scheduler/worker pass. Safe to call concurrently from one process. */
  async tick() {
    const now = this.clock();
    const due = this.db.prepare(`SELECT * FROM automations WHERE status = 'active' AND next_run_at IS NOT NULL AND next_run_at <= ?`).all(now);
    for (const row of due) {
      const a = this.automation(row.id);
      const slot = row.next_run_at;
      tx(this.db, () => {
        const next = this.schedule(a, Math.max(now, slot));
        this.db.prepare('UPDATE automations SET next_run_at = ? WHERE id = ? AND next_run_at = ?').run(next, a.id, slot);
      });
      if (now - slot > MISSED_GRACE_MS) {
        try {
          this.db.prepare('INSERT INTO executions (id, seq, workspace_id, automation_id, trigger_type, scheduled_for, status, started_at, ended_at, error) VALUES (?,?,?,?,?,?,?,?,?,?)')
            .run(newId('x_'), (this.db.prepare('SELECT MAX(seq) m FROM executions WHERE workspace_id = ?').get(a.workspace_id).m || 0) + 1, a.workspace_id, a.id, 'schedule', slot, 'skipped', now, now, 'Missed: the server was offline at the scheduled time.');
        } catch { /* duplicate slot */ }
        continue;
      }
      this.start(a, { triggerType: 'schedule', data: { scheduledFor: new Date(slot).toISOString() }, scheduledFor: slot });
    }
    await this.pollTriggers(now);
    const jobs = this.db.prepare('SELECT * FROM cloud_jobs WHERE done = 0 AND due_at <= ? AND (locked_until IS NULL OR locked_until < ?) ORDER BY due_at LIMIT 50').all(now, now);
    for (const j of jobs) {
      const claimed = this.db.prepare('UPDATE cloud_jobs SET locked_until = ?, attempts = attempts + 1 WHERE id = ? AND done = 0 AND (locked_until IS NULL OR locked_until < ?)').run(now + JOB_LOCK_MS, j.id, now).changes;
      if (!claimed) continue;
      try {
        await this.runExecution(j.execution_id);
        this.db.prepare('UPDATE cloud_jobs SET done = 1 WHERE id = ?').run(j.id);
      } catch (e) {
        const give = j.attempts + 1 >= 5;
        this.db.prepare('UPDATE cloud_jobs SET locked_until = NULL, due_at = ?, last_error = ?, done = ? WHERE id = ?').run(now + 60e3, String(e.message), give ? 1 : 0, j.id);
        if (give) this.db.prepare(`UPDATE executions SET status = 'failed', ended_at = ?, error = ? WHERE id = ? AND status = 'running'`).run(now, `Internal error: ${e.message}`, j.execution_id);
      }
    }
    await this.flushPush();
    return { scheduled: due.length, jobs: jobs.length };
  }

  /** Polling triggers (Gmail new_email). Cursor starts at activation: old mail never fires. */
  async pollTriggers(now = this.clock()) {
    const rows = this.db.prepare(`SELECT id FROM automations WHERE status = 'active' AND trigger LIKE '%"integration":"gmail"%' AND (next_poll_at IS NULL OR next_poll_at <= ?)`).all(now);
    for (const { id } of rows) {
      const a = this.automation(id);
      const t = a.trigger;
      if (t.integration !== 'gmail' || t.key !== 'new_email') continue;
      this.db.prepare('UPDATE automations SET next_poll_at = ? WHERE id = ?').run(now + 60e3, id);
      const conn = t.connectionId ? this.connection(t.connectionId, a.workspace_id) : null;
      if (!conn || conn.status !== 'connected') continue;
      const state = J.parse(this.db.prepare('SELECT trigger_state FROM automations WHERE id = ?').get(id).trigger_state, {});
      try {
        const r = await pollNewEmails(conn, t.config?.query || '', state.cursor || null, { fetch: this.fetch, env: this.env, now: this.clock, saveSecret: (p) => this.saveSecret(conn.id, p) });
        this.db.prepare('UPDATE automations SET trigger_state = ? WHERE id = ?').run(J.str({ cursor: r.cursor }), id);
        this.db.prepare('UPDATE connections SET last_ok_at = ?, last_error = NULL WHERE id = ?').run(now, conn.id);
        for (const email of r.emails) this.start(a, { triggerType: 'gmail', data: { email }, scheduledFor: email.receivedAt });
      } catch (err) {
        if (err instanceof ActionError && err.kind === 'auth') {
          this.onFailure(a, { is_test: 0 }, { connectionId: conn.id }, INTEGRATIONS.gmail, err);
        } else {
          this.db.prepare('UPDATE connections SET last_error = ? WHERE id = ?').run(String(err.message), conn.id);
        }
      }
    }
  }

  /** Runs everything due, including jobs created during this pass (tests, catch-up). */
  async drain(max = 20) {
    for (let i = 0; i < max; i++) {
      const r = await this.tick();
      if (!r.jobs && !r.scheduled) return;
    }
  }
}
