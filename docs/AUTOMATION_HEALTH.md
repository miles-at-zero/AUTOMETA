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

## Guardian (foundation)
`GET /v1/guardian` (server, read-only, no schema change) and
`GuardianFinding.forDevice` (app) turn real data into findings. Each finding
records its **certainty**:

| Finding | Source | Certainty |
|---|---|---|
| Paused after repeated failures | automation `status = error` + stored reason | certain |
| Repeated failures (3 in a row) / recent failures (7 days) | execution rows | certain |
| Connection needs reconnect / has a problem | connection `status`, linked to the automations that reference it | certain |
| Scheduled run looks overdue (> 15 min past `next_run_at`) | automation row | unusual |
| Looks unusually quiet (event-driven, at least 5 runs, silent > 3× its median gap and > 1 day) | execution rows | unusual |

"Unusual" findings are always worded as "looks …" in the UI, with "This may be
expected". Cloud findings come only from the server, and on-device findings only
from this phone; they are never mixed. Home shows the GUARDIAN panel only when
at least one automation is active. If Cloud can't be checked, it says so instead
of reporting "all clear".

## Not yet (future passes)
- A numeric score. This needs server-side lifetime aggregates and connection
  history per automation.
- Spike and zero-result rules: runs don't record item counts yet.
- Duplicate/similar-automation detection.
- Turning findings into Notification Center entries (needs de-duplication, so it
  doesn't nag).
