# Device test plan

Status: **REAL DEVICE TEST REQUIRED.** None of the sections below has been run on a phone.
Green CI does not prove Android background behaviour, Firebase push, Gmail, WhatsApp Business or a deployment.

Write results in the *Result* column as ✅, ❌ (with a note) or N/A. Record the phone model, Android version, OEM skin (e.g. Infinix XOS) and the APK version (Settings footer, e.g. `0.9.0`).

## 0. What CI already covers (no phone)
On every push, CI runs `flutter analyze`, the unit tests, `test/e2e_test.dart` and `server` `npm test`.
* The e2e test uses the real AppServices, SQLite, engine, scheduler and execution service. AlarmManager, the WhatsApp app and the network are faked.
* It covers:
  * the Dad schedules (07:00/20:00/22:00 Lagos);
  * once-per-slot delivery and duplicate alarms;
  * late-alarm skip;
  * pause-all;
  * the personal prepare hand-off; personal "send" refused and failing visibly;
  * Business outage and retry;
  * dry run, persistence, and Cloud-never-runs-locally;
  * the weekly Sunday 18:00 automation;
  * the canonical `{{weekday}}` variable;
  * the push client states and cold-start routing (fake transport).

## 1. Install & update
| # | Step | Pass = | Result |
|---|---|---|---|
| 1.1 | Install `autometa.apk` from the release page | Installs. Icon correct. The Settings footer shows the version | |
| 1.2 | Install a newer build over it | Installs as an update. Automations and history kept | |
| 1.3 | First launch | Welcome → How Autometa works → Choose your first step (3 screens, Skip setup available). No phone number or permission asked. The notification prompt appears on Android 13+ the first time you turn an automation on | |
| 1.4 | Small phone + system font at largest | Bottom tab labels fit, nothing overflows on Home/Builder/Settings | |

## 2. On-device schedules (Settings → Background reliability)
| # | Situation | How | Pass = | Result |
|---|---|---|---|---|
| 2.1 | App closed | "In 2 min", swipe from recents | ≤ 1 min late | |
| 2.2 | Screen locked | "In 2 min", lock | ≤ 1 min late | |
| 2.3 | Idle overnight (Doze) | "In 8 h" at bedtime | ≤ a few min late | |
| 2.4 | Battery optimisation ON | repeat 2.1 | note the delay | |
| 2.5 | Battery optimisation OFF | "Exempt", repeat 2.1 | ≤ 1 min late | |
| 2.6 | Reboot | "In 15 min", reboot | fires after boot | |
| 2.7 | Exact alarms revoked (Android 14) | Revoke in system settings | App shows the warning and a fix link; nothing pretends to be scheduled | |
| 2.8 | Timezone change | Change the phone timezone | Next-run times are recomputed for the automation's timezone | |
| 2.9 | OEM (Infinix XOS) | Phone Master → Auto-start ON, battery "No restrictions", lock in recents | 2.1–2.3 pass | |

## 3. Acceptance automations (no code changes)
| # | Step | Pass = | Result |
|---|---|---|---|
| 3.1 | Templates → Morning/Evening/Night Dad, save Dad's number in Contacts | Three automations at 07:00/20:00/22:00 | |
| 3.2 | At each time | "Message ready" notification. Tap → WhatsApp opens with the text prefilled. **You** tap Send. History says "Handed to WhatsApp", never "Sent" | |
| 3.3 | Create "Every Sunday 18:00 → AI summary → notification" | Runs Sunday 18:00. The notification has the summary, or a clear AI-not-configured failure | |
| 3.4 | Condition `{{weekday}} equals Sunday` in the builder | Runs only on Sunday (test with dry run on another day → skipped) | |

## 4. WhatsApp
| # | Step | Pass = | Result |
|---|---|---|---|
| 4.1 | Personal account: "Prepare message" | Card + notification; chat opens prefilled; nothing is sent without your tap | |
| 4.2 | Personal account set to "send" | Builder/validator refuses it, or the run fails with "Personal WhatsApp can't send automatically". Never sent, never silently prepared | |
| 4.3 | WhatsApp Business (Meta test number) → send to a tester | Message arrives. Run shows "Delivered to WhatsApp" | |
| 4.4 | Business token revoked | Clear failure, nothing marked delivered | |

