import { autometa, webhookIntegration } from './core.js';
import { http } from './http.js';
import { telegram } from './telegram.js';
import { whatsapp } from './whatsapp.js';
import { gmailIntegration } from './gmail.js';

// Register integrations here. Gmail is listed with available=false when the
// server has no Google OAuth credentials. Google Calendar: DEFERRED FROM V1.
export const INTEGRATIONS = Object.fromEntries([autometa, webhookIntegration, telegram, whatsapp, gmailIntegration, http].map((i) => [i.id, i]));

export function catalog(env = process.env) {
  return Object.values(INTEGRATIONS).map((i) => ({
    id: i.id, name: i.name, category: i.category, description: i.description, docs: i.docs || null, builtin: !!i.builtin,
    available: i.available ? !!i.available(env) : true, unavailableReason: i.available && !i.available(env) ? i.unavailableReason : null,
    auth: { type: i.auth.type, fields: (i.auth.fields || []).map(({ key, label, type, required, placeholder, help }) => ({ key, label, type, required, placeholder, help })) },
    triggers: Object.entries(i.triggers).map(([key, t]) => ({ key, label: t.label, description: t.description, config: t.config, variables: t.variables })),
    actions: Object.entries(i.actions).map(([key, a]) => ({ key, label: a.label, description: a.description, config: a.config, idempotent: !!a.idempotent })),
  }));
}
