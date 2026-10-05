import { createSign } from 'node:crypto';

// Device push via Firebase Cloud Messaging HTTP v1 (official).
// EXTERNAL CONFIG REQUIRED: FCM_SERVICE_ACCOUNT_JSON (service-account JSON
// with the firebase messaging role). Without it, push is reported as
// "not configured" and in-app notifications remain the only channel.

// Which notification kinds may interrupt the user. Ordinary successes never push.
export const PUSH_KINDS = {
  automation_failed: 'failures', automation_paused: 'failures', connection_reauth: 'failures',
  usage_limit: 'account', usage_warning: 'account', automation_message: 'messages',
};
export const DEFAULT_PREFS = { failures: true, account: true, messages: true };

export function pushConfig(env) {
  if (!env.FCM_SERVICE_ACCOUNT_JSON) return null;
  try {
    const sa = JSON.parse(env.FCM_SERVICE_ACCOUNT_JSON);
    if (!sa.client_email || !sa.private_key || !sa.project_id) return null;
    return sa;
  } catch { return null; }
}

/** Builds the FCM v1 message. Data payload drives the in-app deep link. */
export function buildPushMessage(token, n) {
  const action = n.action || {};
  return {
    message: {
      token,
      notification: { title: n.title, body: String(n.body).slice(0, 240) },
      data: {
        notificationId: n.id, kind: n.kind, severity: n.severity,
        actionType: action.type || '', executionId: action.executionId || '', connectionId: action.connectionId || '',
        automationId: n.target || '',
      },
      android: { priority: n.severity === 'error' ? 'high' : 'normal', notification: { channel_id: 'cloud_alerts', tag: n.target || n.kind } },
    },
  };
}

export class PushService {
  constructor({ db, env, fetchImpl = globalThis.fetch, clock = () => Date.now() }) {
    Object.assign(this, { db, env, fetch: fetchImpl, clock, token: null });
  }
  get configured() { return !!pushConfig(this.env); }

  async accessToken() {
    if (this.token && this.token.exp - 60e3 > this.clock()) return this.token.value;
    const sa = pushConfig(this.env);
    const now = Math.floor(this.clock() / 1000);
    const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
    const unsigned = `${b({ alg: 'RS256', typ: 'JWT' })}.${b({ iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 })}`;
    const sig = createSign('RSA-SHA256').update(unsigned).sign(sa.private_key).toString('base64url');
    const res = await this.fetch('https://oauth2.googleapis.com/token', {
      method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${sig}` }).toString(),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`FCM auth failed: ${body.error || res.status}`);
    this.token = { value: body.access_token, exp: this.clock() + (body.expires_in || 3600) * 1000 };
    return this.token.value;
  }

  log(nid, did, status, detail) {
    this.db.prepare('INSERT INTO push_log (notification_id, device_id, status, detail, ts) VALUES (?,?,?,?,?)').run(nid, did, status, detail || null, this.clock());
  }

  /** Sends a stored notification to the workspace's devices that opted in. Never throws. */
  async dispatch(wsId, n) {
    const category = PUSH_KINDS[n.kind];
    if (!category) return { sent: 0, reason: 'not_push_worthy' };
    const devices = this.db.prepare('SELECT * FROM devices WHERE workspace_id = ?').all(wsId)
      .filter((d) => ({ ...DEFAULT_PREFS, ...JSON.parse(d.prefs || '{}') })[category] !== false);
    if (!devices.length) return { sent: 0, reason: 'no_devices' };
    const sa = pushConfig(this.env);
    if (!sa) { for (const d of devices) this.log(n.id, d.id, 'not_configured'); return { sent: 0, reason: 'not_configured' }; }
    let sent = 0;
    try {
      const token = await this.accessToken();
      for (const d of devices) {
        const res = await this.fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
          method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(buildPushMessage(d.token, n)),
        });
        if (res.ok) { sent++; this.log(n.id, d.id, 'sent'); continue; }
        const body = await res.json().catch(() => ({}));
        const code = body?.error?.details?.find?.((x) => x.errorCode)?.errorCode || body?.error?.status;
        if (res.status === 404 || code === 'UNREGISTERED') this.db.prepare('DELETE FROM devices WHERE id = ?').run(d.id);
        this.log(n.id, d.id, 'failed', `${res.status} ${code || ''}`);
      }
    } catch (e) { this.log(n.id, null, 'failed', e.message); }
    return { sent };
  }
}