## 5. Cloud account & journey (needs a deployed server; DEPLOYMENT REQUIRED)
| # | Step | Pass = | Result |
|---|---|---|---|
| 5.1 | Settings → Cloud account, enter `http://…` in a release build | Refused: "Use an https:// server address" | |
| 5.2 | Sign up / sign in / forgot password | Works. Wrong password gives a clear error | |
| 5.3 | Connect Telegram; build schedule → Telegram; **Test** | Test run shows "Simulated", nothing sent | |
| 5.4 | Activate; wait for the slot with the app closed and the phone in airplane mode | The message arrives on Telegram. The run is in Activity (☁️) once back online | |
| 5.5 | Revoke the bot token at @BotFather; wait for the next run | Run failed → automation paused → Reconnect prompt | |
| 5.6 | Reconnect with the new token | Connection healthy. The next run succeeds | |
| 5.7 | Move an On-device notification automation to Cloud | "Cloud" badge; no local alarm left | |
| 5.8 | Sign out | Cloud screens ask to sign in. On-device automations keep working | |

## 6. Gmail (needs Google OAuth on the server; REAL PROVIDER TEST REQUIRED)
| # | Step | Pass = | Result |
|---|---|---|---|
| 6.1 | Server without Google credentials | Gmail shows "Unavailable: server configuration required". Connect is disabled | |
| 6.2 | Connect Gmail (test user) | Google consent → "Gmail connected" page → back in the app shows the address | |
| 6.3 | New-email trigger + condition (`email.subject contains invoice`) → Telegram | Matching email → Telegram. Non-matching → skipped. Old mail isn't replayed | |
| 6.4 | Send-email action | Email arrives. History shows success | |
| 6.5 | Revoke at myaccount.google.com → Security → Third-party access | Paused + Reconnect. Reconnect → healthy | |
| 6.6 | After 7 days in Testing mode | Token expiry → Reconnect prompt (expected until verification) | |

## 7. Push & alerts (needs `google-services.json` in the build AND `FCM_SERVICE_ACCOUNT_JSON` on the server)
| # | Step | Pass = | Result |
|---|---|---|---|
| 7.1 | Build **without** Firebase config, sign in | Cloud account → Phone alerts = "Not configured in this build". No crash | |
| 7.2 | Build with config, server without FCM | "Server push not configured" | |
| 7.3 | Both configured | "Push alerts on". The server `devices` table has the token | |
| 7.4 | Deny the notification permission | "Notifications blocked" | |
| 7.5 | **Foreground**: make a Cloud automation fail | One notification. Tap → that run's detail | |
| 7.6 | **Background** (home screen) | System notification on "Cloud alerts". Tap → run detail | |
| 7.7 | **Terminated** (swipe from recents, or reboot and don't open the app) | Notification arrives. Tap → the app cold-starts **directly on the run detail** (not Home) | |
| 7.8 | Reconnect alert (revoke a token) while terminated | Tap → Cloud account / connections screen with Reconnect | |
| 7.9 | Turn off "Failures, pauses and reconnect requests" | The next failure produces no push (the alert is still listed in the app) | |
| 7.10 | Sign out, make a failure | No push to this phone | |
| 7.11 | Push not configured (7.1): failure while closed, then open the app | Polling fallback shows the alert on open; tap → run detail | |
| 7.12 | Ordinary success | Never pushes | |

## 8. Offline & errors
| # | Step | Pass = | Result |
|---|---|---|---|
| 8.1 | Open the app in airplane mode while signed in | Cached Cloud state, "Offline" note, no sign-out | |
| 8.2 | Server down | Clear "Can't reach Autometa Cloud" messages; on-device features unaffected | |

## 9. Account, privacy & legal
| # | Step | Pass = | Result |
|---|---|---|---|
| 9.1 | Settings → Legal & privacy | All documents open, each marked "prepared for legal review" | |
| 9.2 | Export my data | A file is produced with the account's automations/history and no secrets | |
| 9.3 | Delete account (test account) | Asks for confirmation. Afterwards sign-in fails and Cloud automations stop | |

## 10. After the run
Copy failures into GitHub issues, including the phone, Android version, APK version, timestamps and the delivery log (Settings → Background reliability → Share).
