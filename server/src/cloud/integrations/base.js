// Integration contract. Each integration is a plain object:
// {
//   id, name, category, description, docs,
//   auth: { type: 'none' | 'token' | 'oauth', fields: [Field], help },
//   connect?(fields, ctx) -> { identity, secret, meta, scopes }   // verify before storing
//   test?(conn, ctx)      -> { identity }                          // throws ActionError
//   triggers: { key: { label, description, config: [Field], variables: [..], validate?(cfg) } }
//   actions:  { key: { label, description, config: [Field], idempotent, validate?(cfg),
//                      simulate(cfg) -> output, execute(cfg, conn, ctx) -> output } }
// }
// Field = { key, label, type: text|textarea|number|select|chat|json|password, required, options, help, placeholder }
// The engine only talks to this contract; providers never leak into it.

export class ActionError extends Error {
  /**
   * kind: auth (reconnect needed) | config (user must edit) | rate_limit | transient
   *       | ambiguous (may have happened; never auto-retried unless idempotent) | permanent
   */
  constructor(message, { kind = 'permanent', fix = null, retryAfterMs = null, detail = null } = {}) {
    super(message);
    Object.assign(this, { kind, fix, retryAfterMs, detail });
  }
  get retryable() { return this.kind === 'rate_limit' || this.kind === 'transient'; }
}

export function requireFields(cfg, fields) {
  const errors = [];
  for (const f of fields) {
    const v = cfg?.[f.key];
    if (f.required && (v == null || String(v).trim() === '')) errors.push(`${f.label} is required`);
    if (v != null && f.type === 'number' && v !== '' && !Number.isFinite(Number(v))) errors.push(`${f.label} must be a number`);
    if (f.type === 'select' && v != null && v !== '' && f.options && !f.options.some((o) => o.value === v)) errors.push(`${f.label}: choose one of the options`);
  }
  return errors;
}

/** fetch with timeout that classifies failures for the retry logic. */
export async function callApi(fetchImpl, url, init = {}, { timeoutMs = 15000, provider = 'Provider' } = {}) {
  let res;
  try {
    res = await fetchImpl(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  } catch (e) {
    // Request may or may not have reached the provider.
    throw new ActionError(`${provider} didn't respond (${e.name === 'TimeoutError' ? 'timeout' : 'network error'}).`, { kind: init.method && init.method !== 'GET' ? 'ambiguous' : 'transient' });
  }
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  return { res, body };
}
