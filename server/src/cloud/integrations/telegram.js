import { ActionError, callApi } from './base.js';

// Official Telegram Bot API. The user creates a bot with @BotFather, pastes its
// token, then sends /start to the bot (or adds it to a group/channel) so the
// bot is allowed to message that chat. Bots can't message people first.
const API = 'https://api.telegram.org';

function classify(res, body) {
  const desc = body?.description || `HTTP ${res.status}`;
  if (res.status === 401) return new ActionError('Telegram rejected the bot token.', { kind: 'auth', fix: 'Reconnect Telegram with a valid token from @BotFather.' });
  if (res.status === 403) return new ActionError(`Telegram: ${desc}`, { kind: 'config', fix: 'Open the chat with your bot and press Start (or re-add the bot to the group), then retry.' });
  if (res.status === 400 && /chat not found/i.test(desc)) return new ActionError('Telegram chat not found.', { kind: 'config', fix: 'Send /start to your bot, then pick the chat again in this step.' });
  if (res.status === 429) return new ActionError('Telegram rate limit reached.', { kind: 'rate_limit', retryAfterMs: (body?.parameters?.retry_after || 5) * 1000 });
  if (res.status >= 500) return new ActionError(`Telegram server error (${res.status}).`, { kind: 'transient' });
  return new ActionError(`Telegram: ${desc}`, { kind: 'permanent' });
}

async function tg(ctx, token, method, payload) {
  const { res, body } = await callApi(ctx.fetch, `${API}/bot${token}/${method}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload || {}),
  }, { provider: 'Telegram' });
  if (!res.ok || body?.ok === false) throw classify(res, body);
  return body.result;
}

export const telegram = {
  id: 'telegram',
  name: 'Telegram',
  category: 'messaging',
  description: 'Send messages from your own Telegram bot to you, a group or a channel.',
  docs: 'Create a bot: open @BotFather in Telegram, send /newbot, copy the token. Then open your new bot and press Start so it can message you. For groups add the bot to the group; for channels add it as an admin.',
  auth: { type: 'token', fields: [{ key: 'token', label: 'Bot token', type: 'password', required: true, placeholder: '123456:ABC-DEF…' }] },
  async connect(fields, ctx) {
    const token = String(fields.token || '').trim();
    if (!/^\d+:[\w-]{20,}$/.test(token)) throw new ActionError('That doesn\'t look like a bot token (it looks like 123456:ABC…).', { kind: 'config' });
    const me = await tg(ctx, token, 'getMe');
    return { identity: `@${me.username}`, secret: token, meta: { botId: me.id }, scopes: ['bot:send_message'] };
  },
  async test(conn, ctx) {
    const me = await tg(ctx, conn.secret, 'getMe');
    return { identity: `@${me.username}` };
  },
  /** Chats that recently messaged the bot, so users can pick instead of typing ids. */
  async listChats(conn, ctx) {
    const updates = await tg(ctx, conn.secret, 'getUpdates', { limit: 100, allowed_updates: ['message', 'channel_post', 'my_chat_member'] });
    const chats = new Map();
    for (const u of updates) {
      const c = u.message?.chat || u.channel_post?.chat || u.my_chat_member?.chat;
      if (c) chats.set(String(c.id), { id: String(c.id), title: c.title || [c.first_name, c.last_name].filter(Boolean).join(' ') || c.username || String(c.id), type: c.type });
    }
    return [...chats.values()];
  },
  triggers: {},
  actions: {
    send_message: {
      label: 'Send a Telegram message',
      description: 'Your bot sends a text message to a chat, group or channel.',
      config: [
        { key: 'chatId', label: 'Chat', type: 'chat', required: true, help: 'Pick a chat that has pressed Start on your bot, or paste a chat id / @channelname.' },
        { key: 'text', label: 'Message', type: 'textarea', required: true, variables: true },
        { key: 'silent', label: 'Send silently', type: 'select', options: [{ value: 'no', label: 'No' }, { value: 'yes', label: 'Yes' }] },
      ],
      idempotent: false,
      validate(cfg) {
        return String(cfg.text || '').length > 4096 ? ['Telegram messages are limited to 4096 characters'] : [];
      },
      simulate: (cfg) => ({ chatId: cfg.chatId, text: cfg.text }),
      async execute(cfg, conn, ctx) {
        const r = await tg(ctx, conn.secret, 'sendMessage', { chat_id: cfg.chatId, text: cfg.text, disable_notification: cfg.silent === 'yes' });
        return { messageId: r.message_id, chatId: String(r.chat?.id ?? cfg.chatId) };
      },
    },
  },
};
