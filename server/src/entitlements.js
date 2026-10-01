import { PLANS, FEATURES } from './plans.js';

export const GRACE_DAYS = 7;

/**
 * Turns a stored subscription into the plan the account may use right now.
 *  active                    → paid plan (until period_end, if set)
 *  canceled                  → paid plan until period_end, then free
 *  grace (payment failing)   → paid plan until grace_until, then free
 *  on_hold / expired         → free
 */
export function effectiveSubscription(sub, now = Date.now()) {
  const base = { plan: 'free', status: 'active', source: 'none', periodEnd: null, graceUntil: null, paidPlan: null, notice: null };
  if (!sub) return base;
  const paid = PLANS[sub.plan] ? sub.plan : 'free';
  const out = { ...base, source: sub.source, periodEnd: sub.period_end ?? null, graceUntil: sub.grace_until ?? null, paidPlan: paid, status: sub.status };
  if (paid === 'free') return { ...out, plan: 'free' };

  const periodOk = sub.period_end == null || now < sub.period_end;
  switch (sub.status) {
    case 'active':
      if (periodOk) return { ...out, plan: paid };
      // Lapsed without a renewal signal: give a grace window before downgrading.
      if (now < sub.period_end + GRACE_DAYS * 864e5) {
        return { ...out, plan: paid, status: 'grace', graceUntil: sub.period_end + GRACE_DAYS * 864e5, notice: 'Renewal pending. Update payment to keep your plan.' };
      }
      return { ...out, plan: 'free', status: 'expired', notice: `${PLANS[paid].name} expired. You're on Free.` };
    case 'canceled':
      return periodOk
        ? { ...out, plan: paid, notice: `Cancelled. ${PLANS[paid].name} stays active until the end of the period.` }
        : { ...out, plan: 'free', status: 'expired', notice: `${PLANS[paid].name} ended. You're on Free.` };
    case 'grace':
      return sub.grace_until && now < sub.grace_until
        ? { ...out, plan: paid, notice: 'Payment problem. Fix it before your grace period ends to keep your plan.' }
        : { ...out, plan: 'free', status: 'expired', notice: 'Grace period ended. You\'re on Free.' };
    case 'on_hold':
      return { ...out, plan: 'free', notice: 'Subscription on hold (payment failed). Fix payment to restore your plan.' };
    default:
      return { ...out, plan: 'free' };
  }
}

export function planOf(id) {
  return PLANS[id] || PLANS.free;
}

export function can(planId, feature) {
  return planOf(planId).features.includes(feature);
}

/** null limit = unlimited. Returns {ok, limit, used}. */
export function within(planId, limitName, used) {
  const limit = planOf(planId).limits[limitName];
  return { ok: limit == null || used < limit, limit, used };
}

export class PlanError extends Error {
  constructor(message, { feature, limit, requiredPlan } = {}) {
    super(message);
    this.status = 402;
    this.code = feature ? 'feature_locked' : 'limit_reached';
    this.feature = feature;
    this.limit = limit;
    this.requiredPlan = requiredPlan;
  }
}

export function cheapestPlanWith(feature) {
  return Object.values(PLANS).sort((a, b) => a.rank - b.rank).find((p) => p.features.includes(feature))?.id || 'business';
}

export function requireFeature(planId, feature) {
  if (!can(planId, feature)) {
    const req = cheapestPlanWith(feature);
    throw new PlanError(`${FEATURES[feature] || feature} needs ${PLANS[req].name}`, { feature, requiredPlan: req });
  }
}

export function requireWithin(planId, limitName, used, label) {
  const r = within(planId, limitName, used);
  if (!r.ok) {
    const next = Object.values(PLANS).sort((a, b) => a.rank - b.rank)
      .find((p) => p.rank > planOf(planId).rank && (p.limits[limitName] == null || p.limits[limitName] > used));
    throw new PlanError(`${planOf(planId).name} allows ${r.limit} ${label}. Upgrade for more.`, { limit: limitName, requiredPlan: next?.id });
  }
}

/** Public description for the app (feature matrix + limits). */
export function describePlans() {
  return Object.values(PLANS).map((p) => ({ id: p.id, name: p.name, rank: p.rank, features: p.features, limits: p.limits }));
}
