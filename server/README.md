# AUTOMETA Business server

Runs WhatsApp Business automations for the AUTOMETA app's **Business mode**: it receives the
official WhatsApp Cloud API webhook, runs your workflows, and serves the app's inbox, flows,
analytics, team, and billing screens. Zero dependencies; Node ≥ 22.5 (built-in SQLite).

```bash
cd server
npm test                      # 14 tests: API end-to-end + engine units
SECRET_KEY=$(openssl rand -hex 32) ADMIN_KEY=change-me node src/index.js
# or: docker build -t autometa-server . && docker run -p 8080:8080 -v autometa:/data --env-file .env autometa-server
```

It needs a public HTTPS URL that Meta can reach (Render, Railway, Fly, or a VPS behind Caddy).

## Connect WhatsApp (official Cloud API only)
1. developers.facebook.com → create app → add **WhatsApp**.
2. Configuration → Webhook URL `https://YOUR-HOST/webhook`, verify token = `WEBHOOK_VERIFY_TOKEN`; subscribe to **messages**.
3. Set `META_APP_SECRET` (App settings → Basic) so every webhook is signature-checked.
4. In the app: Business → Settings → Connect number. Paste the Phone number ID and a **permanent
   System User token**. Temporary tokens expire in 24 h.

## Plans and pricing
Features and limits live in `src/plans.js`; prices live in `src/pricing.js` (override with `PRICING_JSON`).
Entitlement checks only look at the plan, never the price. On downgrade nothing is deleted: extra
workflows stay saved and pause (shown as "Paused by plan" in the app). Lapsed renewals get 7 days of grace.

| | Free | Pro (₦5,000/mo) | Business (₦15,000/mo) |
|---|---|---|---|
| Businesses / numbers | 1 | 1 | 5 |
| Active workflows | 3 | unlimited | unlimited |
| Steps per workflow | 6: message, condition, handoff | 40: + question, capture, tag, delay, follow-up, assign | 120: + AI reply, webhook |
| FAQs | 10 | unlimited | unlimited |
| Team | owner only | 5 | 25, assigned-only permission |
| Analytics | – | 30 days | 365 days, busiest hours, errors |
| AI assistant | – | – | drafts, summaries, FAQ ideas, text→workflow (quota) |
| Audit log | – | – | ✓ |

## Setup service (manual onboarding)
```bash
curl -X POST https://HOST/admin/accounts -H "x-admin-key: $ADMIN_KEY" -H 'content-type: application/json' \
  -d '{"ownerName":"Ngozi","businessName":"Mama Put","plan":"pro","months":12,
       "templates":["greeting","restaurant_order","fallback"],"starterFaqs":true,
       "hours":{"mon":[["09:00","21:00"]]},"notes":"Paid ₦50k setup, transfer ref 123"}'
# → {"onboardingCode":"ABCD-EFGH-JKLM", ...}  The owner enters it in the app (valid 14 days).
```
`POST /admin/accounts/:id/subscription {"plan":"business","months":1}` activates bank-transfer payments.

## Google Play billing
Products `autometa_pro_monthly` and `autometa_business_monthly`. The app sends the purchase token to
`/billing/google/verify`; the server checks it with the Play Developer API (`GOOGLE_SERVICE_ACCOUNT_JSON`).
Point Real-time developer notifications (Pub/Sub push) at `/billing/google/rtdn?token=RTDN_TOKEN`.
Without credentials these return 501 and manual activation still works.

## Debugging a workflow
* App → workflow → **Test**: replays messages through the real engine with nothing sent and nothing counted.
* App → **Activity**: every run with a step-by-step trace (answers, retries, branch taken, send errors).
* Meta delivery failures (e.g. outside the 24 h window) come back as `send_failed` events in Analytics.
