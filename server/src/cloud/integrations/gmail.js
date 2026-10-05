import { ActionError, callApi } from './base.js';

// Gmail via Google's official OAuth 2.0 + Gmail REST API.
// EXTERNAL CONFIG REQUIRED: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, PUBLIC_URL
// (redirect URI = PUBLIC_URL + /oauth/google/callback, registered in Google
// Cloud Console). gmail.send / gmail.readonly are restricted scopes: public
// launch needs Google's OAuth verification (and a security assessment).
const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const API = 'https://gmail.googleapis.com/gmail/v1/users/me';
export const GMAIL_SCOPES = ['https://www.googleapis.com/auth/gmail.readonly', 'https://www.googleapis.com/auth/gmail.send'];

export const googleConfigured = (env) => !!(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET && env.PUBLIC_URL);
export const googleRedirectUri = (env) => `${String(env.PUBLIC_URL).replace(/\/+$/, '')}/oauth/google/callback`;

export function googleAuthUrl(env, { state, challenge }) {
  const q = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID, redirect_uri: googleRedirectUri(env), response_type: 'code',
    scope: GMAIL_SCOPES.join(' '), access_type: 'offline', prompt: 'consent', include_granted_scopes: 'true',
    state, code_challenge: challenge, code_challenge_method: 'S256',
  });
  return `${AUTH_URL}?${q}`;
}

async function tokenCall(fetchImpl, env, params) {
  const { res, body } = await callApi(fetchImpl, TOKEN_URL, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET, ...params }).toString(),
  }, { provider: 'Google' });
  if (res.status === 400 && body?.error === 'invalid_grant') {
    throw new ActionError('Google access was revoked or expired.', { kind: 'auth', fix: 'Reconnect Gmail.' });
  }
  if (!res.ok) throw new ActionError(`Google sign-in failed (${body?.error || res.status}).`, { kind: res.status >= 500 ? 'transient' : 'config' });
  return body;
}

/** Exchanges the OAuth code; returns {identity, secret, scopes}. */
export async function googleExchange(fetchImpl, env, { code, verifier, now = Date.now() }) {
  const t = await tokenCall(fetchImpl, env, { grant_type: 'authorization_code', code, code_verifier: verifier, redirect_uri: googleRedirectUri(env) });
  if (!t.refresh_token) throw new ActionError('Google did not grant offline access.', { kind: 'config', fix: 'Remove Autometa from your Google account permissions and connect again.' });
  const granted = String(t.scope || '').split(' ');
  const missing = GMAIL_SCOPES.filter((s) => !granted.includes(s));
  if (missing.length) throw new ActionError('Some Gmail permissions were not granted.', { kind: 'config', fix: 'Connect again and allow reading and sending email.' });
  const secret = { refresh_token: t.refresh_token, access_token: t.access_token, expires_at: now + (t.expires_in || 3600) * 1000 };
  const { res, body } = await callApi(fetchImpl, `${API}/profile`, { headers: { authorization: `Bearer ${t.access_token}` } }, { provider: 'Gmail' });
  if (!res.ok) throw new ActionError('Could not read the Gmail profile.', { kind: 'config' });
  return { identity: body.emailAddress, secret: JSON.stringify(secret), scopes: granted, meta: {} };
}

/** Valid access token, refreshing when needed. Persists via ctx.saveSecret. */
async function accessToken(conn, ctx) {
  const nowMs = ctx.now ? ctx.now() : Date.now();
  let s;
  try { s = JSON.parse(conn.secret || '{}'); } catch { s = {}; }
  if (!s.refresh_token) throw new ActionError('Gmail isn\'t connected.', { kind: 'auth', fix: 'Reconnect Gmail.' });
  if (s.access_token && s.expires_at - 60e3 > nowMs) return s.access_token;
  const t = await tokenCall(ctx.fetch, ctx.env, { grant_type: 'refresh_token', refresh_token: s.refresh_token });
  s = { ...s, access_token: t.access_token, expires_at: nowMs + (t.expires_in || 3600) * 1000 };
  conn.secret = JSON.stringify(s);
  ctx.saveSecret?.(conn.secret);
  return s.access_token;
}

async function gmail(ctx, conn, path, init = {}) {
  const token = await accessToken(conn, ctx);
  const { res, body } = await callApi(ctx.fetch, `${API}${path}`, { ...init, headers: { authorization: `Bearer ${token}`, ...(init.headers || {}) } }, { provider: 'Gmail' });
  if (res.status === 401) throw new ActionError('Gmail rejected the saved access.', { kind: 'auth', fix: 'Reconnect Gmail.' });
  if (res.status === 403) throw new ActionError(body?.error?.message || 'Gmail refused the request.', { kind: /rate|quota/i.test(body?.error?.message || '') ? 'rate_limit' : 'auth', fix: 'Reconnect Gmail and allow all requested permissions.' });
  if (res.status === 429) throw new ActionError('Gmail rate limit reached.', { kind: 'rate_limit', retryAfterMs: 60e3 });
  if (res.status >= 500) throw new ActionError(`Gmail is having problems (${res.status}).`, { kind: init.method === 'POST' ? 'ambiguous' : 'transient' });
  if (!res.ok) throw new ActionError(body?.error?.message || `Gmail error ${res.status}`, { kind: 'permanent' });
  return body;
}

