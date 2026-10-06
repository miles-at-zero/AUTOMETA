// AI assistant (Business plan). Cost controls:
//  * monthly per-business quota from the plan (aiCallsPerMonth)
//  * response cache keyed by task + input hash (repeat questions are free)
//  * deterministic logic first (rule-based categorisation, FAQ keyword match)
//  * short prompts, capped output tokens, last 12 messages only
import { J } from './db.js';
import { sha256 } from './crypto.js';
import { planOf } from './entitlements.js';
import { validateFlow, NODE_TYPES, TRIGGER_TYPES } from './engine.js';
import { PlanError } from './entitlements.js';

export class AiService {
  constructor({ db, planFor, env = process.env, fetchImpl = globalThis.fetch, clock = () => Date.now() }) {
    Object.assign(this, { db, planFor, fetchImpl, clock });
    this.baseUrl = (env.AI_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');
    this.apiKey = env.AI_API_KEY || '';
    this.model = env.AI_MODEL || 'gpt-4o-mini';
  }

  get configured() { return !!this.apiKey; }
  month() { return new Date(this.clock()).toISOString().slice(0, 7); }

  usage(business) {
    const used = this.db.prepare('SELECT calls FROM ai_usage WHERE business_id = ? AND month = ?').get(business.id, this.month())?.calls || 0;
    const limit = planOf(this.planFor(business.account_id)).limits.aiCallsPerMonth;
    return { used, limit, month: this.month() };
  }

  async complete(business, task, system, user, { maxTokens = 300, json = false } = {}) {
    const key = sha256(`${task}|${this.model}|${system}|${user}`);
    const cached = this.db.prepare('SELECT result FROM ai_cache WHERE key = ?').get(key);
    if (cached) return { text: cached.result, cached: true };
    if (!this.configured) throw Object.assign(new Error('AI is not configured on this server (AI_API_KEY)'), { status: 503 });
    const { used, limit } = this.usage(business);
    if (limit != null && used >= limit) throw new PlanError(`AI limit reached for this month (${limit} requests).`, { limit: 'aiCallsPerMonth' });
    const res = await this.fetchImpl(`${this.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { authorization: `Bearer ${this.apiKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        model: this.model, max_tokens: maxTokens, temperature: 0.3,
        ...(json ? { response_format: { type: 'json_object' } } : {}),
        messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
      }),
      signal: AbortSignal.timeout(30000),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error?.message || `AI HTTP ${res.status}`);
    const text = body?.choices?.[0]?.message?.content?.trim() || '';
    this.db.prepare('INSERT INTO ai_usage (business_id, month, calls) VALUES (?,?,1) ON CONFLICT(business_id, month) DO UPDATE SET calls = calls + 1').run(business.id, this.month());
    this.db.prepare('INSERT OR REPLACE INTO ai_cache (key, result, created_at) VALUES (?,?,?)').run(key, text, this.clock());
    return { text, cached: false };
  }

  transcript(customer, limit = 12) {
    return this.db.prepare('SELECT direction, text FROM messages WHERE customer_id = ? ORDER BY created_at DESC LIMIT ?').all(customer.id, limit)
      .reverse().map((m) => `${m.direction === 'in' ? 'Customer' : 'Business'}: ${m.text}`).join('\n');
  }

  async draftReply(business, customer, { instructions = '' } = {}) {
    const sys = `You write short, friendly WhatsApp replies for "${business.name}", a small business. Max 3 sentences. Never invent prices, stock or promises; if unsure, say a team member will confirm. ${instructions}`;
    return (await this.complete(business, 'draft', sys, this.transcript(customer))).text;
  }

  async summarize(business, customer) {
    const sys = 'Summarise this WhatsApp conversation for a busy shop owner in 2-4 bullet points: what the customer wants, details given, what is still needed.';
    return (await this.complete(business, 'summary', sys, this.transcript(customer, 30), { maxTokens: 220 })).text;
  }

  async suggestFollowup(business, customer) {
    const sys = `Suggest ONE short, polite WhatsApp follow-up message ${business.name} could send to move this conversation forward. Reply with the message only.`;
    return (await this.complete(business, 'followup', sys, this.transcript(customer))).text;
  }

  async categorize(business, text) {
    const sys = 'Classify the customer message into exactly one of: order, booking, pricing, complaint, support, greeting, other. Reply with the single word.';
    const out = (await this.complete(business, 'category', sys, String(text).slice(0, 500), { maxTokens: 5 })).text.toLowerCase().trim();
    return ['order', 'booking', 'pricing', 'complaint', 'support', 'greeting'].includes(out) ? out : 'other';
  }

  async suggestFaqs(business) {
    const rows = this.db.prepare(`SELECT text FROM messages WHERE business_id = ? AND direction = 'in' ORDER BY created_at DESC LIMIT 200`).all(business.id);
    const sys = 'From these customer messages, propose up to 6 FAQ entries a small business should automate. Return JSON {"faqs":[{"keywords":["..."],"answer":"..."}]}. Use [placeholders] for facts you don\'t know.';
    const r = await this.complete(business, 'faqs', sys, rows.map((r) => r.text).join('\n').slice(0, 6000), { maxTokens: 600, json: true });
    return J.parse(r.text, {}).faqs || [];
  }

  async flowFromText(business, description) {
    const sys = `Convert the business owner's description into an AUTOMETA WhatsApp workflow. Return ONLY JSON: {"name":"...","trigger":{"type":one of ${JSON.stringify(TRIGGER_TYPES)},"keywords":[...]},"nodes":[...]}.
Node types: ${NODE_TYPES.join(', ')}. Shapes: message{id,type,text}; question{id,type,text,input:"text"|"number"|"choice",saveAs,choices:[{label,value,next?}]}; condition{id,type,rules:[{if:{kind:"var"|"business_hours"|"tag",var,op,value},next}],else}; tag{id,type,tags}; capture{id,type,field,value,lead?}; track{id,type,event:"order_started"|"order_completed"|"lead_captured"}; handoff{id,type,text,reason}; delay{id,type,minutes}; followup{id,type,minutes,text}; end{id,type}.
Use {{name}} and {{saveAs}} placeholders. Steps run in order unless next is given. Keep it under 15 steps.`;
    const r = await this.complete(business, 'flow', sys, String(description).slice(0, 2000), { maxTokens: 1200, json: true });
    const flow = J.parse(r.text, null);
    if (!flow) throw new Error('AI returned something that is not a workflow. Try describing it differently.');
    const check = validateFlow(flow, this.planFor(business.account_id));
    return { flow, validation: check };
  }
}
