// Prices are display + store data only. Entitlements never read this file.
// Override at deploy time with PRICING_JSON to run price tests.
const DEFAULT = {
  currency: 'NGN',
  plans: {
    free: { monthly: 0 },
    pro: { monthly: 5000, googlePlayProductId: 'autometa_pro_monthly' },
    business: { monthly: 15000, googlePlayProductId: 'autometa_business_monthly' },
  },
  // Cloud automation plans (Autometa platform). Display/store data only.
  cloud: {
    free: { monthly: 0 },
    plus: { monthly: 2500, googlePlayProductId: 'autometa_plus_monthly' },
    pro: { monthly: 6000, googlePlayProductId: 'autometa_cloud_pro_monthly' },
    business: { monthly: 15000, googlePlayProductId: 'autometa_cloud_business_monthly' },
  },
  setupService: {
    from: 25000, to: 100000,
    description: 'We connect your WhatsApp Business number, build your menu/FAQ/order flows and train your staff.',
    contact: '',
  },
};

export function pricing(env = process.env) {
  if (!env.PRICING_JSON) return DEFAULT;
  try {
    const custom = JSON.parse(env.PRICING_JSON);
    return { ...DEFAULT, ...custom, plans: { ...DEFAULT.plans, ...(custom.plans || {}) } };
  } catch {
    return DEFAULT;
  }
}

export function planForProduct(productId, env = process.env) {
  const p = pricing(env).plans;
  return Object.keys(p).find((k) => p[k].googlePlayProductId === productId) || null;
}
