# Architecture

```
lib/
  main.dart                 UI entry: bootstrap → sync schedules → runApp
  app_services.dart         Composition root (also used by the background isolate)
  core/                     constants, theme/design tokens, logger (redacting), secure storage, utils
  domain/                   PURE DART – no Flutter widgets, no DB, no platform
    models/                 Workflow, WorkflowTrigger (sealed), WorkflowStep (sealed), Condition, ExecutionRecord
    engine/                 WorkflowEngine, VariableResolver, ConditionEvaluator, RetryPolicy, IdempotencyKeys, ports
    schedule/               ScheduleCalculator (IANA time zones, DST-safe)
    validation/             WorkflowValidator
  data/                     SQLite schema + repositories, SQL implementations of engine ports
  services/
    scheduler/              AlarmPlatform port, AlarmManager bindings, SchedulerService
    execution/              ExecutionService: load → guard → run → notify → re-arm, catch-up, approvals
    integrations/           Integration registry, WhatsApp (personal + business), HTTP/webhook/clipboard/url executors
    ai/                     AiProvider abstraction, OpenAI-compatible, Anthropic, local templates, NL parser
    connections/            ConnectionManager (live-verified status)
    notifications/          Channels + preferences
    templates/              Template gallery (pure workflow definitions)
    settings/               SettingsService (implements EngineStateProvider)
  state/                    AppState (ChangeNotifier the UI reads)
  ui/                       screens + widgets
```

## Workflow definition
Workflows are JSON (`Workflow.toJson`) stored in `workflows.definition`. The UI only reads/writes this model; nothing is hard-coded per workflow. Example: `assets/workflows/example_morning_dad.json`.

## Engine
`WorkflowEngine.execute()`:
1. **Validate** – broken definitions are refused (FAILED, `workflow.invalid`).
2. **Key** – scheduled runs: `IdempotencyKeys.forScheduledRun(workflow, scheduledFor)` = FNV-1a of `workflowId|date|time|target`. Manual/test runs get unique ad-hoc keys.
3. **Pause gate** – scheduled runs while paused → SKIPPED (`engine.paused`), slot not consumed.
4. **Claim** – `IdempotencyStore.claim` (SQLite `idempotency_keys` PRIMARY KEY). Loser → SKIPPED (`engine.duplicate`).
5. **Interpret** – a work queue; `IF` splices its branch onto the front. Action blocks go to a `StepExecutor` from the registry, wrapped in `RetryPolicy` (finite, exponential backoff, non-retriable failures stop at once).
6. **Park** – a block may return `awaitingApproval` (ticket persisted, run = WAITING_APPROVAL) or a WAIT may be deferred (run = PENDING with `resumeAt`). The remaining tail is stored in `resume_program`, so resume never re-runs earlier blocks.

States: PENDING · RUNNING · SUCCESS · FAILED · CANCELLED · SKIPPED · WAITING_APPROVAL.

Safety limits (`EngineLimits`): 64 blocks, 12 nested conditions, 12 h per WAIT, 24 h per run, ≤5 retries, 24 h approval TTL, runaway guard.

## Android background execution
* **No UI `Timer`s.** Each enabled scheduled workflow gets a one-shot `AndroidAlarmManager.oneShotAt(exact, alarmClock, allowWhileIdle, rescheduleOnReboot)` for its *next* occurrence. The callback (`automationAlarmCallback`) runs in a fresh isolate, rebuilds `AppServices` from the DB, runs, notifies, and re-arms.
* **Reboot:** the plugin's `RebootBroadcastReceiver` restores alarms (`RECEIVE_BOOT_COMPLETED`).
* **Maintenance wake** every 3 h: expire approvals, resume deferred WAITs, catch up missed slots (≤6 h old run; older → SKIPPED), re-sync alarms.
* **App start** does the same catch-up + sync, covering force-stop (which cancels alarms).
* **Doze / battery optimisation:** the Reliability screen shows the exemption state via a MethodChannel (`MainActivity.kt`) and opens the system dialog. The app never claims guaranteed execution.
* **Time zones:** schedules are evaluated in the workflow's IANA zone with `package:timezone`, so 07:00 stays 07:00 across DST.

## Security
* Secrets (AI key, WhatsApp token) → `flutter_secure_storage` (EncryptedSharedPreferences / Keystore). Never SQLite.
* Phone numbers live in `contacts`, referenced by alias; workflows never contain numbers. UI shows masked numbers.
* `Logger.scrub` redacts `token/api_key/authorization/secret/password` patterns; `ApiRequest.describe()` never prints headers.
* `allowBackup=false` + data-extraction rules exclude the DB and prefs from cloud backup/device transfer.
* No keys in source; `.gitignore` covers `.env`, keystores, `key.properties`.

## Extending
* **New block:** add a `StepKind` + `WorkflowStep` subclass (JSON in/out), a `StepExecutor`, register it in `AppServices._build`, and an editor case in `builder_screen.dart`.
* **New integration:** implement `Integration.check()` honestly and register it. It then appears on Connections; until then it is listed under *Planned* as NOT AVAILABLE.
* **New AI vendor:** implement `AiProvider` and register it.
* **iOS:** implement `AlarmPlatform` with BGTaskScheduler/local-notification triggers; nothing in `domain/` changes.
