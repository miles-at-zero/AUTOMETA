# Testing

## Automated (`flutter test`)
| File | Covers |
|---|---|
| `engine_test.dart` | runs, duplicate SKIP, pause/resume, retries (exhaust / recover / non-retriable), dry run, IF/ELSE, variables, approval park+resume, deferred WAIT, invalid workflow, missing integration |
| `schedule_test.dart` | daily/weekday/weekly/monthly/interval, Dad 07/20/22, Sunday 18:00, DST, bad zone, one-shot, next-run selection |
| `primitives_test.dart` | variables, all condition operators incl. dates, idempotency keys, retry policy |
| `ai_test.dart` | NL parser (the in-app examples), local templates, provider errors, key never in logs |
| `whatsapp_test.dart` | wa.me link, personal never sends, hand-off ≠ delivery, Cloud API payload/endpoint, templates, Meta errors, config/token states |
| `database_test.dart` | CRUD/edit, SQL duplicate guard, engine+SQLite, contacts/settings/variables, personal approval flow, scheduler arm/disarm |
| `workflow_model_test.dart` | JSON round-trip of every block, spec §36 shape, validator, acceptance templates |
| `notifications_test.dart` | preferences, alarm ids, unavailable platform |

CI (`.github/workflows/flutter.yml`) runs analyze, test and builds a debug APK artifact.

## Real-device checklist (Android 10–15)
1. Onboarding → Start from a template → Dad reminders → Personal WhatsApp, enter a real number → Create drafts. Open Morning Dad, set its time to 2 min from now and activate it.
2. Lock the phone. At the time: approval notification appears (not a “sent” notification).
3. Approve → WhatsApp opens with “Good morning Dad” prefilled. Activity shows *Handed to WhatsApp — you tap Send*.
4. Trigger the same slot again (Run now is ad-hoc; to test duplicates, reboot during the minute) → Activity shows SKIPPED “Already executed”.
5. Reboot → alarms restored (Reliability screen shows armed count).
6. Settings → Pause all → nothing fires; Resume → re-armed.
7. Enable battery optimisation → Reliability warns; exempt → warning clears.
8. Create “Every Sunday at 18:00 generate an AI summary and show me a notification” in Create → review → create → Test run shows SIMULATION.
9. Business: enter a test Phone Number ID + token → Connected with API messaging; send to a test recipient; wrong token → Connection error.
10. Airplane mode + HTTP block → retries then FAILED with reason; Retry works.
