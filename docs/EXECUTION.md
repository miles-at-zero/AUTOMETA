# Execution modes: Cloud and On-device

> **Locked decision.** Autometa supports Cloud and On-device execution. Cloud is recommended by default. On-device execution is available for eligible local automations and is subject to operating-system restrictions. Capability restrictions are enforced per trigger/action. Execution mode never bypasses integration or platform rules. Consumer WhatsApp auto-send is not supported.

| Mode | Where it runs | Phone must be open? | Account/server? |
|---|---|---|---|
| ☁️ Cloud (default, recommended) | Autometa backend: scheduler, job queue, workers (`server/src/cloud`) | No | Yes |
| 📱 On this device | This phone: Android AlarmManager and the local engine (`lib/domain/engine`) | Depends on the OS | No |

## One automation model
`Workflow.executionMode` (`ExecutionMode.cloud` / `ExecutionMode.onDevice`, stored as `execution_mode`) is a property of the automation. Both modes share the trigger, condition and step models, the validator and the status model. Only the execution adapter differs:

```
Cloud:     App → /v1 API → automations table → scheduler/job queue → worker → integration adapter → execution log → App
On-device: App → local SQLite → AlarmManager → local engine → local action → local execution log
```

* Cloud automations are **never armed on the phone**: `Workflow.runsLocally` is false, and the scheduler, catch-up and event entry points skip them. Saving or activating one syncs it to the backend (`CloudSession.sync`). The app only configures and monitors it.
* Definitions saved before this change have no `execution_mode` field and stay **On this device**. Nothing was deleted.
* New automations take the default from Settings → Automation defaults (Cloud unless changed). Templates that contain device-only blocks are created On-device.

## Capabilities (`lib/domain/capabilities/execution_capabilities.dart`)
| Trigger / block | Cloud | On-device |
|---|---|---|
| Schedule (daily, days, weekly, monthly, interval) | ✅ | ✅ (subject to OS rules) |
| Manual | ✅ | ✅ |
| Webhook trigger | ✅ | ❌ (a phone can't receive webhooks) |
| One-off date & time | ❌ for now | ✅ |
| Phone events | ❌ | ✅ |
| Notification | ✅ (Autometa inbox) | ✅ (Android notification) |
| HTTP request / outgoing webhook | ✅ (public https only) | ✅ |
| Wait | ✅ | ✅ |
| Condition | ✅ when it's the last block, has no ELSE, and tests a `{{variable}}` with a supported operator | ✅ |
| WhatsApp: send via the official Business API | ✅ | ✅ |
| WhatsApp: prepare a message (you tap Send) | ❌ (needs the phone) | ✅ |
| WhatsApp: silent send from personal WhatsApp | ❌ never | ❌ never |
| AI, clipboard, open URL, set variable | ❌ for now | ✅ |

The builder hides unavailable blocks and triggers and lists them separately, together with the reason. The validator refuses activation in a mode that can't run every block. Drafts may still be saved.

## Migration
* **Move to Cloud** (automation detail):
  - It checks the trigger, the conditions and every action.
  - If anything is incompatible, nothing changes and a sheet names each blocking step, with *Keep On-device* and *Edit automation* buttons.
  - Otherwise it creates the Cloud copy with the same name and trigger/condition/action configuration, switches the mode, cancels the phone's alarms, and confirms.
  - Local run history stays on the automation.
* **Move to this device** is offered only when every block can run locally. The Cloud copy is paused, not deleted, so its history remains.

## Offline
* Cloud: the automation keeps running on the server. The app shows "offline" and catches up when it reconnects.
* On-device: runs follow Android's rules. A late or blocked run is recorded as skipped or failed, with remediation steps on the Background reliability screen. A run is never reported as successful when the OS prevented it.

## Current limits (honest)
* Cloud needs the `server/` backend deployed (see `server/DEPLOY.md`). The app asks for its address when you sign in, or a build can preset it with `--dart-define=AUTOMETA_CLOUD_URL=https://…`.
* Cloud "notification" steps and failure alerts appear in the Autometa Cloud inbox (`/v1/notifications`). The app shows important ones (failures, paused, reconnect needed, usage limits) as phone notifications **when it is opened or resumed**. The server can push them with FCM HTTP v1, but the Android app has no FCM client yet because it needs a Firebase `google-services.json`. **EXTERNAL CONFIG REQUIRED.** See `docs/NOTIFICATIONS.md`.
* Gmail (new-email trigger, send email) is implemented in Cloud with Google OAuth. It needs Google credentials on the server and, before a public launch, Google's restricted-scope verification. **EXTERNAL CONFIG REQUIRED.** See `docs/GMAIL.md`.
* Google Calendar: **DEFERRED FROM V1.** It isn't listed anywhere in the app or the catalog.

## On-device limits (honest)
* Runs only while Android lets Autometa run. Battery saver, "restricted" battery mode and OEM task killers can delay or drop alarms.
* Exact times need the "Alarms & reminders" permission (Android 12+). Without it, Android may shift runs by minutes.
* After a reboot, alarms are re-armed when the boot broadcast arrives or the app is next opened. Missed runs are recorded as skipped, never as successful.
* A force-stop from Settings cancels every alarm until the app is opened again (an Android rule).
* Personal WhatsApp steps need you: the phone must be unlocked and you tap Send.

## Variables shared by Cloud and On-device

`{{weekday}}` is the canonical weekday variable and resolves to the day name ("Sunday") in both modes.
`{{day}}` is an explicit compatibility alias with the same value: the app rewrites it to `{{weekday}}` when it sends an automation to Cloud, and the server accepts the bare `day` as an alias (`VARIABLE_ALIASES` in `server/src/cloud/validate.js`).
The builder only offers `{{weekday}}`.

Breaking change for on-device automations: `{{weekday}}` used to mean "is it a weekday" (`true`/`false`). That flag is now `{{is_weekday}}`; `{{weekend}}` and `{{day_type}}` are unchanged.
Variables that exist only on the device (for example `{{greeting}}`, `{{day_short}}`, `{{name}}`) are rejected by the Cloud validator with an "Unknown variable" check rather than silently resolving to empty text.
