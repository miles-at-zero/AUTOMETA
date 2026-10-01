// Official WhatsApp Business Platform (Cloud API) only.
const GRAPH = 'https://graph.facebook.com';

export class CloudApiSender {
  constructor({ version = 'v26.0', tokenFor, fetchImpl = globalThis.fetch }) {
    Object.assign(this, { version, tokenFor, fetchImpl });
  }

  async post(business, payload) {
    const token = this.tokenFor(business);
    if (!business.phone_number_id || !token) throw new Error('WhatsApp number not connected');
    const res = await this.fetchImpl(`${GRAPH}/${this.version}/${business.phone_number_id}/messages`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ messaging_product: 'whatsapp', recipient_type: 'individual', ...payload }),
      signal: AbortSignal.timeout(10000),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error?.message || `HTTP ${res.status}`);
    return { wamid: body?.messages?.[0]?.id || null, status: body?.messages?.[0]?.message_status || 'accepted' };
  }

  /** Text, or interactive buttons (≤3 choices) / list (≤10) when choices are given. */
  async send(business, to, { text, choices }) {
    if (choices?.length && choices.length <= 3 && choices.every((c) => c.title.length <= 20)) {
      return this.post(business, { to, type: 'interactive', interactive: { type: 'button', body: { text }, action: { buttons: choices.map((c) => ({ type: 'reply', reply: { id: c.id, title: c.title } })) } } });
    }
    if (choices?.length && choices.length <= 10 && choices.every((c) => c.title.length <= 24)) {
      return this.post(business, { to, type: 'interactive', interactive: { type: 'list', body: { text }, action: { button: 'Choose', sections: [{ title: 'Options', rows: choices.map((c) => ({ id: c.id, title: c.title })) }] } } });
    }
    const body = choices?.length ? `${text}\n${choices.map((c, i) => `${i + 1}. ${c.title}`).join('\n')}` : text;
    return this.post(business, { to, type: 'text', text: { body, preview_url: false } });
  }

  async sendTemplate(business, to, name, language = 'en_US') {
    return this.post(business, { to, type: 'template', template: { name, language: { code: language } } });
  }

  /** Checks a phone-number id + token pair without sending anything. */
  async verify(phoneNumberId, token) {
    const res = await this.fetchImpl(`${GRAPH}/${this.version}/${phoneNumberId}?fields=display_phone_number,verified_name,quality_rating`, {
      headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10000),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error?.message || `HTTP ${res.status}`);
    return body;
  }
}

/** Flattens a Cloud API webhook payload into simple inbound/status records. */
export function parseWebhook(payload) {
  const inbound = [];
  const statuses = [];
  for (const entry of payload?.entry || []) {
    for (const change of entry.changes || []) {
      const v = change.value || {};
      const phoneNumberId = v.metadata?.phone_number_id;
      const names = Object.fromEntries((v.contacts || []).map((c) => [c.wa_id, c.profile?.name || '']));
      for (const m of v.messages || []) {
        let text = '';
        let replyId = null;
        if (m.type === 'text') text = m.text?.body || '';
        else if (m.type === 'interactive') {
          const r = m.interactive?.button_reply || m.interactive?.list_reply;
          text = r?.title || '';
          replyId = r?.id ?? null;
        } else if (m.type === 'button') { text = m.button?.text || ''; replyId = m.button?.payload ?? null; }
        else text = `[${m.type}]`;
        inbound.push({ phoneNumberId, waId: m.from, name: names[m.from] || '', text, replyId, wamid: m.id, type: m.type });
      }
      for (const s of v.statuses || []) {
        statuses.push({ phoneNumberId, wamid: s.id, status: s.status, error: s.errors?.[0]?.title || s.errors?.[0]?.message || null });
      }
    }
  }
  return { inbound, statuses };
}

/** Test/dev sender: records instead of sending. */
export class RecordingSender {
  constructor() { this.sent = []; this.failNext = null; }
  async send(business, to, msg) {
    if (this.failNext) { const e = this.failNext; this.failNext = null; throw new Error(e); }
    this.sent.push({ business: business.id, to, ...msg });
    return { wamid: `wamid.${this.sent.length}.${Math.random().toString(36).slice(2, 8)}` };
  }
  async sendTemplate(business, to, name) {
    this.sent.push({ business: business.id, to, template: name });
    return { wamid: `wamid.t${this.sent.length}` };
  }
}
