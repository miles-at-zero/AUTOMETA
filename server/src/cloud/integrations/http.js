import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { ActionError, callApi } from './base.js';

// Outgoing HTTP request. Blocks private/loopback/link-local targets so a
// workspace can't use the server to probe internal networks (SSRF).
function privateIp(ip) {
  if (isIP(ip) === 6) return ip === '::1' || /^f[cd]/i.test(ip) || /^fe80/i.test(ip) || ip.startsWith('::ffff:') && privateIp(ip.slice(7));
  const [a, b] = ip.split('.').map(Number);
  return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
}

export async function assertPublicUrl(raw, env = process.env) {
  let u;
  try { u = new URL(raw); } catch { throw new ActionError('URL isn\'t valid.', { kind: 'config' }); }
  if (u.protocol !== 'https:' && !(env.ALLOW_HTTP_ACTIONS === 'true' && u.protocol === 'http:')) throw new ActionError('Only https:// URLs are allowed.', { kind: 'config' });
  if (env.ALLOW_PRIVATE_HTTP === 'true') return u;
  const host = u.hostname.replace(/^\[|\]$/g, '');
  const ips = isIP(host) ? [host] : (await lookup(host, { all: true }).catch(() => { throw new ActionError(`Can't resolve ${host}.`, { kind: 'transient' }); })).map((r) => r.address);
  if (ips.some(privateIp) || host === 'localhost') throw new ActionError('Requests to private or local addresses are blocked.', { kind: 'config' });
  return u;
}

export const http = {
  id: 'http',
  name: 'HTTP request',
  category: 'web',
  description: 'Call any HTTPS API or send data to another service.',
  auth: { type: 'none' },
  builtin: true,
  triggers: {},
  actions: {
    request: {
      label: 'Send an HTTP request',
      description: 'POST/GET/PUT/DELETE to a URL. The response is available to later steps as {{steps.<id>.body}}.',
      config: [
        { key: 'method', label: 'Method', type: 'select', required: true, options: ['POST', 'GET', 'PUT', 'PATCH', 'DELETE'].map((v) => ({ value: v, label: v })) },
        { key: 'url', label: 'URL', type: 'text', required: true, placeholder: 'https://example.com/hook', variables: true },
        { key: 'headers', label: 'Headers (JSON)', type: 'json', placeholder: '{"Authorization":"Bearer …"}' },
        { key: 'body', label: 'Body', type: 'textarea', variables: true },
      ],
      // GET/PUT/DELETE are idempotent by HTTP semantics; POST/PATCH are not.
      idempotentFor: (cfg) => ['GET', 'PUT', 'DELETE'].includes(cfg.method),
      idempotent: false,
      validate(cfg) {
        const e = [];
        if (cfg.headers) { try { const h = typeof cfg.headers === 'string' ? JSON.parse(cfg.headers) : cfg.headers; if (typeof h !== 'object' || Array.isArray(h)) e.push('Headers must be a JSON object'); } catch { e.push('Headers must be valid JSON'); } }
        if (cfg.url && !/^https?:\/\//.test(cfg.url) && !cfg.url.startsWith('{{')) e.push('URL must start with https://');
        return e;
      },
      simulate: (cfg) => ({ method: cfg.method, url: cfg.url }),
      async execute(cfg, _conn, ctx) {
        const u = await assertPublicUrl(cfg.url, ctx.env);
        const headers = { 'user-agent': 'Autometa/1.0', 'x-autometa-execution': ctx.execution.id, 'idempotency-key': ctx.idempotencyKey, ...(cfg.headers ? (typeof cfg.headers === 'string' ? JSON.parse(cfg.headers) : cfg.headers) : {}) };
        if (cfg.body && !Object.keys(headers).some((k) => k.toLowerCase() === 'content-type')) headers['content-type'] = /^\s*[{[]/.test(cfg.body) ? 'application/json' : 'text/plain';
        const { res, body } = await callApi(ctx.fetch, u, { method: cfg.method, headers, body: ['GET', 'DELETE'].includes(cfg.method) ? undefined : cfg.body, redirect: 'manual' }, { provider: u.host });
        if (res.status === 429) throw new ActionError(`${u.host} rate-limited the request.`, { kind: 'rate_limit', retryAfterMs: (Number(res.headers.get('retry-after')) || 30) * 1000 });
        if (res.status >= 500) throw new ActionError(`${u.host} returned ${res.status}.`, { kind: cfg.method === 'POST' || cfg.method === 'PATCH' ? 'ambiguous' : 'transient' });
        if (res.status === 401 || res.status === 403) throw new ActionError(`${u.host} refused the request (${res.status}).`, { kind: 'config', fix: 'Check the Authorization header.' });
        if (res.status >= 400) throw new ActionError(`${u.host} returned ${res.status}.`, { kind: 'permanent', detail: typeof body === 'string' ? body.slice(0, 300) : body });
        return { status: res.status, body: typeof body === 'string' ? body.slice(0, 10000) : body };
      },
    },
  },
};
