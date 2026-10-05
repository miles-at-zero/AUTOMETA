// Cloud plans: what each plan allows. Prices live in pricing.js (cloud key).
// null = unlimited. Enforcement is server-side only.
export const CLOUD_PLANS = {
  free: { id: 'free', name: 'Free', rank: 0, limits: { automations: 5, executionsPerMonth: 500, webhooks: 1, connections: 3, stepsPerAutomation: 4, minIntervalMinutes: 15, historyDays: 7 }, features: ['basicConditions'] },
  plus: { id: 'plus', name: 'Plus', rank: 1, limits: { automations: 20, executionsPerMonth: 3000, webhooks: 3, connections: 10, stepsPerAutomation: 10, minIntervalMinutes: 5, historyDays: 30 }, features: ['basicConditions', 'advancedConditions', 'retries'] },
  pro: { id: 'pro', name: 'Pro', rank: 2, limits: { automations: 100, executionsPerMonth: 25000, webhooks: 25, connections: null, stepsPerAutomation: 30, minIntervalMinutes: 1, historyDays: 90 }, features: ['basicConditions', 'advancedConditions', 'retries', 'advancedLogs'] },
  business: { id: 'business', name: 'Business', rank: 3, limits: { automations: 500, executionsPerMonth: 150000, webhooks: 100, connections: null, stepsPerAutomation: 50, minIntervalMinutes: 1, historyDays: 365 }, features: ['basicConditions', 'advancedConditions', 'retries', 'advancedLogs', 'team', 'audit'] },
};

export const cloudPlan = (id) => CLOUD_PLANS[id] || CLOUD_PLANS.free;

/** Plan in force now: lapsed paid plans fall back to Free after 7 days' grace. */
export function effectiveCloudPlan(ws, now = Date.now()) {
  if (!ws || ws.plan === 'free') return 'free';
  if (ws.plan_status === 'on_hold' || ws.plan_status === 'expired') return 'free';
  if (ws.plan_period_end && now > ws.plan_period_end + 7 * 864e5) return 'free';
  return CLOUD_PLANS[ws.plan] ? ws.plan : 'free';
}

export class LimitError extends Error {
  constructor(message, { limit, feature, requiredPlan } = {}) {
    super(message);
    Object.assign(this, { status: 402, limit, feature, requiredPlan });
  }
}

export function upgradeFor(predicate) {
  return Object.values(CLOUD_PLANS).sort((a, b) => a.rank - b.rank).find(predicate)?.id || 'business';
}
