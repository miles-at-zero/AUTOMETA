# Gmail (Autometa Cloud)

Status: **implemented, EXTERNAL CONFIG REQUIRED.** Without Google credentials the
server lists Gmail as *unavailable* with the reason. The app disables the
Connect button and any automation using Gmail can't be activated.

## What works
| Piece | Where |
|---|---|
| OAuth 2.0 authorization-code flow with PKCE (S256) and a single-use state that expires after 10 min | `POST /v1/oauth/gmail/start`, `GET /oauth/google/callback` (server/src/cloud/api.js) |
| Scopes: `gmail.readonly`, `gmail.send`. Missing scopes or no refresh token → not connected, with a clear message | server/src/cloud/integrations/gmail.js |
| Tokens encrypted at rest (AES-GCM with `SECRET_KEY`). Never returned by the API and never logged | connections.secret_enc |
| Access-token refresh. Refreshed tokens are persisted | `accessToken()` |
| Revoked/expired grant (`invalid_grant`) or 401 → connection `needs_reauth`, automation paused, `connection_reauth` notification with a Reconnect action | engine `onFailure` |
| Reconnect keeps the same connection id. Paused automations can then be turned back on | `POST /v1/oauth/gmail/start {connectionId}` |
| Trigger **New email** (Gmail search query), polled about every 60 s by the server scheduler. The cursor starts at activation, so older mail never fires. Each email runs at most once | engine `pollTriggers` |
| Action **Send an email** (to/subject/body, variables allowed, header-injection guarded). Not idempotent: an ambiguous 5xx is not retried blindly | `send_email` |
| Variables: `{{email.from}}`, `{{email.fromEmail}}`, `{{email.to}}`, `{{email.subject}}`, `{{email.snippet}}`, `{{email.date}}`, `{{email.id}}` | |
| Flutter: "New email (Gmail)" trigger and "Gmail: send email" block. Both are Cloud-only (capability-gated); connect via the browser from Settings → Cloud account | |
| Tests: server/test/v1.test.js (OAuth, backlog skip, condition, refresh, revoke → pause → reconnect, send) | |

## Operator setup
1. In Google Cloud Console, create a project and enable the **Gmail API**.
2. On the OAuth consent screen, add the two scopes above. While in *Testing*, add your test users.
3. Under Credentials, create an OAuth client of type **Web application** with the authorized redirect URI `https://YOUR-HOST/oauth/google/callback`.
4. Set `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `PUBLIC_URL=https://YOUR-HOST` on the server.
5. Check that `GET /health` shows `cloud.gmail: true`.

Public launch: `gmail.readonly` is a *restricted* scope. Google requires app
verification and an annual third-party security assessment (CASA). Until then,
only the test users you list can connect (max 100), and their refresh tokens
expire after 7 days in Testing mode.

## Google verification (before any public launch). **EXTERNAL / USER ACTION**
Nothing below has been started. Order of work:
1. **Stay in Testing** for internal and beta use. Only the listed test users (up to 100) can connect, Google shows them an "unverified app" warning, and their refresh tokens expire after 7 days. When that happens, Autometa pauses the automation and asks for **Reconnect**, which is the tested `connection_reauth` path.
2. **Prerequisites for verification:**
   * a verified domain (Search Console) that hosts the app homepage;
   * a public privacy policy on the same domain. The in-app Privacy text is a draft *prepared for legal review*, not a final policy;
   * terms of service;
   * an app logo;
   * a support email.
3. **Scope justification:**
   * `gmail.send` is *sensitive*.
   * `gmail.readonly` is *restricted*.
   * Explain why each is needed: the new-email trigger needs read access; the send-email action needs send access.
   * Record a demo video of the OAuth flow and the feature that uses each scope.
   * The privacy policy must include Google's Limited Use disclosure.
4. **Restricted scope:** Google requires an annual third-party security assessment (CASA) for `gmail.readonly`. Budget time and money for it.

   Alternative: ship send-only first, which drops the Gmail trigger. That is a product decision for the owner.
5. After approval, switch the consent screen to *In production* and run the Gmail section of `docs/DEVICE_TEST_PLAN.md` again with a non-test account.

## Not in V1
Attachments, labels/archiving, replies in a thread, push (Pub/Sub watch)
instead of polling, and Google Calendar (**DEFERRED FROM V1**).
