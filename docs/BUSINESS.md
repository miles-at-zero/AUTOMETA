# Business mode

Personal mode (your own reminders and automations) is unchanged. **Business mode** turns customer
WhatsApp conversations into an organised workflow, using the official WhatsApp Business Platform.

Open it from **Home → Business mode** or **Settings → Mode**. Use the person icon at the top right to go back to Personal.

| Tab | What it does |
|---|---|
| **Inbox** | Every customer, with chats that need a person shown first. Reply within WhatsApp's 24 h window, tag, assign, hand back to automation. AI draft and summary on Business. |
| **Workflows** | Templates (food order, booking/lead, welcome, away hours, office-hours router, fallback). A step editor with message, question, if/else, business hours, wait, tag, save detail, assign, follow-up, hand to staff, track, go to, AI reply and webhook. **Test** replays a chat with nothing sent. **Activity log** shows every run step by step. **FAQs**. |
| **Insights** | Conversations, automated replies, leads, orders started/completed, handoffs, automation rate, bot and staff response times, activity chart, top workflows, errors. |
| **More** | Connect your number, hours and settings, team invites, plan and billing, audit log, switch business. |

## Getting started
1. Deploy `server/` (see `server/README.md`) or get a setup code from your installer.
2. In the app, Business mode → enter the server address → setup code (or "Start free").
3. More → WhatsApp number → follow the 4 steps, then paste the Phone number ID and a System User token.
4. Workflows → New → template → **Test** → switch it on.

Plans are enforced by the server. The app only shows them. Purchases go through Google Play and are
verified by the server, and bank-transfer or setup-service customers are activated by the operator.
