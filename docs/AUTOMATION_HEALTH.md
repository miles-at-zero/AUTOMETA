# Automation Health (foundation)

Health is a **state with reasons**, computed only from real execution records
(`lib/domain/health/automation_health.dart`). There is intentionally **no
numeric score** yet: the app sees only each automation's recent runs, and a
number would look more precise than the data allows.

## Data source (per execution mode, never mixed)
- **On this device:** device `ExecutionRecord`s for the automation. Dry runs and
  unfinished runs are excluded.
- **Cloud:** the `recent` runs returned by `GET /v1/automations/:id`. Test runs
  and `running` rows are excluded, and `partial` counts as a failure. If Cloud
  history can't be read (signed out or offline), the UI says so; nothing is
  guessed.

## Rules (first match wins)
| # | Condition | State |
|---|-----------|-------|
| 1 | Automation is off | ⚪ INACTIVE |
| 2 | A capability/configuration problem for its execution mode | 🟡 ATTENTION |
| 3 | No finished non-skipped runs yet | ⚫ UNKNOWN ("Not enough history") |
| 4 | The last 3 finished runs all failed (skips ignored) | 🔴 CRITICAL |
| 5 | The latest run failed, or any failure in the last 7 days | 🟡 ATTENTION |
| 6 | Otherwise | 🟢 HEALTHY |

Skipped runs (condition not met, duplicate, engine paused) are counted and
shown, but they are **never failures**.

"Most common failure" is shown only when the same reason occurred at least twice.

## Guardian v1
Guardian is `GET /v1/guardian` on the server (Cloud automations) plus
`GuardianFinding.forDevice` in the app (on-device automations). The two are
never mixed.

It's read-only. Findings are derived on request from authoritative data and
never stored, so a fixed problem disappears on the next check. Every finding has
`kind, severity, certainty, title, why, body, evidence, detectedAt, action`
(`open_automation` or `reconnect`, with the real id).

| Kind | Rule (evidence) | Certainty |
|---|---|---|
| `repeated_failures` / `paused_after_failures` | Last **3** finished runs failed (skips ignored), or the engine paused it (`status = error`) | certain |
| `connection_attention` | Connection status is not `connected` and not `disconnected` (e.g. `needs_reauth`, `error`). Critical when an active automation uses it. | certain |
| `missed_schedule` | A **tracked** slot (`schedule_slots`) in the last 7 days whose run is absent (`never`, after a 5-minute settle) or recorded by the engine as `Missed:` (server offline) | certain |
| `schedule_overdue` | Current `next_run_at` more than 15 minutes in the past and not yet processed | unusual |
| `recent_failures` | A failure in the last 7 days, or the latest run failed | certain |
| `looks_inactive` | Active, event-driven (no schedule), at least **5** runs, silent for more than **max(1 day, 3 × its own median gap)** | unusual |

Order: critical failures → connections → missed schedules → other failures →
inactivity. Home shows at most 3 findings, plus "+ N more".

### Expected-run tracking
`schedule_slots(automation_id, workspace_id, slot, consumed_at)` is written
only by `CloudEngine.tick` when it picks up a due slot. Each slot's outcome
comes from the run with `scheduled_for = slot`:

| Run for the slot | Outcome |
|---|---|
| success | ran |
| failed / partial | **failed** (a failure, never "missed") |
| skipped (condition, limit…) | skipped |
| skipped with `Missed:` | missed (server offline) |
| none, more than 5 minutes after consumption | never happened → missed |

**Limitation:** tracking starts when this version is deployed. Slots from
before that are never reconstructed, so older history can't produce
missed-schedule findings.

## Not yet (future passes)
- A numeric score. This needs server-side lifetime aggregates and connection
  history per automation.
- Spike and zero-result rules: runs don't record item counts yet.
- Duplicate/similar-automation detection.
- Turning findings into Notification Center entries (needs de-duplication, so it
  doesn't nag).
