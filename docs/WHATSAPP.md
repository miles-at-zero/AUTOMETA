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

## Policy: no consumer WhatsApp automation

The former opt-in "auto-send" edition (an Accessibility Service that tapped Send inside consumer WhatsApp) has been **removed**: the plugin, the `autosend` build flavor, the APK and all UI. Autometa will not use the consumer WhatsApp app as an automation backdoor, in either execution mode:

* no Accessibility or UI automation, simulated taps, unofficial clients/protocols or WhatsApp Web scraping;
* **personal WhatsApp** = *prepare → you confirm → you tap Send* (official `wa.me` click-to-chat). Runs on this device; it is never reported as "sent";
* **automatic sending** only through the official **WhatsApp Business API** (on this phone or from Autometa Cloud);
* a step set to "send" on a personal account is rejected by the validator and by the adapter.

Each WhatsApp block can still choose **Default / My WhatsApp / Business API** (`account` field in the step JSON).

Business Cloud API setup steps are shown in-app under Connections → WhatsApp → Business → "Setup guide".
