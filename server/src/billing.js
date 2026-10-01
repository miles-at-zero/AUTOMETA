// Subscriptions: Google Play (verified server-side) or manual activation
// (bank transfer / setup-service customers, done by the operator).
import { createSign } from 'node:crypto';
import { planForProduct } from './pricing.js';

/** Google Play subscriptionState → our status. */
export function mapPlayState(state) {
  switch (state) {
    case 'SUBSCRIPTION_STATE_ACTIVE': return 'active';
    case 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD': return 'grace';
    case 'SUBSCRIPTION_STATE_ON_HOLD': return 'on_hold';
    case 'SUBSCRIPTION_STATE_PAUSED': return 'on_hold';
    case 'SUBSCRIPTION_STATE_CANCELED': return 'canceled';
    case 'SUBSCRIPTION_STATE_EXPIRED': return 'expired';
    case 'SUBSCRIPTION_STATE_PENDING': return 'on_hold';
    default: return 'expired';
  }
}

export class GooglePlayVerifier {
  constructor({ env = process.env, fetchImpl = globalThis.fetch }) {
    this.packageName = env.GOOGLE_PLAY_PACKAGE || 'dev.autometa.app';
    this.sa = env.GOOGLE_SERVICE_ACCOUNT_JSON ? JSON.parse(env.GOOGLE_SERVICE_ACCOUNT_JSON) : null;
    this.fetchImpl = fetchImpl;
    this.env = env;
  }
  get configured() { return !!this.sa; }

  async accessToken() {
    const now = Math.floor(Date.now() / 1000);
    const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
    const unsigned = `${enc({ alg: 'RS256', typ: 'JWT' })}.${enc({ iss: this.sa.client_email, scope: 'https://www.googleapis.com/auth/androidpublisher', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 })}`;
    const sig = createSign('RSA-SHA256').update(unsigned).sign(this.sa.private_key).toString('base64url');
    const res = await this.fetchImpl('https://oauth2.googleapis.com/token', {
      method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${sig}` }),
    });
    const b = await res.json();
    if (!res.ok) throw new Error(b.error_description || 'Google auth failed');
    return b.access_token;
  }

  /** @returns {{plan, status, periodEnd, graceUntil, productId}} */
  async verify(purchaseToken) {
    if (!this.configured) throw Object.assign(new Error('Google Play verification is not configured on this server'), { status: 501 });
    const token = await this.accessToken();
    const res = await this.fetchImpl(`https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${this.packageName}/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    const b = await res.json();
    if (!res.ok) throw Object.assign(new Error(b?.error?.message || 'Purchase not found'), { status: 400 });
    const line = (b.lineItems || [])[0] || {};
    const productId = line.productId;
    const plan = planForProduct(productId, this.env);
    if (!plan) throw Object.assign(new Error(`Unknown product ${productId}`), { status: 400 });
    const status = mapPlayState(b.subscriptionState);
    const periodEnd = line.expiryTime ? Date.parse(line.expiryTime) : null;
    return { plan, status, periodEnd, graceUntil: status === 'grace' ? periodEnd : null, productId, acknowledged: b.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED' };
  }
}

export function saveSubscription(db, accountId, s, clock = Date.now) {
  db.prepare(`INSERT INTO subscriptions (account_id, plan, status, period_end, grace_until, source, product_id, purchase_token, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?)
    ON CONFLICT(account_id) DO UPDATE SET plan=excluded.plan, status=excluded.status, period_end=excluded.period_end,
      grace_until=excluded.grace_until, source=excluded.source, product_id=excluded.product_id,
      purchase_token=COALESCE(excluded.purchase_token, subscriptions.purchase_token), updated_at=excluded.updated_at`)
    .run(accountId, s.plan, s.status, s.periodEnd ?? null, s.graceUntil ?? null, s.source, s.productId ?? null, s.purchaseToken ?? null, clock());
}
