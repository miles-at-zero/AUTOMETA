# Autometa V1: intermediate gap audit (2026-10-05)

I verified this audit against the code, not against earlier reports.
Statuses: COMPLETE · PARTIAL · MISSING · MOCKED · DISCONNECTED · BROKEN ·
EXTERNAL CONFIG REQUIRED · DEFERRED FROM V1.
"Before" is the state at c3d3d76. "After" is this pass.

## Gap matrix

| # | Requirement | Before | After | What exists / what's missing | Blocks V1? | Files |
|---|---|---|---|---|---|---|
| 1 | Docker image can write its DB | **BROKEN**: `VOLUME /data` with `USER node` and no chown, so the first write fails | COMPLETE | `mkdir/chown /data`, HEALTHCHECK, SIGTERM shutdown. Smoke-tested with node; the image wasn't built here (no Docker in the sandbox) | yes, fixed | server/Dockerfile, src/index.js |
| 2 | Env template / config docs | PARTIAL: no PUBLIC_URL, Google or FCM vars | COMPLETE | `.env.example`, `server/DEPLOY.md` checklist | yes, fixed | server/.env.example, server/DEPLOY.md |
| 3 | Health endpoint | PARTIAL | COMPLETE | `/health` → `cloud:{scheduler,gmail,push,publicUrl}`. Startup log prints the same booleans only | no | src/app.js, cloud/api.js |
| 4 | SECRET_KEY enforcement, token encryption | COMPLETE | COMPLETE | Refuses to start in production without it. AES-GCM at rest | — | src/app.js, crypto.js |
| 5 | Cloud deployment | EXTERNAL CONFIG REQUIRED | EXTERNAL CONFIG REQUIRED | Not deployed (no host or credentials). Checklist written | yes (operator) | server/DEPLOY.md |
| 6 | App dev/prod server URL | MISSING (typed manually) | COMPLETE | `--dart-define=AUTOMETA_CLOUD_URL` prefill. Still editable | no | lib/cloud/cloud_session.dart |
| 7 | Client flow: signup/login/create/activate/schedule/execute/Activity | COMPLETE (server tests + app) | COMPLETE | Session expiry → sign-out with message. Offline keeps the cached state. Workspace isolation tested | — | test/cloud.test.js |
| 8 | Cloud run detail in app | PARTIAL (rows not tappable) | COMPLETE | `CloudExecutionScreen`: steps, ✓/✕ condition detail, error, fix, Retry, Reconnect. Reached from Activity and automation history | no | lib/ui/screens/cloud_execution_screen.dart |
| 9 | Gmail OAuth/connect | MISSING (not registered) | COMPLETE in code · **EXTERNAL CONFIG REQUIRED** | PKCE, single-use state, encrypted refresh token, scope check, reconnect keeps the id. Unavailable (disabled, with the reason) when unconfigured | yes for the Gmail journey | cloud/integrations/gmail.js, cloud/api.js |
| 10 | Gmail refresh / revoked → reconnect | MISSING | COMPLETE (tested with a fake Google) | `invalid_grant`/401 → needs_reauth → automation paused → notification → OAuth reconnect | — | engine.js |
| 11 | Gmail trigger (new email) | MISSING | COMPLETE (polling ~60 s) | The cursor starts at activation, so the backlog is skipped. Dedupe per email | — | engine.pollTriggers |
| 12 | Gmail action (send) | MISSING | COMPLETE | Recipient validation, header-injection guard, not idempotent | — | gmail.js |
| 13 | Gmail in app builder/capabilities | MISSING | COMPLETE (CI-verified) | `GmailTrigger`, `GmailSendStep`; Cloud-only; mapper requires a Cloud Gmail connection | — | lib/domain/models/*, cloud_mapper |
| 14 | Google public launch | — | EXTERNAL CONFIG REQUIRED | Restricted-scope verification + CASA | before public launch | docs/GMAIL.md |
| 15 | Google Calendar | MISSING | **DEFERRED FROM V1** | Not listed anywhere (test asserts this). No dead button | no | integrations/index.js |
| 16 | Notification inbox (server) | COMPLETE | COMPLETE | Failure / paused / reauth / usage, with deduplication | — | engine.notify |
| 17 | Device push (server) | MISSING (`afterFinish` hook was empty) | COMPLETE in code · **EXTERNAL CONFIG REQUIRED** | `devices` table and API, FCM v1 sender, preferences, invalid-token cleanup, `push_log`; successes never push | — | cloud/push.js |
| 18 | Device push (Android FCM client) | MISSING | **EXTERNAL CONFIG REQUIRED** / PARTIAL | Needs Firebase `google-services.json`. Fallback: alerts are polled on start/resume and shown as local notifications that deep-link to the run or reconnect | for push while the app is closed | lib/cloud/cloud_session.dart, lib/ui/app.dart |
| 19 | Conditions: eq/ne/contains/not contains | COMPLETE | COMPLETE | Both engines | — | |
| 20 | Conditions: AND/OR | PARTIAL (server only; Plus-gated; app had a single rule) | COMPLETE | App: up to 5 rules plus All/Any; Free gets 3 per block | — | step.dart, builder_screen, workflow_engine |
| 21 | Invalid variable / unsupported operator / empty | MISSING (op silently coerced; mode coerced to `all`) | COMPLETE | Server validator rejects these. The app validator blocks empty conditions | — | cloud/validate.js, api.js cleanSteps |
| 22 | Condition results in test/logs | PARTIAL (✓/✕ without values) | COMPLETE | `(was "actual")` / `(field not available in this run)` | — | engine.js |
| 23 | ELSE in Cloud | MISSING | **DEFERRED FROM V1** | Blocked with an explanation in the app | no | execution_capabilities |
| 24 | WhatsApp personal vs Business separation | PARTIAL: neutral labels ("Send automatically", "Prepare message"); dead `sentFromPhone` state from the removed auto-send build ("AUTOMETA pressed Send") | COMPLETE | Labels: "Personal WhatsApp: prepare (you tap Send)" / "WhatsApp Business: send automatically (official API)". `sentFromPhone` removed. The Personal "send" mode stays unsupported everywhere | yes, fixed | step.dart, whatsapp_* |
| 25 | No silent personal → Business migration | COMPLETE | COMPLETE | The mapper only maps `mode==send`; prepare stays on-device | — | cloud_mapper |
| 26 | Dad reminders | COMPLETE | COMPLETE | Templates use **Personal WhatsApp prepare** (on-device, you tap Send) | — | template_gallery.dart |
| 27 | Execution mode UX (☁️/📱, Cloud default for new, legacy kept) | COMPLETE | COMPLETE | Verified in tests | — | execution_mode_test |
| 28 | On-device limitation copy | PARTIAL | COMPLETE | Battery, exact alarms, reboot, force-stop and unlock requirements documented | no | docs/EXECUTION.md |
| 29 | Postgres / multi-instance | — | DEFERRED FROM V1 | SQLite, single process | no | |

## Critical scenarios (tests)
Server (`cd server && npm test`, 29 tests):
- Cloud lifecycle, revoke → pause → reconnect → retry (cloud.test.js journey)
- Gmail OAuth → trigger + AND condition → Telegram; backlog skipped; refresh; revoke → pause → OAuth reconnect (v1.test.js)
- Gmail send (v1.test.js)
- Gmail unavailable without credentials; Calendar not listed (v1.test.js)
- Push: failure pushes with a deep link, success doesn't, preferences respected, `not_configured` logged (v1.test.js)
- Conditions: eq, neq, contains, AND, OR, missing field, invalid variable, `steps.` ordering, unsupported operator, empty, invalid mode, Free rule cap (v1.test.js)
- Isolation, limits, retries/receipts, webhooks, schedule DST (cloud.test.js)

Flutter (CI): capabilities, mapper (AND/OR, Gmail), legacy migration, personal WhatsApp never sent, blocked migration, empty condition validation.

## Remaining blockers (not fixed here)
1. No deployed server (operator). See server/DEPLOY.md.
2. Google OAuth credentials, plus verification before a public launch.
3. Firebase project + `google-services.json` for push while the app is closed.
4. Device testing on a real phone (docs/DEVICE_TEST_PLAN.md) hasn't been done in this environment.
