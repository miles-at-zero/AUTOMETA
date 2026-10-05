import { J, tx } from '../db.js';
import { encrypt, newId, newToken, sha256 } from '../crypto.js';
import { GooglePlayVerifier, mapPlayState } from '../billing.js';
import { pricing } from '../pricing.js';
import { CLOUD_SCHEMA, CLOUD_MIGRATIONS } from './schema.js';
import { CloudEngine } from './engine.js';
import { catalog, INTEGRATIONS } from './integrations/index.js';
import { googleAuthUrl, googleConfigured, googleExchange } from './integrations/gmail.js';
import { createHash, randomBytes } from 'node:crypto';
import { ActionError } from './integrations/base.js';
import { CLOUD_PLANS, cloudPlan, effectiveCloudPlan, LimitError, upgradeFor } from './plans.js';
import { describeSchedule, nextRun, validTimezone } from './schedule.js';
import { CLOUD_TEMPLATES, STARTERS } from './templates.js';
import { validateAutomation } from './validate.js';
import { hashPassword, passwordProblem, RateLimiter, sendResetEmail, validEmail, verifyPassword } from './auth.js';

class HttpError extends Error {
  constructor(status, message, extra = {}) { super(message); Object.assign(this, { status }, extra); }
}
const SESSION_MS = 30 * 864e5;
const MAX_HOOK_BYTES = 256 * 1024;

