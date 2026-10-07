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

## Not yet (future passes)
- A numeric score. This needs server-side lifetime aggregates and connection
  history per automation.
- Missed-schedule / spike / zero-result anomaly rules (Guardian). These need
  expected-run tracking on the server.
- Health across all automations on Home (one request per automation today, which
  is too chatty; needs a server summary endpoint).
