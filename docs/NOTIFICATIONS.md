# Cloud notifications & push

Flow: execution event → `engine.notify()` (single choke point, stored in
`notifications`) → `PushService.dispatch()` → devices → tap opens the run.

## Which events notify
| Kind | Push-worthy | Deep link |
|---|---|---|
| `automation_failed` (deduped for 30 min per automation) | yes ("failures") | execution |
| `automation_paused` (after N failures) | yes ("failures") | execution |
| `connection_reauth` (token revoked → paused) | yes ("failures") | reconnect |
| `usage_warning` (80 %), `usage_limit` | yes ("account") | billing |
| `automation_message` (a Notify step) | yes ("messages") | — |
| ordinary success | **never** | — |

Per-device preferences `{failures, account, messages}` are sent with
`POST /v1/devices` and respected server-side.

## Server (implemented)
* `POST /v1/devices {token, platform, prefs}` / `DELETE /v1/devices {token}`
* FCM HTTP v1 sender (service-account JWT, RS256). Invalid tokens are removed
  (404/UNREGISTERED). Every attempt is written to `push_log`, including
  `not_configured`, so nothing is ever faked as "sent".
* Payload `data`: `notificationId, kind, severity, actionType, executionId, connectionId, automationId`.
* Tests: server/test/v1.test.js ("push: …").

**EXTERNAL CONFIG REQUIRED:** set `FCM_SERVICE_ACCOUNT_JSON` (a Firebase
project service account). `GET /health` reports `cloud.push`.

## Android app

Three separate states. Only the first is claimed:

| State | Status |
|---|---|
| Push client implemented | **CODE COMPLETE**: unit-tested with a fake transport and mocked server payloads (`test/push_test.dart`). Compiled by CI. |
| Firebase configured | **EXTERNAL CONFIG REQUIRED**: no `google-services.json` in the repository or in CI by default. |
| Real-device verified | **REAL DEVICE TEST REQUIRED**: never done. See `docs/DEVICE_TEST_PLAN.md` § Push. |

### What the code does
* `lib/cloud/push_client.dart` (`PushClient`):
  * initialises Firebase; asks for notification permission;
  * calls `getToken()` and registers it with `POST /v1/devices {token, platform, prefs}` after sign-in;
  * re-registers on `onTokenRefresh` and on preference changes;
  * calls `DELETE /v1/devices` on sign-out.
* Foreground: FCM shows nothing by itself, so the message is re-posted as a local notification on the `cloud_alerts` channel. It carries the deep link and a stable id derived from `notificationId`.
* Background: Android shows the notification on its own, using the server's `channel_id: cloud_alerts`; the manifest names the same default channel and icon. A tap arrives through `onMessageOpenedApp`. The top-level background handler is a deliberate no-op.
* Terminated (cold start): `main()` reads the FCM `getInitialMessage()` and the local `getNotificationAppLaunchDetails()` before `runApp`. The destination is parked in `PendingNavigation` and consumed once, after the app shell's first frame (`lib/ui/app.dart`):
  * `execution` → `CloudExecutionScreen(executionId)`;
  * `reconnect` → the Cloud account / connections screen, which has the Reconnect buttons;
  * anything else → the Activity tab.
* Statuses shown in Cloud account → Phone alerts:
  * *Not configured in this build*: no Firebase config.
  * *Notifications blocked*: permission denied.
  * *Server push not configured*: the device is registered, but the server lacks `FCM_SERVICE_ACCOUNT_JSON`.
  * *Push alerts on*: registered and the server can push.
  * *Push unavailable*: registration failed.
* Preferences: three switches (failures/pauses/reconnects; usage limits; automation messages). They are stored locally and sent with the device registration; the server enforces them.
* Polling fallback: the in-app alerts poll (app start and resume) stays on. While push is fully active, it only advances its marker, so alerts aren't shown twice; otherwise, it shows them.

### Enabling push (owner steps)
1. Create a Firebase project and add an Android app with package `dev.autometa.app`.
2. Download `google-services.json` and either:
   * place it at `android/app/google-services.json` for local builds (it is git-ignored; see the `.example` template); or
   * store its full contents as the GitHub Actions secret `GOOGLE_SERVICES_JSON`. CI writes the file before building.
3. Create a service account with the Firebase Cloud Messaging API enabled. Set its JSON as `FCM_SERVICE_ACCOUNT_JSON` on the server.
4. Rebuild the APK, sign in, and open Cloud account → Phone alerts. It must say "Push alerts on".
5. Run the device test plan's push section.

Without step 2, the Gradle build logs a warning and builds without the google-services plugin. The app then reports "Not configured in this build".