export function createCloud({ db, env = process.env, secret, clock = () => Date.now(), fetchImpl = globalThis.fetch }) {
  db.exec(CLOUD_SCHEMA);
  for (const m of CLOUD_MIGRATIONS) { try { db.exec(m); } catch { /* column already exists */ } }
  const engine = new CloudEngine({ db, env, secret, clock, fetchImpl });
  const limiter = new RateLimiter(clock);
  const play = new GooglePlayVerifier({ env, fetchImpl });
  const routes = [];
  const route = (method, path, handler, opts = {}) => {
    const keys = [];
    const re = new RegExp(`^${path.replace(/:(\w+)/g, (_, k) => { keys.push(k); return '([^/]+)'; })}$`);
    routes.push({ method, re, keys, handler, ...opts });
  };

  // ------------------------------------------------------------ helpers
  const audit = (ctx, action, target = null, detail = null) => db.prepare('INSERT INTO cloud_audit (workspace_id, user_id, action, target, detail, ip, ts) VALUES (?,?,?,?,?,?,?)')
    .run(ctx?.ws?.id ?? null, ctx?.user?.id ?? null, action, target, detail ? J.str(detail) : null, ctx?.ip ?? null, clock());
  const planOf = (ws) => cloudPlan(effectiveCloudPlan(ws, clock()));
  const own = (table, id, ws) => {
    const r = db.prepare(`SELECT * FROM ${table} WHERE id = ? AND workspace_id = ?`).get(id, ws.id);
    if (!r) throw new HttpError(404, 'Not found');
    return r;
  };
  const limitCheck = (ws, key, used, label) => {
    const plan = planOf(ws);
    const lim = plan.limits[key];
    if (lim != null && used >= lim) throw new LimitError(`${plan.name} includes ${lim} ${label}. Upgrade for more.`, { limit: key, requiredPlan: upgradeFor((p) => p.limits[key] == null || p.limits[key] > lim) });
  };
  const count = (sql, ...a) => db.prepare(sql).get(...a).n;
  const userOut = (u) => ({ id: u.id, email: u.email, name: u.name, timezone: u.timezone, settings: J.parse(u.settings, {}), createdAt: u.created_at });
  const connOut = (c) => ({
    id: c.id, integration: c.integration, name: INTEGRATIONS[c.integration]?.name || c.integration, label: c.label, identity: c.identity, status: c.status,
    scopes: J.parse(c.scopes, []), lastOkAt: c.last_ok_at, lastError: c.last_error, createdAt: c.created_at,
    usedBy: db.prepare(`SELECT id, name, status FROM automations WHERE workspace_id = ? AND (steps LIKE ? OR trigger LIKE ?) AND status != 'archived'`).all(c.workspace_id, `%${c.id}%`, `%${c.id}%`),
  });
  const webhookOut = (w, publicBase) => ({
    id: w.id, name: w.name, enabled: !!w.enabled, automationId: w.automation_id, requiresSecret: !!w.secret_hash,
    url: `${publicBase}/hooks/${w.public_id}`, requestCount: w.request_count, lastReceivedAt: w.last_received_at, createdAt: w.created_at,
  });
  const autoRow = (a) => ({ ...a, trigger: J.parse(a.trigger, {}), steps: J.parse(a.steps, []), retry: J.parse(a.retry, { policy: 'none' }) });
  const validationFor = (ws, a) => validateAutomation(a, { env,
    connections: db.prepare('SELECT id, integration, status, identity FROM connections WHERE workspace_id = ?').all(ws.id),
    webhooks: db.prepare('SELECT id, name, enabled FROM webhooks WHERE workspace_id = ?').all(ws.id),
    planId: planOf(ws).id,
  });
  const summary = (a) => {
    const t = a.trigger || {};
    const trig = t.key === 'schedule' ? describeSchedule(t.schedule) : INTEGRATIONS[t.integration]?.triggers?.[t.key]?.label || 'No trigger yet';
    const first = (a.steps || []).find((s) => s.type === 'action');
    const action = first ? engine.stepLabel(first) : 'No action yet';
    return { trigger: trig, action, providers: [...new Set([t.integration, ...(a.steps || []).filter((s) => s.type === 'action').map((s) => s.integration)].filter(Boolean))] };
  };
  const autoOut = (ws, raw, { detail = false } = {}) => {
    const a = autoRow(raw);
    const stats = db.prepare(`SELECT COUNT(*) runs, SUM(status='success') ok, SUM(status IN ('failed','partial')) bad, MAX(started_at) last, AVG(CASE WHEN ended_at IS NOT NULL THEN ended_at - started_at END) avg_ms
      FROM executions WHERE automation_id = ? AND is_test = 0 AND status != 'skipped'`).get(a.id);
    const out = {
      id: a.id, name: a.name, description: a.description, status: a.status, statusReason: a.status_reason, trigger: a.trigger, steps: a.steps,
      timezone: a.timezone, retry: a.retry, onFailure: a.on_failure, maxRunsPerDay: a.max_runs_per_day, nextRunAt: a.next_run_at,
      templateId: a.template_id, createdAt: a.created_at, updatedAt: a.updated_at, summary: summary(a),
      stats: { executions: stats.runs || 0, successRate: stats.runs ? Math.round((stats.ok / stats.runs) * 1000) / 10 : null, failures: stats.bad || 0, lastRunAt: stats.last, avgDurationMs: stats.avg_ms ? Math.round(stats.avg_ms) : null },
    };
    if (detail) {
      out.validation = validationFor(ws, a);
      out.recent = db.prepare('SELECT id, seq, status, trigger_type triggerType, is_test isTest, started_at startedAt, ended_at endedAt, error FROM executions WHERE automation_id = ? ORDER BY started_at DESC LIMIT 15').all(a.id);
      out.commonFailure = db.prepare(`SELECT error, COUNT(*) n FROM executions WHERE automation_id = ? AND status IN ('failed','partial') AND error IS NOT NULL GROUP BY error ORDER BY n DESC LIMIT 1`).get(a.id) || null;
      const since = clock() - 14 * 864e5;
      out.timeline = db.prepare(`SELECT CAST((started_at - ?) / 86400000 AS INTEGER) day, SUM(status='success') ok, SUM(status IN ('failed','partial')) bad FROM executions WHERE automation_id = ? AND started_at >= ? AND is_test = 0 GROUP BY day`).all(since, a.id, since);
      const upcoming = [];
      let t = clock();
      for (let i = 0; i < 5 && a.trigger.key === 'schedule'; i++) { t = nextRun(a.trigger.schedule, a.timezone, t); if (!t) break; upcoming.push(t); }
      out.upcoming = upcoming;
    }
    return out;
  };
  const execOut = (e, withSteps = false) => {
    const name = db.prepare('SELECT name FROM automations WHERE id = ?').get(e.automation_id)?.name || 'Deleted automation';
    const out = { id: e.id, number: e.seq, automationId: e.automation_id, automationName: name, triggerType: e.trigger_type, status: e.status, isTest: !!e.is_test, live: !!e.live, startedAt: e.started_at, endedAt: e.ended_at, durationMs: e.ended_at ? e.ended_at - e.started_at : null, error: e.error, retryCount: e.retry_count };
    if (withSteps) {
      out.trigger = J.parse(e.trigger_data, {});
      out.steps = db.prepare('SELECT step_id stepId, idx, kind, label, status, detail, output, error, fix, attempts, started_at startedAt, ended_at endedAt FROM execution_steps WHERE execution_id = ? ORDER BY id').all(e.id)
        .map((s) => ({ ...s, output: J.parse(s.output, null), durationMs: s.endedAt ? s.endedAt - s.startedAt : null }));
      out.notice = e.is_test ? (e.live ? 'Test run with live actions (you confirmed). Waits were skipped.' : 'This was a test. No live action was performed.') : null;
      const failed = out.steps.find((s) => s.status === 'failed');
      const conn = failed && db.prepare(`SELECT c.id, c.integration FROM connections c WHERE c.workspace_id = ? AND c.status = 'needs_reauth' AND ? LIKE '%' || c.id || '%'`).get(e.workspace_id, (() => { const r = db.prepare('SELECT steps, trigger FROM automations WHERE id = ?').get(e.automation_id); return r ? r.steps + r.trigger : ''; })());
      out.actions = { canRetry: ['failed', 'partial'].includes(e.status) && !e.is_test, reconnect: conn ? { connectionId: conn.id, integration: conn.integration } : null };
    }
    return out;
  };
  const setDerivedStatus = (ws, id) => {
    const a = autoRow(own('automations', id, ws));
    if (['active', 'paused', 'archived', 'error'].includes(a.status)) {
      if (a.status === 'active' && !validationFor(ws, a).ok) db.prepare(`UPDATE automations SET status = 'paused', status_reason = 'Paused: a recent edit left it incomplete.', next_run_at = NULL WHERE id = ?`).run(id);
      else if (a.status === 'active') db.prepare('UPDATE automations SET next_run_at = ? WHERE id = ?').run(engine.schedule(a), id);
      return;
    }
    db.prepare('UPDATE automations SET status = ? WHERE id = ?').run(validationFor(ws, a).ok ? 'ready' : 'draft', id);
  };
  const cleanSteps = (steps) => (Array.isArray(steps) ? steps : []).slice(0, 60).map((s) => ({
    id: String(s.id || newId('s')).slice(0, 40), type: s.type, enabled: s.enabled !== false, label: s.label ? String(s.label).slice(0, 80) : undefined,
    ...(s.type === 'action' ? { integration: s.integration, action: s.action, connectionId: s.connectionId || null, config: s.config && typeof s.config === 'object' ? s.config : {} } : {}),
    ...(s.type === 'condition' ? { mode: s.mode == null ? 'all' : String(s.mode).slice(0, 20), rules: (s.rules || []).slice(0, 10).map((r) => ({ field: String(r.field || ''), op: r.op || 'eq', value: r.value ?? '' })) } : {}),
    ...(s.type === 'delay' ? { minutes: Number(s.minutes) || 0 } : {}),
  }));

  // ------------------------------------------------------------ auth
  async function startSession(user, req) {
    const token = newToken();
    db.prepare('INSERT INTO user_sessions (token_hash, user_id, created_at, expires_at, last_seen, agent) VALUES (?,?,?,?,?,?)')
      .run(sha256(token), user.id, clock(), clock() + SESSION_MS, clock(), String(req.headers['user-agent'] || '').slice(0, 120));
    return token;
  }
  function authCtx(req) {
    const h = req.headers.authorization || '';
    const token = h.startsWith('Bearer ') ? h.slice(7) : null;
    if (!token) throw new HttpError(401, 'Sign in required');
    const s = db.prepare('SELECT * FROM user_sessions WHERE token_hash = ?').get(sha256(token));
    if (!s || s.expires_at < clock()) throw new HttpError(401, 'Your session expired. Sign in again.');
    const user = db.prepare('SELECT * FROM users WHERE id = ? AND disabled = 0').get(s.user_id);
    if (!user) throw new HttpError(401, 'Account unavailable');
    if (clock() - s.last_seen > 3600e3) db.prepare('UPDATE user_sessions SET last_seen = ? WHERE token_hash = ?').run(clock(), s.token_hash);
    const ws = db.prepare('SELECT w.*, m.role FROM workspaces w JOIN workspace_members m ON m.workspace_id = w.id WHERE m.user_id = ? ORDER BY w.created_at LIMIT 1').get(user.id);
    return { user, ws, session: s };
  }

  route('POST', '/v1/auth/signup', async ({ body, ip, req }) => {
    if (!limiter.hit(`signup:${ip}`, 10, 3600e3)) throw new HttpError(429, 'Too many sign-ups from this network. Try again later.');
    if (env.CLOUD_SIGNUP === 'false') throw new HttpError(403, 'Sign-up is closed on this server.');
    const email = String(body.email || '').trim().toLowerCase();
    if (!validEmail(email)) throw new HttpError(422, 'Enter a valid email address.');
    const pwErr = passwordProblem(body.password);
    if (pwErr) throw new HttpError(422, pwErr);
    if (db.prepare('SELECT 1 FROM users WHERE email = ?').get(email)) throw new HttpError(409, 'An account with this email already exists. Sign in instead.');
    const tz = validTimezone(body.timezone) ? body.timezone : 'UTC';
    const hash = await hashPassword(body.password);
    const user = tx(db, () => {
      const id = newId('u_');
      const wsId = newId('w_');
      db.prepare('INSERT INTO users (id, email, name, password_hash, timezone, created_at) VALUES (?,?,?,?,?,?)').run(id, email, String(body.name || '').trim().slice(0, 80), hash, tz, clock());
      db.prepare('INSERT INTO workspaces (id, name, owner_id, created_at) VALUES (?,?,?,?)').run(wsId, `${String(body.name || 'My').trim() || 'My'} workspace`, id, clock());
      db.prepare('INSERT INTO workspace_members (workspace_id, user_id, role) VALUES (?,?,?)').run(wsId, id, 'owner');
      return db.prepare('SELECT * FROM users WHERE id = ?').get(id);
    });
    audit({ user, ip }, 'auth.signup');
    return { token: await startSession(user, req), user: userOut(user) };
  }, { public: true });

  route('POST', '/v1/auth/login', async ({ body, ip, req }) => {
    const email = String(body.email || '').trim().toLowerCase();
    if (!limiter.hit(`login:${ip}`, 30, 15 * 60e3) || !limiter.hit(`login:${email}`, 10, 15 * 60e3)) throw new HttpError(429, 'Too many attempts. Wait 15 minutes and try again.');
    const user = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
    const ok = user ? await verifyPassword(body.password, user.password_hash) : (await hashPassword('x'), false);
    if (!ok || user.disabled) throw new HttpError(401, 'Email or password is incorrect.');
    audit({ user, ip }, 'auth.login');
    return { token: await startSession(user, req), user: userOut(user) };
  }, { public: true });

  route('POST', '/v1/auth/logout', ({ ctx }) => { db.prepare('DELETE FROM user_sessions WHERE token_hash = ?').run(ctx.session.token_hash); return { ok: true }; });
  route('POST', '/v1/auth/logout-all', ({ ctx }) => { db.prepare('DELETE FROM user_sessions WHERE user_id = ?').run(ctx.user.id); audit(ctx, 'auth.logout_all'); return { ok: true }; });

  route('POST', '/v1/auth/forgot', async ({ body, ip }) => {
    if (!limiter.hit(`forgot:${ip}`, 5, 3600e3)) throw new HttpError(429, 'Too many requests. Try again later.');
    const user = db.prepare('SELECT * FROM users WHERE email = ? AND disabled = 0').get(String(body.email || '').trim().toLowerCase());
    let emailConfigured = !!(env.RESEND_API_KEY && env.MAIL_FROM);
    if (user && emailConfigured) {
      const token = newToken();
      db.prepare('INSERT INTO password_resets (token_hash, user_id, expires_at) VALUES (?,?,?)').run(sha256(token), user.id, clock() + 3600e3);
      emailConfigured = await sendResetEmail({ env, fetchImpl, to: user.email, link: `${env.PUBLIC_APP_URL || env.PUBLIC_URL || ''}/reset?token=${token}` }).catch(() => false);
    }
    // Same answer whether or not the account exists (no account enumeration).
    return { ok: true, message: emailConfigured ? 'If that email has an account, a reset link is on its way.' : 'Password reset email isn\'t set up on this server. Ask the server owner for a reset link.' };
  }, { public: true });

  async function applyReset(token, password, ip) {
    if (!limiter.hit(`reset:${ip}`, 20, 3600e3)) throw new HttpError(429, 'Too many attempts.');
    const r = db.prepare('SELECT * FROM password_resets WHERE token_hash = ?').get(sha256(token || ''));
    if (!r || r.used || r.expires_at < clock()) throw new HttpError(400, 'This reset link is invalid or expired. Request a new one.');
    const pwErr = passwordProblem(password);
    if (pwErr) throw new HttpError(422, pwErr);
    const hash = await hashPassword(password);
    tx(db, () => {
      db.prepare('UPDATE password_resets SET used = 1 WHERE token_hash = ?').run(r.token_hash);
      db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(hash, r.user_id);
      db.prepare('DELETE FROM user_sessions WHERE user_id = ?').run(r.user_id);
    });
    audit({ user: { id: r.user_id }, ip }, 'auth.reset');
  }
  route('POST', '/v1/auth/reset', async ({ body, ip }) => {
    await applyReset(body.token, body.password, ip);
    return { ok: true };
  }, { public: true });
  // The reset email links here (PUBLIC_URL/reset?token=…). A plain HTML form
  // (no scripts; the page CSP forbids them) that posts back to POST /reset.
  route('GET', '/reset', ({ query }) => {
    const token = String(query.get('token') || '');
    if (!token) return page('Reset link incomplete', 'Open the full link from the email, or request a new one in the app.', false);
    return { __html: `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Reset password</title><body style="font-family:system-ui;background:#0f1220;color:#e8eaf6;display:grid;place-items:center;min-height:90vh;padding:24px"><form method="post" action="/reset" style="max-width:360px;width:100%"><h2>Choose a new password</h2><input type="hidden" name="token" value="${esc(token)}"><p><input type="password" name="password" required minlength="10" autocomplete="new-password" placeholder="New password" style="width:100%;padding:12px;font-size:16px;border-radius:8px;border:1px solid #444"></p><p><button type="submit" style="width:100%;padding:12px;font-size:16px;border-radius:8px;border:0;background:#22d3ee;color:#0f1220">Set password</button></p><p style="opacity:.7">This signs you out on every device.</p></form>` };
  }, { public: true });
  route('POST', '/reset', async ({ raw, ip }) => {
    const f = new URLSearchParams(raw.toString('utf8'));
    try {
      await applyReset(f.get('token'), f.get('password'), ip);
    } catch (e) {
      if (!(e instanceof HttpError)) throw e;
      return page('Password not changed', esc(e.message), false);
    }
    return page('Password changed', 'Sign in to Autometa with your new password.', true);
  }, { public: true, raw: true });

  // ------------------------------------------------------------ account
  route('GET', '/v1/me', ({ ctx }) => ({
    user: userOut(ctx.user),
    workspace: { id: ctx.ws.id, name: ctx.ws.name, role: ctx.ws.role, plan: planOf(ctx.ws).id, planName: planOf(ctx.ws).name },
    unreadNotifications: count('SELECT COUNT(*) n FROM notifications WHERE workspace_id = ? AND read = 0', ctx.ws.id),
  }));
  route('PATCH', '/v1/me', ({ ctx, body }) => {
    if (body.timezone && !validTimezone(body.timezone)) throw new HttpError(422, 'Unknown timezone');
    const settings = { ...J.parse(ctx.user.settings, {}), ...(body.settings && typeof body.settings === 'object' ? body.settings : {}) };
    db.prepare('UPDATE users SET name = ?, timezone = ?, settings = ? WHERE id = ?').run(body.name != null ? String(body.name).slice(0, 80) : ctx.user.name, body.timezone || ctx.user.timezone, J.str(settings), ctx.user.id);
    return userOut(db.prepare('SELECT * FROM users WHERE id = ?').get(ctx.user.id));
  });
  route('POST', '/v1/me/password', async ({ ctx, body }) => {
    if (!(await verifyPassword(body.current, ctx.user.password_hash))) throw new HttpError(401, 'Current password is incorrect.');
    const pwErr = passwordProblem(body.password);
    if (pwErr) throw new HttpError(422, pwErr);
    db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(await hashPassword(body.password), ctx.user.id);
    db.prepare('DELETE FROM user_sessions WHERE user_id = ? AND token_hash != ?').run(ctx.user.id, ctx.session.token_hash);
    audit(ctx, 'auth.password_change');
    return { ok: true, message: 'Password changed. Other devices were signed out.' };
  });
  route('GET', '/v1/me/sessions', ({ ctx }) => db.prepare('SELECT token_hash, created_at, last_seen, agent FROM user_sessions WHERE user_id = ? AND expires_at > ? ORDER BY last_seen DESC').all(ctx.user.id, clock())
    .map((s) => ({ id: s.token_hash.slice(0, 12), createdAt: s.created_at, lastSeen: s.last_seen, device: s.agent, current: s.token_hash === ctx.session.token_hash })));
  route('DELETE', '/v1/me/sessions/:sid', ({ ctx, p }) => {
    db.prepare('DELETE FROM user_sessions WHERE user_id = ? AND substr(token_hash, 1, 12) = ?').run(ctx.user.id, p.sid);
    return { ok: true };
  });
  route('GET', '/v1/me/export', ({ ctx }) => {
    const ws = ctx.ws.id;
    audit(ctx, 'account.export');
    return {
      exportedAt: new Date(clock()).toISOString(), user: userOut(ctx.user),
      automations: db.prepare('SELECT * FROM automations WHERE workspace_id = ?').all(ws).map(autoRow),
      connections: db.prepare('SELECT id, integration, label, identity, status, created_at FROM connections WHERE workspace_id = ?').all(ws),
      webhooks: db.prepare('SELECT id, name, enabled, created_at FROM webhooks WHERE workspace_id = ?').all(ws),
      executions: db.prepare('SELECT id, seq, automation_id, status, trigger_type, started_at, ended_at, error FROM executions WHERE workspace_id = ? ORDER BY started_at DESC LIMIT 5000').all(ws),
      note: 'Connection secrets are never exported.',
    };
  });
  route('DELETE', '/v1/me', async ({ ctx, body }) => {
    if (!(await verifyPassword(body.password, ctx.user.password_hash))) throw new HttpError(401, 'Password is incorrect.');
    tx(db, () => {
      db.prepare('DELETE FROM workspaces WHERE owner_id = ?').run(ctx.user.id);
      db.prepare('DELETE FROM users WHERE id = ?').run(ctx.user.id);
    });
    audit({ user: ctx.user, ip: ctx.ip }, 'account.delete');
    return { ok: true, message: 'Your account and all its automations, connections and history were deleted.' };
  });

  // ------------------------------------------------------------ integrations & connections
  route('GET', '/v1/integrations', () => catalog(env), { public: true });
  route('GET', '/v1/connections', ({ ctx }) => db.prepare('SELECT * FROM connections WHERE workspace_id = ? ORDER BY created_at').all(ctx.ws.id).map(connOut));
  const providerCtx = () => ({ fetch: fetchImpl, env });
  async function verifyConnect(integ, fields) {
    if (!integ?.connect) throw new HttpError(422, 'This app doesn\'t need a connection.');
    try { return await integ.connect(fields || {}, providerCtx()); } catch (e) {
      if (e instanceof ActionError) throw new HttpError(422, e.message, { fix: e.fix });
      throw e;
    }
  }
  route('POST', '/v1/connections', async ({ ctx, body }) => {
    const integ = INTEGRATIONS[body.integration];
    if (!integ || integ.auth.type === 'none') throw new HttpError(422, 'Unknown app');
    if (integ.auth.type === 'oauth') throw new HttpError(422, 'This app connects through its sign-in page.');
    limitCheck(ctx.ws, 'connections', count('SELECT COUNT(*) n FROM connections WHERE workspace_id = ?', ctx.ws.id), 'connections');
    const r = await verifyConnect(integ, body.fields);
    const id = newId('c_');
    db.prepare('INSERT INTO connections (id, workspace_id, integration, label, identity, status, scopes, secret_enc, meta, last_ok_at, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)')
      .run(id, ctx.ws.id, integ.id, String(body.label || integ.name).slice(0, 60), r.identity || '', 'connected', J.str(r.scopes || []), r.secret ? encrypt(r.secret, secret) : null, J.str(r.meta || {}), clock(), clock());
    audit(ctx, 'connection.create', id, { integration: integ.id });
    return connOut(own('connections', id, ctx.ws));
  });
  route('POST', '/v1/connections/:id/test', async ({ ctx, p }) => {
    const c = engine.connection(own('connections', p.id, ctx.ws).id, ctx.ws.id);
    const integ = INTEGRATIONS[c.integration];
    try {
      const r = await integ.test(c, providerCtx());
      db.prepare(`UPDATE connections SET status = 'connected', identity = ?, last_ok_at = ?, last_error = NULL WHERE id = ?`).run(r.identity || c.identity, clock(), c.id);
      return { ok: true, message: `${integ.name} is working (${r.identity}).`, connection: connOut(own('connections', c.id, ctx.ws)) };
    } catch (e) {
      const auth = e instanceof ActionError && e.kind === 'auth';
      db.prepare('UPDATE connections SET status = ?, last_error = ? WHERE id = ?').run(auth ? 'needs_reauth' : 'error', e.message, c.id);
      return { ok: false, message: e.message, fix: e.fix || null, connection: connOut(own('connections', c.id, ctx.ws)) };
    }
  });
  // ---- Google OAuth (Gmail). Authorization-code flow with PKCE + one-time state.
  route('POST', '/v1/oauth/:integration/start', ({ ctx, p, body }) => {
    const integ = INTEGRATIONS[p.integration];
    if (!integ || integ.auth.type !== 'oauth') throw new HttpError(404, 'Unknown app');
    if (!googleConfigured(env)) throw new HttpError(503, integ.unavailableReason || 'Not configured on this server.', { fix: 'The server operator must configure Google OAuth (see DEPLOY.md).' });
    let reconnectId = null;
    if (body.connectionId) reconnectId = own('connections', body.connectionId, ctx.ws).id;
    else limitCheck(ctx.ws, 'connections', count('SELECT COUNT(*) n FROM connections WHERE workspace_id = ?', ctx.ws.id), 'connections');
    const state = randomBytes(24).toString('base64url');
    const verifier = randomBytes(48).toString('base64url');
    const challenge = createHash('sha256').update(verifier).digest('base64url');
    db.prepare('DELETE FROM oauth_states WHERE expires_at < ?').run(clock());
    db.prepare('INSERT INTO oauth_states (state, workspace_id, user_id, integration, verifier, redirect, expires_at) VALUES (?,?,?,?,?,?,?)')
      .run(state, ctx.ws.id, ctx.user.id, integ.id, verifier, reconnectId, clock() + 10 * 60e3);
    audit(ctx, 'oauth.start', integ.id);
    return { url: googleAuthUrl(env, { state, challenge }), expiresInSeconds: 600 };
  });
  const page = (title, msg, ok) => ({ __html: `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><body style="font-family:system-ui;background:#0f1220;color:#e8eaf6;display:grid;place-items:center;min-height:90vh;text-align:center;padding:24px"><div><div style="font-size:48px">${ok ? '✅' : '⚠️'}</div><h2>${title}</h2><p>${msg}</p><p style="opacity:.7">You can close this page and return to Autometa.</p></div>` });
  const esc = (v) => String(v).replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);
  route('GET', '/oauth/google/callback', async ({ query }) => {
    const st = db.prepare('SELECT * FROM oauth_states WHERE state = ?').get(String(query.get('state') || ''));
    if (st) db.prepare('DELETE FROM oauth_states WHERE state = ?').run(st.state);
    if (!st || st.expires_at < clock()) return page('Link expired', 'This sign-in link is invalid or expired. Start again from the app.', false);
    if (query.get('error')) return page('Not connected', `Google said: ${esc(query.get('error'))}. Nothing was saved.`, false);
    const integ = INTEGRATIONS[st.integration];
    let r;
    try { r = await googleExchange(fetchImpl, env, { code: String(query.get('code') || ''), verifier: st.verifier, now: clock() }); } catch (e) {
      return page('Not connected', esc(e.message) + (e.fix ? ` ${esc(e.fix)}` : ''), false);
    }
    const ctx = { ws: { id: st.workspace_id }, user: { id: st.user_id } };
    let id = st.redirect;
    if (id && db.prepare('SELECT 1 FROM connections WHERE id = ? AND workspace_id = ?').get(id, st.workspace_id)) {
      db.prepare(`UPDATE connections SET status = 'connected', identity = ?, secret_enc = ?, scopes = ?, last_ok_at = ?, last_error = NULL WHERE id = ?`)
        .run(r.identity, encrypt(r.secret, secret), J.str(r.scopes), clock(), id);
      audit(ctx, 'connection.reconnect', id);
    } else {
      id = newId('c_');
      db.prepare('INSERT INTO connections (id, workspace_id, integration, label, identity, status, scopes, secret_enc, meta, last_ok_at, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)')
        .run(id, st.workspace_id, integ.id, integ.name, r.identity, 'connected', J.str(r.scopes), encrypt(r.secret, secret), '{}', clock(), clock());
      audit(ctx, 'connection.create', id, { integration: integ.id });
    }
    return page(`${integ.name} connected`, `Connected as ${esc(r.identity)}.`, true);
  }, { public: true });

  // ---- Device push tokens
  route('POST', '/v1/devices', ({ ctx, body }) => {
    const token = String(body.token || '').trim();
    if (token.length < 20 || token.length > 4096) throw new HttpError(422, 'Invalid device token');
    const prefs = J.str({ failures: body.prefs?.failures !== false, account: body.prefs?.account !== false, messages: body.prefs?.messages !== false });
    const ex = db.prepare('SELECT id FROM devices WHERE token = ?').get(token);
    if (ex) db.prepare('UPDATE devices SET user_id = ?, workspace_id = ?, prefs = ?, last_seen_at = ? WHERE id = ?').run(ctx.user.id, ctx.ws.id, prefs, clock(), ex.id);
    else db.prepare('INSERT INTO devices (id, user_id, workspace_id, platform, token, prefs, created_at, last_seen_at) VALUES (?,?,?,?,?,?,?,?)').run(newId('d_'), ctx.user.id, ctx.ws.id, body.platform === 'ios' ? 'ios' : 'android', token, prefs, clock(), clock());
    return { ok: true, pushConfigured: engine.push.configured };
  });
  route('DELETE', '/v1/devices', ({ ctx, body }) => {
    const n = db.prepare('DELETE FROM devices WHERE token = ? AND user_id = ?').run(String(body.token || ''), ctx.user.id).changes;
    return { ok: true, removed: n };
  });

  route('POST', '/v1/connections/:id/reconnect', async ({ ctx, p, body }) => {
    const c = own('connections', p.id, ctx.ws);
    if (INTEGRATIONS[c.integration]?.auth.type === 'oauth') throw new HttpError(422, 'Reconnect through the sign-in page.', { fix: 'Use POST /v1/oauth/:integration/start with connectionId.' });
    const r = await verifyConnect(INTEGRATIONS[c.integration], body.fields);
    db.prepare(`UPDATE connections SET status = 'connected', identity = ?, secret_enc = ?, meta = ?, scopes = ?, last_ok_at = ?, last_error = NULL WHERE id = ?`)
      .run(r.identity || '', r.secret ? encrypt(r.secret, secret) : null, J.str(r.meta || {}), J.str(r.scopes || []), clock(), c.id);
    // Automations paused only because of this connection can be resumed by the user.
    const affected = db.prepare(`SELECT id, name FROM automations WHERE workspace_id = ? AND status = 'error' AND (steps LIKE ? OR trigger LIKE ?)`).all(ctx.ws.id, `%${c.id}%`, `%${c.id}%`);
    audit(ctx, 'connection.reconnect', c.id);
    return { connection: connOut(own('connections', c.id, ctx.ws)), pausedAutomations: affected, message: affected.length ? `Reconnected. ${affected.length} paused automation(s) can be turned back on.` : 'Reconnected.' };
  });
  route('DELETE', '/v1/connections/:id', async ({ ctx, p }) => {
    const c = own('connections', p.id, ctx.ws);
    // Revoke at the provider first (Gmail). Best-effort: a provider outage
    // must never block the user from removing the connection here.
    let revoked = null;
    const integ = INTEGRATIONS[c.integration];
    if (integ?.revoke) {
      try { revoked = await integ.revoke(engine.connection(c.id, ctx.ws.id), providerCtx()); } catch { revoked = false; }
    }
    db.prepare('DELETE FROM connections WHERE id = ?').run(c.id);
    const affected = db.prepare(`SELECT id FROM automations WHERE workspace_id = ? AND (steps LIKE ? OR trigger LIKE ?) AND status = 'active'`).all(ctx.ws.id, `%${c.id}%`, `%${c.id}%`);
    for (const a of affected) db.prepare(`UPDATE automations SET status = 'paused', status_reason = ?, next_run_at = NULL WHERE id = ?`).run(`Paused: ${INTEGRATIONS[c.integration]?.name} was disconnected.`, a.id);
    audit(ctx, 'connection.delete', c.id);
    return { ok: true, pausedAutomations: affected.length, ...(revoked === null ? {} : { revokedAtProvider: revoked }) };
  });
  route('GET', '/v1/connections/:id/chats', async ({ ctx, p }) => {
    const c = engine.connection(own('connections', p.id, ctx.ws).id, ctx.ws.id);
    const integ = INTEGRATIONS[c.integration];
    if (!integ.listChats) throw new HttpError(422, 'Not supported for this app');
    try { return await integ.listChats(c, providerCtx()); } catch (e) { throw new HttpError(422, e.message, { fix: e.fix }); }
  });

  // ------------------------------------------------------------ automations
  route('GET', '/v1/automations', ({ ctx, query }) => {
    const status = query.get('status');
    const q = `%${(query.get('q') || '').toLowerCase()}%`;
    const rows = db.prepare(`SELECT * FROM automations WHERE workspace_id = ? ${status ? 'AND status = ?' : "AND status != 'archived'"} AND (lower(name) LIKE ? OR lower(description) LIKE ?) ORDER BY CASE status WHEN 'error' THEN 0 WHEN 'active' THEN 1 ELSE 2 END, updated_at DESC`)
      .all(...[ctx.ws.id, ...(status ? [status] : []), q, q]);
    return rows.map((r) => autoOut(ctx.ws, r));
  });
  route('POST', '/v1/automations', ({ ctx, body }) => {
    limitCheck(ctx.ws, 'automations', count(`SELECT COUNT(*) n FROM automations WHERE workspace_id = ? AND status != 'archived'`, ctx.ws.id), 'automations');
    const id = newId('a_');
    const tz = validTimezone(body.timezone) ? body.timezone : ctx.user.timezone;
    db.prepare('INSERT INTO automations (id, workspace_id, name, description, trigger, steps, timezone, retry, on_failure, max_runs_per_day, template_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)')
      .run(id, ctx.ws.id, String(body.name || 'Untitled automation').slice(0, 80), String(body.description || '').slice(0, 300), J.str(body.trigger || {}), J.str(cleanSteps(body.steps)), tz, J.str(body.retry || { policy: 'none' }), body.onFailure || 'pause_after_3', body.maxRunsPerDay || null, body.templateId || null, clock(), clock());
    setDerivedStatus(ctx.ws, id);
    audit(ctx, 'automation.create', id);
    return autoOut(ctx.ws, own('automations', id, ctx.ws), { detail: true });
  });
  route('GET', '/v1/automations/:id', ({ ctx, p }) => autoOut(ctx.ws, own('automations', p.id, ctx.ws), { detail: true }));
  route('PUT', '/v1/automations/:id', ({ ctx, p, body }) => {
    const a = autoRow(own('automations', p.id, ctx.ws));
    if (body.timezone && !validTimezone(body.timezone)) throw new HttpError(422, 'Unknown timezone');
    db.prepare('UPDATE automations SET name = ?, description = ?, trigger = ?, steps = ?, timezone = ?, retry = ?, on_failure = ?, max_runs_per_day = ?, updated_at = ? WHERE id = ?')
      .run(body.name != null ? String(body.name).slice(0, 80) : a.name, body.description != null ? String(body.description).slice(0, 300) : a.description, J.str(body.trigger ?? a.trigger), J.str(body.steps ? cleanSteps(body.steps) : a.steps),
        body.timezone || a.timezone, J.str(body.retry ?? a.retry), body.onFailure || a.on_failure, body.maxRunsPerDay !== undefined ? body.maxRunsPerDay || null : a.max_runs_per_day, clock(), a.id);
    setDerivedStatus(ctx.ws, a.id);
    audit(ctx, 'automation.update', a.id);
    return autoOut(ctx.ws, own('automations', a.id, ctx.ws), { detail: true });
  });
  route('POST', '/v1/automations/:id/validate', ({ ctx, p }) => validationFor(ctx.ws, autoRow(own('automations', p.id, ctx.ws))));
  route('POST', '/v1/automations/:id/activate', ({ ctx, p }) => {
    const a = autoRow(own('automations', p.id, ctx.ws));
    const v = validationFor(ctx.ws, a);
    if (!v.ok) throw new HttpError(422, 'Fix the items below before activating.', { validation: v });
    db.prepare(`UPDATE automations SET status = 'active', status_reason = NULL, consecutive_failures = 0, next_run_at = ?, updated_at = ?, trigger_state = ?, next_poll_at = NULL WHERE id = ?`).run(engine.schedule(a), clock(), J.str({ cursor: clock() }), a.id);
    audit(ctx, 'automation.activate', a.id);
    return autoOut(ctx.ws, own('automations', a.id, ctx.ws), { detail: true });
  });
  route('POST', '/v1/automations/:id/pause', ({ ctx, p }) => {
    own('automations', p.id, ctx.ws);
    db.prepare(`UPDATE automations SET status = 'paused', status_reason = 'Paused by you.', next_run_at = NULL, updated_at = ? WHERE id = ?`).run(clock(), p.id);
    audit(ctx, 'automation.pause', p.id);
    return autoOut(ctx.ws, own('automations', p.id, ctx.ws), { detail: true });
  });
  route('POST', '/v1/automations/:id/archive', ({ ctx, p }) => {
    own('automations', p.id, ctx.ws);
    db.prepare(`UPDATE automations SET status = 'archived', next_run_at = NULL, updated_at = ? WHERE id = ?`).run(clock(), p.id);
    return { ok: true };
  });
  route('POST', '/v1/automations/:id/duplicate', ({ ctx, p }) => {
    const a = autoRow(own('automations', p.id, ctx.ws));
    limitCheck(ctx.ws, 'automations', count(`SELECT COUNT(*) n FROM automations WHERE workspace_id = ? AND status != 'archived'`, ctx.ws.id), 'automations');
    const id = newId('a_');
    db.prepare('INSERT INTO automations (id, workspace_id, name, description, trigger, steps, timezone, retry, on_failure, max_runs_per_day, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)')
      .run(id, ctx.ws.id, `${a.name} (copy)`.slice(0, 80), a.description, J.str(a.trigger), J.str(a.steps), a.timezone, J.str(a.retry), a.on_failure, a.max_runs_per_day, clock(), clock());
    setDerivedStatus(ctx.ws, id);
    return autoOut(ctx.ws, own('automations', id, ctx.ws), { detail: true });
  });
  route('DELETE', '/v1/automations/:id', ({ ctx, p }) => {
    own('automations', p.id, ctx.ws);
    db.prepare('DELETE FROM automations WHERE id = ?').run(p.id);
    audit(ctx, 'automation.delete', p.id);
    return { ok: true };
  });
  route('POST', '/v1/automations/:id/run', async ({ ctx, p, body }) => {
    const a = autoRow(own('automations', p.id, ctx.ws));
    const v = validationFor(ctx.ws, a);
    if (!v.ok) throw new HttpError(422, 'Fix the items below before running.', { validation: v });
    if (!limiter.hit(`run:${a.id}`, 10, 60e3)) throw new HttpError(429, 'Slow down: at most 10 manual runs a minute.');
    const ex = engine.start(a, { triggerType: 'manual', data: body.payload ? { payload: body.payload } : {} });
    await engine.drain(3);
    return execOut(db.prepare('SELECT * FROM executions WHERE id = ?').get(ex.id), true);
  });
  route('POST', '/v1/automations/:id/test', async ({ ctx, p, body }) => {
    const a = autoRow(own('automations', p.id, ctx.ws));
    const live = body.live === true;
    if (live && body.confirm !== true) throw new HttpError(400, 'Live tests perform real actions. Confirm to continue.');
    if (!limiter.hit(`test:${a.id}`, 20, 60e3)) throw new HttpError(429, 'Slow down: at most 20 tests a minute.');
    if (live) { const v = validationFor(ctx.ws, a); if (!v.ok) throw new HttpError(422, 'Fix the items below before a live test.', { validation: v }); }
    const sample = body.payload ?? sampleFor(a);
    const ex = engine.start(a, { triggerType: 'test', data: { payload: sample, ...(sample?.email ? { email: sample.email } : {}) }, isTest: true, live });
    await engine.drain(5);
    return execOut(db.prepare('SELECT * FROM executions WHERE id = ?').get(ex.id), true);
  });
  route('POST', '/v1/automations/:id/steps/:sid/test', async ({ ctx, p, body }) => {
    const a = autoRow(own('automations', p.id, ctx.ws));
    const step = a.steps.find((s) => s.id === p.sid);
    if (!step) throw new HttpError(404, 'Step not found');
    const live = body.live === true;
    if (live && body.confirm !== true) throw new HttpError(400, 'Live tests perform real actions. Confirm to continue.');
    const single = { ...a, steps: [{ ...step, enabled: true }] };
    const ex = engine.start(single, { triggerType: 'test', data: { payload: body.payload ?? sampleFor(a) }, isTest: true, live });
    // The engine reads steps from the DB; run this one against an in-memory copy.
    const orig = engine.automation.bind(engine);
    engine.automation = (id) => (id === a.id ? { ...orig(id), steps: single.steps } : orig(id));
    try { await engine.runExecution(ex.id); } finally { engine.automation = orig; }
    db.prepare('UPDATE cloud_jobs SET done = 1 WHERE execution_id = ?').run(ex.id);
    return execOut(db.prepare('SELECT * FROM executions WHERE id = ?').get(ex.id), true);
  });
  function sampleFor(a) {
    if (a.trigger?.integration === 'webhook') {
      const last = db.prepare('SELECT r.payload FROM webhook_requests r JOIN webhooks w ON w.id = r.webhook_id WHERE w.id = ? ORDER BY r.id DESC LIMIT 1').get(a.trigger.config?.webhookId || '');
      return last ? J.parse(last.payload, {}) : { event: 'test', name: 'Jane', priority: 'high' };
    }
    if (a.trigger?.integration === 'gmail') {
      return { email: { id: 'sample', from: 'Billing <billing@example.com>', fromEmail: 'billing@example.com', to: 'you@example.com', subject: 'Your invoice is ready', snippet: 'Sample email used for testing', date: new Date(clock()).toUTCString() } };
    }
    return {};
  }

  // ------------------------------------------------------------ executions
  route('GET', '/v1/executions', ({ ctx, query }) => {
    const status = query.get('status');
    const automation = query.get('automation');
    const before = Number(query.get('before')) || clock() + 1;
    const q = query.get('q') ? `%${query.get('q').toLowerCase()}%` : null;
    const historyFrom = clock() - planOf(ctx.ws).limits.historyDays * 864e5;
    return db.prepare(`SELECT e.* FROM executions e JOIN automations a ON a.id = e.automation_id WHERE e.workspace_id = ? AND e.started_at < ? AND e.started_at >= ?
        ${status === 'failed' ? "AND e.status IN ('failed','partial')" : status ? 'AND e.status = ?' : ''} ${automation ? 'AND e.automation_id = ?' : ''} ${q ? 'AND (lower(a.name) LIKE ? OR lower(COALESCE(e.error, \'\')) LIKE ?)' : ''}
        ORDER BY e.started_at DESC LIMIT 50`)
      .all(...[ctx.ws.id, before, historyFrom, ...(status && status !== 'failed' ? [status] : []), ...(automation ? [automation] : []), ...(q ? [q, q] : [])]).map((e) => execOut(e));
  });
  route('GET', '/v1/executions/:id', ({ ctx, p }) => execOut(own('executions', p.id, ctx.ws), true));
  route('POST', '/v1/executions/:id/retry', async ({ ctx, p }) => {
    const e = own('executions', p.id, ctx.ws);
    if (!['failed', 'partial'].includes(e.status) || e.is_test) throw new HttpError(422, 'Only failed live runs can be retried.');
    // Resume at the failed step. Steps that already succeeded have receipts and are not repeated.
    db.prepare(`UPDATE execution_steps SET status = 'retrying' WHERE execution_id = ? AND status = 'failed'`).run(e.id);
    db.prepare(`UPDATE executions SET status = 'running', ended_at = NULL, error = NULL, retry_count = retry_count + 1 WHERE id = ?`).run(e.id);
    engine.addJob('resume', e.id, clock());
    await engine.drain(3);
    audit(ctx, 'execution.retry', e.id);
    return execOut(own('executions', e.id, ctx.ws), true);
  });
  route('POST', '/v1/executions/:id/cancel', ({ ctx, p }) => {
    const e = own('executions', p.id, ctx.ws);
    if (e.status !== 'running') throw new HttpError(422, 'Only running executions can be cancelled.');
    db.prepare(`UPDATE executions SET status = 'cancelled', ended_at = ?, error = 'Cancelled by you' WHERE id = ?`).run(clock(), e.id);
    db.prepare('UPDATE cloud_jobs SET done = 1 WHERE execution_id = ?').run(e.id);
    db.prepare(`UPDATE execution_steps SET status = 'cancelled', ended_at = ? WHERE execution_id = ? AND status IN ('waiting','retrying','running')`).run(clock(), e.id);
    return execOut(own('executions', e.id, ctx.ws), true);
  });

  // ------------------------------------------------------------ webhooks
  const publicBase = (req) => env.PUBLIC_URL || `https://${req.headers['x-forwarded-host'] || req.headers.host}`;
  route('GET', '/v1/webhooks', ({ ctx, req }) => db.prepare('SELECT * FROM webhooks WHERE workspace_id = ? ORDER BY created_at').all(ctx.ws.id).map((w) => webhookOut(w, publicBase(req))));
  route('POST', '/v1/webhooks', ({ ctx, body, req }) => {
    limitCheck(ctx.ws, 'webhooks', count('SELECT COUNT(*) n FROM webhooks WHERE workspace_id = ?', ctx.ws.id), 'webhooks');
    const id = newId('h_');
    const sec = body.requireSecret === false ? null : newToken();
    db.prepare('INSERT INTO webhooks (id, public_id, workspace_id, name, secret_hash, created_at) VALUES (?,?,?,?,?,?)').run(id, newToken().slice(0, 24), ctx.ws.id, String(body.name || 'Webhook').slice(0, 60), sec ? sha256(sec) : null, clock());
    audit(ctx, 'webhook.create', id);
    return { ...webhookOut(own('webhooks', id, ctx.ws), publicBase(req)), secret: sec, secretNotice: sec ? 'Copy this secret now. It won\'t be shown again.' : null };
  });
  route('GET', '/v1/webhooks/:id', ({ ctx, p, req }) => {
    const w = own('webhooks', p.id, ctx.ws);
    return {
      ...webhookOut(w, publicBase(req)),
      automations: db.prepare(`SELECT id, name, status FROM automations WHERE workspace_id = ? AND json_extract(trigger, '$.config.webhookId') = ?`).all(ctx.ws.id, w.id),
      requests: db.prepare('SELECT id, received_at receivedAt, status, outcome, headers, payload, execution_id executionId, is_test isTest FROM webhook_requests WHERE webhook_id = ? ORDER BY id DESC LIMIT 30').all(w.id)
        .map((r) => ({ ...r, headers: J.parse(r.headers, {}), payload: J.parse(r.payload, r.payload) })),
    };
  });
  route('PATCH', '/v1/webhooks/:id', ({ ctx, p, body, req }) => {
    const w = own('webhooks', p.id, ctx.ws);
    db.prepare('UPDATE webhooks SET name = ?, enabled = ? WHERE id = ?').run(body.name != null ? String(body.name).slice(0, 60) : w.name, body.enabled == null ? w.enabled : body.enabled ? 1 : 0, w.id);
    return webhookOut(own('webhooks', w.id, ctx.ws), publicBase(req));
  });
  route('POST', '/v1/webhooks/:id/secret', ({ ctx, p, body, req }) => {
    const w = own('webhooks', p.id, ctx.ws);
    const sec = body.remove === true ? null : newToken();
    db.prepare('UPDATE webhooks SET secret_hash = ? WHERE id = ?').run(sec ? sha256(sec) : null, w.id);
    audit(ctx, sec ? 'webhook.secret_rotate' : 'webhook.secret_remove', w.id);
    return { ...webhookOut(own('webhooks', w.id, ctx.ws), publicBase(req)), secret: sec, secretNotice: sec ? 'Copy this secret now. The old secret stopped working.' : 'Secret removed: anyone with the URL can trigger it.' };
  });
  route('POST', '/v1/webhooks/:id/rotate-url', ({ ctx, p, req }) => {
    const w = own('webhooks', p.id, ctx.ws);
    db.prepare('UPDATE webhooks SET public_id = ? WHERE id = ?').run(newToken().slice(0, 24), w.id);
    audit(ctx, 'webhook.url_rotate', w.id);
    return webhookOut(own('webhooks', w.id, ctx.ws), publicBase(req));
  });
  route('DELETE', '/v1/webhooks/:id', ({ ctx, p }) => { own('webhooks', p.id, ctx.ws); db.prepare('DELETE FROM webhooks WHERE id = ?').run(p.id); audit(ctx, 'webhook.delete', p.id); return { ok: true }; });
  route('POST', '/v1/webhooks/:id/test', async ({ ctx, p, body }) => {
    const w = own('webhooks', p.id, ctx.ws);
    return receiveHook(w, body.payload ?? { event: 'test', name: 'Jane', priority: 'high' }, { 'content-type': 'application/json' }, { isTest: true });
  });

  async function receiveHook(w, payload, headers, { isTest = false } = {}) {
    const autos = db.prepare(`SELECT * FROM automations WHERE workspace_id = ? AND json_extract(trigger, '$.config.webhookId') = ? AND json_extract(trigger, '$.integration') = 'webhook' AND ${isTest ? "status != 'archived'" : "status = 'active'"}`).all(w.workspace_id, w.id);
    const execIds = [];
    for (const a of autos) {
      const ex = engine.start(autoRow(a), { triggerType: isTest ? 'test' : 'webhook', data: { payload, headers }, isTest, live: false });
      execIds.push(ex.id);
    }
    if (!isTest) engine.bump(w.workspace_id, 'webhook_events');
    db.prepare('UPDATE webhooks SET request_count = request_count + ?, last_received_at = ? WHERE id = ?').run(isTest ? 0 : 1, clock(), w.id);
    const outcome = autos.length ? `Started ${autos.length} automation${autos.length > 1 ? 's' : ''}` : 'Received. No active automation uses this webhook.';
    db.prepare('INSERT INTO webhook_requests (webhook_id, received_at, status, outcome, headers, payload, execution_id, is_test) VALUES (?,?,?,?,?,?,?,?)')
      .run(w.id, clock(), 202, outcome, J.str(headers), J.str(payload), execIds[0] || null, isTest ? 1 : 0);
    db.prepare('DELETE FROM webhook_requests WHERE webhook_id = ? AND id NOT IN (SELECT id FROM webhook_requests WHERE webhook_id = ? ORDER BY id DESC LIMIT 100)').run(w.id, w.id);
    if (execIds.length) await engine.drain(3);
    return { accepted: true, outcome, executionIds: execIds };
  }

  route('POST', '/hooks/:publicId', async ({ p, req, raw, ip }) => {
    const w = db.prepare('SELECT * FROM webhooks WHERE public_id = ?').get(p.publicId);
    if (!w) throw new HttpError(404, 'Unknown webhook');
    if (!w.enabled) throw new HttpError(410, 'This webhook is disabled');
    if (!limiter.hit(`hook:${w.id}`, Number(env.WEBHOOK_RATE_PER_MIN || 60), 60e3) || !limiter.hit(`hookip:${ip}`, 300, 60e3)) throw new HttpError(429, 'Too many requests');
    const log = (status, outcome) => db.prepare('INSERT INTO webhook_requests (webhook_id, received_at, status, outcome) VALUES (?,?,?,?)').run(w.id, clock(), status, outcome);
    if (w.secret_hash) {
      const given = req.headers['x-autometa-secret'] || new URL(req.url, 'http://x').searchParams.get('secret') || '';
      if (sha256(given) !== w.secret_hash) { log(401, 'Rejected: missing or wrong secret'); throw new HttpError(401, 'Invalid secret'); }
    }
    if (raw.length > MAX_HOOK_BYTES) { log(413, 'Rejected: payload over 256 KB'); throw new HttpError(413, 'Payload too large'); }
    const ws = db.prepare('SELECT * FROM workspaces WHERE id = ?').get(w.workspace_id);
    const used = engine.usage(w.workspace_id, 'executions');
    const lim = planOf(ws).limits.executionsPerMonth;
    if (lim != null && used >= lim) { log(429, 'Rejected: monthly execution limit reached'); throw new HttpError(429, 'Execution limit reached for this workspace'); }
    const text = raw.toString('utf8');
    let payload;
    try { payload = text ? JSON.parse(text) : {}; } catch {
      payload = (req.headers['content-type'] || '').includes('x-www-form-urlencoded') ? Object.fromEntries(new URLSearchParams(text)) : { body: text };
    }
    const safeHeaders = Object.fromEntries(Object.entries(req.headers).filter(([k]) => !/authorization|cookie|secret|token|signature/i.test(k)).slice(0, 30));
    return receiveHook(w, payload, safeHeaders);
  }, { public: true, raw: true, status: 202 });

  // ------------------------------------------------------------ templates
  route('GET', '/v1/templates', () => CLOUD_TEMPLATES.map((t) => ({ ...t, starter: STARTERS.includes(t.id), summary: summary(t.automation), steps: t.automation.steps.length })), { public: true });
  route('POST', '/v1/templates/:id/install', ({ ctx, p, body }) => {
    const t = CLOUD_TEMPLATES.find((x) => x.id === p.id);
    if (!t) throw new HttpError(404, 'Template not found');
    limitCheck(ctx.ws, 'automations', count(`SELECT COUNT(*) n FROM automations WHERE workspace_id = ? AND status != 'archived'`, ctx.ws.id), 'automations');
    const a = structuredClone(t.automation);
    // Pre-fill connections the user already has.
    for (const s of a.steps) {
      if (s.type === 'action' && INTEGRATIONS[s.integration]?.auth.type !== 'none') {
        const c = db.prepare(`SELECT id FROM connections WHERE workspace_id = ? AND integration = ? AND status = 'connected' ORDER BY created_at LIMIT 1`).get(ctx.ws.id, s.integration);
        if (c) s.connectionId = c.id;
      }
    }
    if (a.trigger.integration === 'webhook') {
      const wh = body.webhookId ? own('webhooks', body.webhookId, ctx.ws) : db.prepare('SELECT id FROM webhooks WHERE workspace_id = ? ORDER BY created_at LIMIT 1').get(ctx.ws.id);
      if (wh) a.trigger.config.webhookId = wh.id;
    }
    const id = newId('a_');
    db.prepare('INSERT INTO automations (id, workspace_id, name, description, trigger, steps, timezone, template_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)')
      .run(id, ctx.ws.id, a.name, t.description, J.str(a.trigger), J.str(cleanSteps(a.steps)), ctx.user.timezone, t.id, clock(), clock());
    setDerivedStatus(ctx.ws, id);
    audit(ctx, 'template.install', id, { template: t.id });
    return autoOut(ctx.ws, own('automations', id, ctx.ws), { detail: true });
  });

  // ------------------------------------------------------------ dashboard, usage, notifications, search
  route('GET', '/v1/dashboard', ({ ctx }) => {
    const ws = ctx.ws.id;
    const dayStart = clock() - 864e5;
    const today = db.prepare(`SELECT COUNT(*) n, SUM(status='success') ok, SUM(status IN ('failed','partial')) bad FROM executions WHERE workspace_id = ? AND started_at >= ? AND is_test = 0 AND status != 'skipped'`).get(ws, dayStart);
    const month30 = db.prepare(`SELECT COUNT(*) n, SUM(status='success') ok FROM executions WHERE workspace_id = ? AND started_at >= ? AND is_test = 0 AND status NOT IN ('skipped','running')`).get(ws, clock() - 30 * 864e5);
    return {
      greetingName: ctx.user.name || ctx.user.email.split('@')[0],
      timezone: ctx.user.timezone,
      totals: {
        automations: count(`SELECT COUNT(*) n FROM automations WHERE workspace_id = ? AND status != 'archived'`, ws),
        active: count(`SELECT COUNT(*) n FROM automations WHERE workspace_id = ? AND status = 'active'`, ws),
        needsAttention: count(`SELECT COUNT(*) n FROM automations WHERE workspace_id = ? AND status = 'error'`, ws),
        executionsToday: today.n || 0, successToday: today.ok || 0, failedToday: today.bad || 0,
        successRate30d: month30.n ? Math.round((month30.ok / month30.n) * 1000) / 10 : null,
        connectedApps: count(`SELECT COUNT(*) n FROM connections WHERE workspace_id = ? AND status = 'connected'`, ws),
        connectionsNeedingAttention: count(`SELECT COUNT(*) n FROM connections WHERE workspace_id = ? AND status != 'connected'`, ws),
      },
      upcoming: db.prepare(`SELECT * FROM automations WHERE workspace_id = ? AND status = 'active' AND next_run_at IS NOT NULL ORDER BY next_run_at LIMIT 6`).all(ws)
        .map((r) => { const a = autoRow(r); return { id: a.id, name: a.name, at: a.next_run_at, providers: summary(a).providers, action: summary(a).action }; }),
      recent: db.prepare('SELECT * FROM executions WHERE workspace_id = ? ORDER BY started_at DESC LIMIT 8').all(ws).map((e) => execOut(e)),
      attention: db.prepare(`SELECT id, name, status_reason reason FROM automations WHERE workspace_id = ? AND status = 'error' LIMIT 5`).all(ws),
      usage: usageSummary(ctx.ws),
    };
  });
  function usageSummary(wsRow) {
    const plan = planOf(wsRow);
    const ws = wsRow.id;
    const m = (metric, limit) => ({ used: engine.usage(ws, metric), limit });
    return {
      plan: plan.id, planName: plan.name, month: new Date(clock()).toISOString().slice(0, 7),
      executions: m('executions', plan.limits.executionsPerMonth),
      actions: m('actions', null),
      webhookEvents: m('webhook_events', null),
      automations: { used: count(`SELECT COUNT(*) n FROM automations WHERE workspace_id = ? AND status != 'archived'`, ws), limit: plan.limits.automations },
      webhooks: { used: count('SELECT COUNT(*) n FROM webhooks WHERE workspace_id = ?', ws), limit: plan.limits.webhooks },
      connections: { used: count('SELECT COUNT(*) n FROM connections WHERE workspace_id = ?', ws), limit: plan.limits.connections },
      logRows: { used: count('SELECT COUNT(*) n FROM executions WHERE workspace_id = ?', ws), limit: null, historyDays: plan.limits.historyDays },
    };
  }
  route('GET', '/v1/usage', ({ ctx }) => ({
    ...usageSummary(ctx.ws),
    history: db.prepare('SELECT month, metric, count FROM usage_records WHERE workspace_id = ? ORDER BY month DESC LIMIT 36').all(ctx.ws.id),
  }));
  route('GET', '/v1/notifications', ({ ctx }) => db.prepare('SELECT * FROM notifications WHERE workspace_id = ? ORDER BY created_at DESC LIMIT 100').all(ctx.ws.id)
    .map((n) => ({ id: n.id, kind: n.kind, severity: n.severity, title: n.title, body: n.body, action: J.parse(n.action, null), target: n.target, read: !!n.read, createdAt: n.created_at })));
  route('POST', '/v1/notifications/read', ({ ctx, body }) => {
    if (body.all) db.prepare('UPDATE notifications SET read = 1 WHERE workspace_id = ?').run(ctx.ws.id);
    else for (const id of (body.ids || []).slice(0, 200)) db.prepare('UPDATE notifications SET read = 1 WHERE id = ? AND workspace_id = ?').run(id, ctx.ws.id);
    return { ok: true };
  });
  route('GET', '/v1/search', ({ ctx, query }) => {
    const raw = String(query.get('q') || '').trim().toLowerCase();
    if (raw.length < 2) return { results: [] };
    const q = `%${raw}%`;
    const ws = ctx.ws.id;
    const results = [
      ...db.prepare(`SELECT id, name, status FROM automations WHERE workspace_id = ? AND status != 'archived' AND (lower(name) LIKE ? OR lower(description) LIKE ? OR lower(steps) LIKE ?) LIMIT 8`).all(ws, q, q, q).map((a) => ({ type: 'automation', id: a.id, title: a.name, subtitle: `Automation · ${a.status}` })),
      ...CLOUD_TEMPLATES.filter((t) => `${t.name} ${t.description} ${t.category}`.toLowerCase().includes(raw)).slice(0, 6).map((t) => ({ type: 'template', id: t.id, title: t.name, subtitle: `Template · ${t.category}` })),
      ...db.prepare('SELECT id, integration, label, identity, status FROM connections WHERE workspace_id = ? AND (lower(label) LIKE ? OR lower(identity) LIKE ? OR lower(integration) LIKE ?) LIMIT 5').all(ws, q, q, q).map((c) => ({ type: 'connection', id: c.id, title: `${INTEGRATIONS[c.integration]?.name} ${c.identity}`.trim(), subtitle: `Connection · ${c.status}` })),
      ...catalog().flatMap((i) => [...i.triggers.map((t) => ({ ...t, kind: 'trigger' })), ...i.actions.map((x) => ({ ...x, kind: 'action' }))].filter((x) => `${i.name} ${x.label} ${x.description}`.toLowerCase().includes(raw)).map((x) => ({ type: x.kind, id: `${i.id}.${x.key}`, title: `${i.name}: ${x.label}`, subtitle: x.kind === 'trigger' ? 'Trigger' : 'Action' }))).slice(0, 6),
      ...db.prepare(`SELECT e.id, e.seq, e.status, e.started_at, a.name FROM executions e JOIN automations a ON a.id = e.automation_id WHERE e.workspace_id = ? AND (lower(a.name) LIKE ? OR lower(COALESCE(e.error,'')) LIKE ?) ORDER BY e.started_at DESC LIMIT 5`).all(ws, q, q).map((e) => ({ type: 'execution', id: e.id, title: `${e.name} #${e.seq}`, subtitle: `Execution · ${e.status}` })),
    ];
    return { results };
  });

  // ------------------------------------------------------------ billing
  route('GET', '/v1/billing', ({ ctx }) => {
    const prices = pricing(env).cloud || {};
    return {
      current: { plan: planOf(ctx.ws).id, status: ctx.ws.plan_status, periodEnd: ctx.ws.plan_period_end },
      plans: Object.values(CLOUD_PLANS).map((p) => ({ ...p, price: prices[p.id] || null })),
      currency: pricing(env).currency, googlePlay: play.configured, usage: usageSummary(ctx.ws),
    };
  });
  route('POST', '/v1/billing/google/verify', async ({ ctx, body }) => {
    if (ctx.ws.role !== 'owner') throw new HttpError(403, 'Only the workspace owner can change the plan.');
    const prices = pricing(env).cloud || {};
    const map = (pid) => Object.keys(prices).find((k) => prices[k].googlePlayProductId === pid) || null;
    let r;
    try { r = await play.verify(String(body.purchaseToken || ''), map); } catch (e) { throw new HttpError(e.status || 400, e.message); }
    db.prepare('UPDATE workspaces SET plan = ?, plan_status = ?, plan_period_end = ? WHERE id = ?').run(r.plan, r.status === 'grace' ? 'active' : r.status, r.periodEnd, ctx.ws.id);
    audit(ctx, 'billing.google_play', null, { plan: r.plan, status: r.status });
    return { plan: r.plan, status: r.status, periodEnd: r.periodEnd };
  });

  // ------------------------------------------------------------ admin (operator only, X-Admin-Key)
  const admin = (method, path, h) => route(method, path, (args) => {
    if (!env.ADMIN_KEY || args.req.headers['x-admin-key'] !== env.ADMIN_KEY) throw new HttpError(403, 'Admin key required');
    return h(args);
  }, { public: true });
  admin('GET', '/v1/admin/overview', () => ({
    users: count('SELECT COUNT(*) n FROM users'), workspaces: count('SELECT COUNT(*) n FROM workspaces'),
    plans: db.prepare('SELECT plan, COUNT(*) n FROM workspaces GROUP BY plan').all(),
    activeAutomations: count(`SELECT COUNT(*) n FROM automations WHERE status = 'active'`),
    executions24h: db.prepare(`SELECT status, COUNT(*) n FROM executions WHERE started_at > ? GROUP BY status`).all(clock() - 864e5),
    queue: { pending: count('SELECT COUNT(*) n FROM cloud_jobs WHERE done = 0'), overdue: count('SELECT COUNT(*) n FROM cloud_jobs WHERE done = 0 AND due_at < ?', clock() - 120e3) },
    connectionsNeedingReauth: count(`SELECT COUNT(*) n FROM connections WHERE status = 'needs_reauth'`),
    integrations: db.prepare('SELECT integration, status, COUNT(*) n FROM connections GROUP BY integration, status').all(),
  }));
  admin('GET', '/v1/admin/users', ({ query }) => db.prepare(`SELECT u.id, u.email, u.name, u.disabled, u.created_at createdAt, w.id workspaceId, w.plan, w.plan_status planStatus,
      (SELECT COUNT(*) FROM automations a WHERE a.workspace_id = w.id) automations FROM users u LEFT JOIN workspaces w ON w.owner_id = u.id WHERE u.email LIKE ? ORDER BY u.created_at DESC LIMIT 200`).all(`%${query.get('q') || ''}%`));
  admin('POST', '/v1/admin/users/:id/disable', ({ p, body }) => {
    db.prepare('UPDATE users SET disabled = ? WHERE id = ?').run(body.disabled === false ? 0 : 1, p.id);
    if (body.disabled !== false) {
      db.prepare('DELETE FROM user_sessions WHERE user_id = ?').run(p.id);
      db.prepare(`UPDATE automations SET status = 'paused', status_reason = 'Paused by Autometa support.', next_run_at = NULL WHERE status = 'active' AND workspace_id IN (SELECT id FROM workspaces WHERE owner_id = ?)`).run(p.id);
    }
    return { ok: true };
  });
  admin('POST', '/v1/admin/users/:id/reset-link', ({ p }) => {
    const token = newToken();
    db.prepare('INSERT INTO password_resets (token_hash, user_id, expires_at) VALUES (?,?,?)').run(sha256(token), p.id, clock() + 3600e3);
    return { token, link: `${env.PUBLIC_APP_URL || env.PUBLIC_URL || ''}/reset?token=${token}`, expiresInMinutes: 60 };
  });
  admin('POST', '/v1/admin/workspaces/:id/plan', ({ p, body }) => {
    if (!CLOUD_PLANS[body.plan]) throw new HttpError(422, 'Unknown plan');
    db.prepare('UPDATE workspaces SET plan = ?, plan_status = ?, plan_period_end = ? WHERE id = ?').run(body.plan, body.status || 'active', body.months ? clock() + body.months * 30 * 864e5 : null, p.id);
    return { ok: true };
  });
  admin('GET', '/v1/admin/failed-jobs', () => db.prepare(`SELECT j.id, j.kind, j.execution_id executionId, j.attempts, j.last_error lastError, j.due_at dueAt FROM cloud_jobs j WHERE j.last_error IS NOT NULL ORDER BY j.created_at DESC LIMIT 100`).all());
  admin('GET', '/v1/admin/executions', ({ query }) => db.prepare(`SELECT id, workspace_id workspaceId, automation_id automationId, status, error, started_at startedAt FROM executions WHERE (? = '' OR status = ?) ORDER BY started_at DESC LIMIT 200`).all(query.get('status') || '', query.get('status') || ''));
  admin('GET', '/v1/admin/abuse', () => ({
    noisyWebhooks: db.prepare(`SELECT w.id, w.workspace_id workspaceId, w.name, COUNT(r.id) lastHour, SUM(r.status = 401) rejected FROM webhooks w JOIN webhook_requests r ON r.webhook_id = w.id WHERE r.received_at > ? GROUP BY w.id HAVING lastHour > 50 OR rejected > 10 ORDER BY lastHour DESC`).all(clock() - 3600e3),
    heavyWorkspaces: db.prepare(`SELECT workspace_id workspaceId, COUNT(*) n FROM executions WHERE started_at > ? GROUP BY workspace_id HAVING n > 500 ORDER BY n DESC LIMIT 20`).all(clock() - 3600e3),
  }));

  // ------------------------------------------------------------ dispatcher
  /** Returns true when the request was a cloud route. */
  async function handle(req, res, url) {
    if (!url.pathname.startsWith('/v1/') && !url.pathname.startsWith('/hooks/') && !url.pathname.startsWith('/oauth/') && url.pathname !== '/reset') return false;
    const r = routes.find((x) => x.method === req.method && x.re.test(url.pathname));
    const send = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json', 'access-control-allow-origin': env.CORS_ORIGIN || '*', 'access-control-allow-headers': 'authorization, content-type, x-admin-key, x-autometa-secret', 'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS', 'cache-control': 'no-store' });
      res.end(JSON.stringify(body));
    };
    if (req.method === 'OPTIONS') { send(204, null); return true; }
    if (!r) { send(404, { error: 'Not found' }); return true; }
    const ip = String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
    try {
      const chunks = [];
      let size = 0;
      for await (const c of req) { size += c.length; if (size > 1.5e6) throw new HttpError(413, 'Body too large'); chunks.push(c); }
      const raw = Buffer.concat(chunks);
      let body = {};
      if (!r.raw && raw.length) { try { body = JSON.parse(raw.toString('utf8')); } catch { throw new HttpError(400, 'Invalid JSON'); } }
      const m = url.pathname.match(r.re);
      const p = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])]));
      const ctx = r.public ? null : { ...authCtx(req), ip };
      const out = await r.handler({ req, body, raw, p, query: url.searchParams, ctx, ip });
      await engine.flushPush();
      if (out?.__html) { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'", 'referrer-policy': 'no-referrer' }); res.end(out.__html); return true; }
      send(r.status || 200, out ?? { ok: true });
    } catch (e) {
      if (e instanceof LimitError) return send(402, { error: e.message, limit: e.limit, requiredPlan: e.requiredPlan }), true;
      const status = e.status || 500;
      if (status >= 500) console.error('[cloud]', e);
      send(status, { error: status >= 500 ? 'Something went wrong on our side. It has been logged.' : e.message, ...(e.validation ? { validation: e.validation } : {}), ...(e.fix ? { fix: e.fix } : {}) });
    }
    return true;
  }

  // Booleans/status words only: never secret values. "scheduler" reflects the
  // real tick loop: not_started (no tick yet) / running / stale (> 60 s).
  const health = () => {
    const last = engine.lastTickAt;
    const scheduler = last == null ? 'not_started' : clock() - last > 60_000 ? 'stale' : 'running';
    return { scheduler, gmail: googleConfigured(env), push: engine.push.configured, publicUrl: !!env.PUBLIC_URL };
  };
  return { engine, handle, health };
}
