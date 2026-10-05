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

## Android app (current)
* **Implemented:** in-app fallback. On app start and every resume the app
  fetches `/v1/notifications` and shows new push-worthy items as Android
  notifications. Tapping one opens the Cloud run detail (`cloudexec:<id>`) or
  the Cloud connections screen (`cloudreconnect:<id>`).
* **Not implemented (EXTERNAL CONFIG REQUIRED):** a real FCM client
  (`firebase_messaging`) that receives pushes while the app is closed. It needs
  a Firebase project and `android/app/google-services.json`, which can't be
  committed without the owner's Firebase project. Once added, register the token
  with `POST /v1/devices` after sign-in and route `data.executionId` to
  `CloudExecutionScreen`.
* Opening the app from a terminated state via a notification tap isn't routed
  yet; the app opens on Home.
