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
* Cloud needs the `server/` backend deployed (Docker, `SECRET_KEY`, `PUBLIC_URL`). The app asks for its address when you sign in.
* Cloud "notification" steps appear in the Autometa Cloud inbox (`/v1/notifications`). Push notifications to the phone aren't implemented yet.
* Gmail and Google Calendar aren't available yet (they need Google OAuth verification).
