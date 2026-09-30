# WhatsApp in AUTOMETA

Personal and Business are **different integrations**. The user picks one; only that adapter is ever used.

## Personal account
There is no official API for sending from a personal WhatsApp account. AUTOMETA therefore uses only the documented **click-to-chat** link:

```
https://wa.me/<digits>?text=<url-encoded message>
```

Flow: trigger → AUTOMETA prepares the message → **approval** notification → user taps Approve → WhatsApp opens with the text prefilled → **user taps Send**.

Reported as `Handed to WhatsApp — you tap Send`. AUTOMETA cannot observe the Send tap, so it never shows “Sent”.

Not used, by design: WhatsApp Web scraping, Selenium/Playwright, reverse-engineered protocols, unofficial client libraries, QR/session extraction, anti-ban tricks.

Capabilities shown: ✓ Open conversations ✓ Prepare messages. Automatic sending: *Not available for this account type.*

## Business account (WhatsApp Business Platform – Cloud API)
Verified against Meta's reference (2026): `POST https://graph.facebook.com/{Version}/{Phone-Number-ID}/messages`, `Authorization: Bearer <token>`, body `{"messaging_product":"whatsapp","recipient_type":"individual","to":"…","type":"text","text":{"body":"…"}}` or `"type":"template"`. Graph API v26.0 was current at build time; the version is a setting because Meta retires versions on a ~2-year cycle.

You must do these in Meta Business Manager first:
1. Create a Meta developer app and add the WhatsApp product.
2. Complete business verification.
3. Register a phone number → note its **Phone Number ID**.
4. Create a **system user** access token with `whatsapp_business_messaging`.
5. Create and get **templates approved** — required for business-initiated messages outside the 24-hour customer-service window.

Connection check: `GET /{version}/{phone-number-id}?fields=verified_name,display_phone_number,quality_rating`. Only a 200 marks it Connected. Send success means Meta **accepted** the message (message id returned); `held_for_quality_assessment` is shown as held, `paused` as failed.

Delivery/read receipts arrive through Meta **webhooks**, which need a public HTTPS server — a phone cannot receive them directly. Host a small relay (Meta → your server → AUTOMETA webhook trigger) if you want read receipts.

## Update: on-device auto-send (Personal)

Personal accounts can now send by themselves when the user opts in:

* Local plugin `packages/whatsapp_auto_send` adds an Android **Accessibility Service** scoped to `com.whatsapp` / `com.whatsapp.w4b`.
* On a `send` step it opens the official click-to-chat link, checks the input box holds exactly the automation's text, presses Send, and reports **"Sent from your phone"** only after WhatsApp clears the input box.
* The screen can be woken, but a PIN/pattern/biometric lock is never bypassed. If the phone is locked, the step fails with a clear reason and is retried.
* If Send was tapped but not confirmed, the step fails **without retry** so no duplicate message goes out.
* Default approval policy: personal steps need approval unless auto-send is on and the step mode is "Send message".
* Each WhatsApp block can choose **Default / My WhatsApp / Business API** (`account` field in the step JSON).
* WhatsApp's terms do not sanction automation. The app says so before the user enables it.

Business Cloud API setup steps are shown in-app under Connections → WhatsApp → Business → "Setup guide".
