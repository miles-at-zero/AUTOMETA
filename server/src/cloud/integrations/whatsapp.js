import { ActionError, callApi } from './base.js';

// WhatsApp Business Platform (Cloud API) only. A personal WhatsApp account
// cannot be automated from the cloud. Personal reminders use the app's
// on-device "prepare message" flow instead (the user taps Send).
// Business-initiated messages outside the 24h customer window must use an
// approved template; that's why both actions exist.
const GRAPH = 'https://graph.facebook.com';

function classify(res, body) {
  const e = body?.error || {};
  const msg = e.error_user_msg || e.message || `HTTP ${res.status}`;
  if (res.status === 401 || e.code === 190) return new ActionError('WhatsApp access token expired or was revoked.', { kind: 'auth', fix: 'Reconnect WhatsApp with a permanent System User token.' });
  if (e.code === 131047 || /re-engagement/i.test(msg)) return new ActionError('More than 24 hours since this person last messaged you, so WhatsApp only allows an approved template.', { kind: 'config', fix: 'Switch this step to "Send template message".' });
  if (e.code === 132001) return new ActionError('That template name/language doesn\'t exist or isn\'t approved.', { kind: 'config', fix: 'Check the template in WhatsApp Manager.' });
  if (e.code === 130429 || e.code === 131056 || res.status === 429) return new ActionError('WhatsApp rate limit reached.', { kind: 'rate_limit', retryAfterMs: 60000 });
  if (res.status >= 500) return new ActionError(`WhatsApp server error (${res.status}).`, { kind: 'transient' });
  return new ActionError(`WhatsApp: ${msg}`, { kind: 'permanent' });
}

const digits = (s) => String(s || '').replace(/\D/g, '');

async function send(ctx, conn, payload) {
  const { res, body } = await callApi(ctx.fetch, `${GRAPH}/${ctx.env.GRAPH_VERSION || 'v26.0'}/${conn.meta.phoneNumberId}/messages`, {
    method: 'POST', headers: { authorization: `Bearer ${conn.secret}`, 'content-type': 'application/json' },
    body: JSON.stringify({ messaging_product: 'whatsapp', recipient_type: 'individual', ...payload }),
  }, { provider: 'WhatsApp' });
  if (!res.ok) throw classify(res, body);
  const m = body?.messages?.[0] || {};
  return { messageId: m.id, status: m.message_status || 'accepted' };
}

export const whatsapp = {
  id: 'whatsapp',
  name: 'WhatsApp Business',
  category: 'messaging',
  description: 'Send WhatsApp messages from your business number via the official Cloud API.',
  docs: 'Requires a WhatsApp Business Platform number (developers.facebook.com → WhatsApp). Personal WhatsApp accounts can\'t be automated from the cloud. For personal reminders, use an "On this phone" automation that prepares the message for you to send.',
  auth: {
    type: 'token',
    fields: [
      { key: 'phoneNumberId', label: 'Phone number ID', type: 'text', required: true },
      { key: 'token', label: 'Permanent access token', type: 'password', required: true, help: 'System User token with whatsapp_business_messaging.' },
    ],
  },
  async connect(fields, ctx) {
    const id = digits(fields.phoneNumberId);
    if (id.length < 5) throw new ActionError('Phone number ID is the long number on Meta\'s API Setup page.', { kind: 'config' });
    const conn = { secret: String(fields.token || '').trim(), meta: { phoneNumberId: id } };
    const r = await this.test(conn, ctx);
    return { identity: r.identity, secret: conn.secret, meta: conn.meta, scopes: ['whatsapp_business_messaging'] };
  },
  async test(conn, ctx) {
    const { res, body } = await callApi(ctx.fetch, `${GRAPH}/${ctx.env.GRAPH_VERSION || 'v26.0'}/${conn.meta.phoneNumberId}?fields=display_phone_number,verified_name`, { headers: { authorization: `Bearer ${conn.secret}` } }, { provider: 'WhatsApp' });
    if (!res.ok) throw classify(res, body);
    return { identity: `${body.verified_name || ''} ${body.display_phone_number || ''}`.trim() };
  },
  triggers: {},
  actions: {
    send_template: {
      label: 'Send template message',
      description: 'Approved template. Works any time, including to people who haven\'t messaged you recently.',
      config: [
        { key: 'to', label: 'Recipient phone (with country code)', type: 'text', required: true, placeholder: '2348012345678', variables: true },
        { key: 'template', label: 'Template name', type: 'text', required: true, placeholder: 'appointment_reminder' },
        { key: 'language', label: 'Language code', type: 'text', placeholder: 'en_US' },
        { key: 'params', label: 'Body parameters (one per line)', type: 'textarea', variables: true, help: 'Fill {{1}}, {{2}}… in the template, in order.' },
      ],
      idempotent: false,
      simulate: (cfg) => ({ to: digits(cfg.to), template: cfg.template }),
      execute(cfg, conn, ctx) {
        const params = String(cfg.params || '').split('\n').map((s) => s.trim()).filter(Boolean);
        return send(ctx, conn, {
          to: digits(cfg.to), type: 'template',
          template: { name: cfg.template, language: { code: cfg.language || 'en_US' }, ...(params.length ? { components: [{ type: 'body', parameters: params.map((text) => ({ type: 'text', text })) }] } : {}) },
        });
      },
    },
    send_text: {
      label: 'Send text message',
      description: 'Free-form text. WhatsApp only delivers it within 24 h of the recipient\'s last message to you.',
      config: [
        { key: 'to', label: 'Recipient phone (with country code)', type: 'text', required: true, variables: true },
        { key: 'text', label: 'Message', type: 'textarea', required: true, variables: true },
      ],
      idempotent: false,
      simulate: (cfg) => ({ to: digits(cfg.to), text: cfg.text }),
      execute: (cfg, conn, ctx) => send(ctx, conn, { to: digits(cfg.to), type: 'text', text: { body: cfg.text, preview_url: false } }),
    },
  },
};
