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
| 24 | WhatsApp personal vs Business separation | PARTIAL: stale auto-send copy and dead `autoSend` branch remained | **COMPLETE** | Personal: prepare → open WhatsApp → user taps Send. Business: automatic sending only via the official API. No auto-send copy, `autoSend` branch or `sentFromPhone` left (repo-wide search). A personal "send" is explained before activation (`whatsappSendProblems`) and fails visibly at run time (`whatsapp.send_unavailable`); it is never converted to prepare | yes, fixed (cc87004, final cleanup) | step.dart, whatsapp_*, app_state.dart, builder_screen.dart |
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

## Blocker-closure & deployment-prep pass (2026-10-05)

| Item | Status | Evidence |
|---|---|---|
| A. Consumer WhatsApp auto-send remnants | CODE COMPLETE | The auto-send copy, comments, the `autoSend` branch and the orphan `sentFromPhone` comment are removed. A personal-account `send` block now **fails visibly** (`whatsapp.send_unavailable`); the old silent downgrade to prepare is gone. Test: `database_test.dart`. `git grep -i "auto-send\|autosend\|sentFromPhone"` → only docs that explain it's unsupported. Row 24 is now COMPLETE. |
| B. Canonical `{{weekday}}` | CODE COMPLETE | App and server both resolve `{{weekday}}` to the day name. `{{day}}` is an explicit alias (`VariableResolver.aliases`, `VARIABLE_ALIASES`). Tests cover builder → saved → mapper → Cloud body (`execution_mode_test.dart`) and validator → engine → result (`v1.test.js`). |
| C. FCM client | Push implementation: CODE COMPLETE. Firebase config: EXTERNAL CONFIG REQUIRED. Real device: REAL DEVICE TEST REQUIRED | `lib/cloud/push_client.dart`, `firebase_push_transport.dart`, `test/push_test.dart`, docs/NOTIFICATIONS.md |
| D. Terminated-app navigation | CODE COMPLETE (mock-tested) / REAL DEVICE TEST REQUIRED | `PendingNavigation` + `getInitialMessage` + `getNotificationAppLaunchDetails` |
| `/health` | CODE COMPLETE | Real scheduler state (`not_started`/`running`/`stale`). A test proves no secret values leak. |
| Cloud URL | CODE COMPLETE | No default server and no localhost fallback. Release builds are https-only (`cloud_url_test.dart`). |
| Gmail unconfigured | CODE COMPLETE | "Unavailable: server configuration required"; Connect is disabled. |
| Legal & privacy centre | CODE COMPLETE; **DRAFTS PREPARED FOR LEGAL REVIEW** | docs/LEGAL.md |
| Export / delete account UI | CODE COMPLETE (server-tested) / REAL DEVICE TEST REQUIRED | Cloud account → Your data |
| Integration disclosures, activation review | CODE COMPLETE | `legal_texts.dart`, `activation_review.dart` + test |
| Deployment | DEPLOYMENT REQUIRED | server/DEPLOY.md. Docker is not built or tested. |


## Final code cleanup (before manual setup)

| Item | Status | Evidence |
|---|---|---|
| 1. Personal WhatsApp auto-send remnants | COMPLETE | Repo-wide search for auto-send / autoSend / sentFromPhone / "presses Send" / accessibility sending: the only hits are docs and a Gradle comment stating the feature was removed and is unsupported, plus unrelated Material/Keychain "accessibility" API names |
| 2. `{{weekday}}` canonical | COMPLETE | Builder, mapper, server validator and engine, tests and docs. `{{day}}` is an explicit alias |
| 3. Personal "send" explained before activation | COMPLETE | `AppState.whatsappSendProblems` blocks activation with an explanation (e2e test). Never converted to prepare |
| 4. Terminated-app deep link | COMPLETE (mock-tested) | `PendingNavigation`. A reconnect alert now opens that connection's reconnect flow directly |
| Device-only variables in Cloud | COMPLETE | The mapper reports e.g. `{{greeting}}` before saving (test) |

### Remaining CODE blockers
None known.

### Remaining EXTERNAL (not code)
Deployment, Google OAuth + verification, Firebase config, Meta WhatsApp Business, private signing key, legal review, real-device test plan.