const header = (msg, name) => (msg.payload?.headers || []).find((h) => h.name.toLowerCase() === name.toLowerCase())?.value || '';
const b64url = (s) => Buffer.from(s, 'utf8').toString('base64url');
const encodeHeader = (v) => (/^[\x20-\x7e]*$/.test(v) ? v : `=?UTF-8?B?${Buffer.from(v, 'utf8').toString('base64')}?=`);

export function emailFromMessage(msg) {
  const from = header(msg, 'From');
  return {
    id: msg.id, threadId: msg.threadId, from, fromEmail: (from.match(/<([^>]+)>/)?.[1] || from).toLowerCase(),
    to: header(msg, 'To'), subject: header(msg, 'Subject'), snippet: msg.snippet || '', date: header(msg, 'Date'),
    labels: msg.labelIds || [], receivedAt: Number(msg.internalDate) || 0,
  };
}

/**
 * Polls for new messages matching the query since `cursor` (ms). Returns
 * {emails (oldest first, max 10), cursor}. First poll (cursor null) only
 * records "now": existing mail never triggers anything.
 */
export async function pollNewEmails(conn, query, cursor, ctx) {
  const now = ctx.now ? ctx.now() : Date.now();
  if (!cursor) return { emails: [], cursor: now };
  const q = `${query ? `${query} ` : ''}after:${Math.floor(cursor / 1000) - 1}`;
  const list = await gmail(ctx, conn, `/messages?maxResults=10&q=${encodeURIComponent(q)}`);
  const emails = [];
  for (const m of list.messages || []) {
    const full = await gmail(ctx, conn, `/messages/${m.id}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date`);
    const e = emailFromMessage(full);
    if (e.receivedAt > cursor) emails.push(e);
  }
  emails.sort((a, b) => a.receivedAt - b.receivedAt);
  return { emails, cursor: emails.length ? emails[emails.length - 1].receivedAt : cursor };
}

export const gmailIntegration = {
  id: 'gmail',
  name: 'Gmail',
  category: 'email',
  description: 'Start automations from new emails and send email from your Gmail account.',
  docs: 'docs/GMAIL.md',
  auth: { type: 'oauth', provider: 'google', scopes: GMAIL_SCOPES },
  available: (env) => googleConfigured(env),
  unavailableReason: 'Gmail needs Google OAuth to be configured on this server (GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, PUBLIC_URL).',
  async test(conn, ctx) {
    const p = await gmail(ctx, conn, '/profile');
    return { identity: p.emailAddress };
  },
  triggers: {
    new_email: {
      label: 'New email',
      description: 'When a new email arrives that matches your Gmail search (checked about every minute).',
      config: [{ key: 'query', label: 'Only emails matching (Gmail search)', type: 'text', placeholder: 'from:billing@example.com subject:invoice', help: 'Same syntax as the Gmail search box. Leave empty for every new email in the inbox.' }],
      variables: ['email.from', 'email.fromEmail', 'email.to', 'email.subject', 'email.snippet', 'email.date', 'email.id'],
      poll: true,
    },
  },
  actions: {
    send_email: {
      label: 'Send an email',
      description: 'Sends from your connected Gmail address.',
      config: [
        { key: 'to', label: 'To', type: 'text', required: true, placeholder: 'name@example.com', variables: true },
        { key: 'subject', label: 'Subject', type: 'text', required: true, variables: true },
        { key: 'body', label: 'Message', type: 'textarea', required: true, variables: true },
      ],
      idempotent: false,
      validate: (cfg) => {
        const e = [];
        if (cfg.to && !cfg.to.includes('{{') && !/^[^\s@,]+@[^\s@,]+\.[^\s@,]+(\s*,\s*[^\s@,]+@[^\s@,]+\.[^\s@,]+)*$/.test(cfg.to)) e.push('"To" must be one or more email addresses');
        return e;
      },
      simulate: (cfg) => ({ to: cfg.to, subject: cfg.subject }),
      async execute(cfg, conn, ctx) {
        if (/[\r\n]/.test(cfg.to + cfg.subject)) throw new ActionError('Recipient and subject can\'t contain line breaks.', { kind: 'config' });
        const raw = [`To: ${cfg.to}`, `Subject: ${encodeHeader(cfg.subject)}`, 'MIME-Version: 1.0', 'Content-Type: text/plain; charset="UTF-8"', 'Content-Transfer-Encoding: 8bit', '', cfg.body].join('\r\n');
        const r = await gmail(ctx, conn, '/messages/send', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ raw: b64url(raw) }) });
        return { messageId: r.id, threadId: r.threadId, to: cfg.to };
      },
    },
  },
};
