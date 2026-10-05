import { autometa, webhookIntegration } from './core.js';
import { http } from './http.js';
import { telegram } from './telegram.js';
import { whatsapp } from './whatsapp.js';

// Register integrations here. Gmail and Google Calendar are added when their
// OAuth flow is built; until then they are not listed, never shown as fakes.
export const INTEGRATIONS = Object.fromEntries([autometa, webhookIntegration, telegram, whatsapp, http].map((i) => [i.id, i]));

export function catalog() {
  return Object.values(INTEGRATIONS).map((i) => ({
    id: i.id, name: i.name, category: i.category, description: i.description, docs: i.docs || null, builtin: !!i.builtin,
    auth: { type: i.auth.type, fields: (i.auth.fields || []).map(({ key, label, type, required, placeholder, help }) => ({ key, label, type, required, placeholder, help })) },
    triggers: Object.entries(i.triggers).map(([key, t]) => ({ key, label: t.label, description: t.description, config: t.config, variables: t.variables })),
    actions: Object.entries(i.actions).map(([key, a]) => ({ key, label: a.label, description: a.description, config: a.config, idempotent: !!a.idempotent })),
  }));
}
