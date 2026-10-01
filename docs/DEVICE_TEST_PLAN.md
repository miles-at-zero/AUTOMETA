# Device test plan (run on your Infinix)

## What's already been tested, and how
Automated tests run on every push on GitHub's build machines: `flutter analyze`, the unit tests, and `test/e2e_test.dart`. The e2e test boots the real AppServices with real SQLite, the real engine, scheduler and execution service. Only AlarmManager, the WhatsApp app and the network are faked. It covers:

| Scenario | Result |
|---|---|
| Morning/Evening/Night Dad arm at 07:00/20:00/22:00 Africa/Lagos | ✅ automated |
| Each alarm sends the right text to Dad once, then re-arms for the next day | ✅ automated |
| Same alarm delivered 3× → one message | ✅ automated |
| Alarm delivered 5 h late (reboot/Doze) → Skipped, not sent | ✅ automated |
| Alarm 20 min late → still runs | ✅ automated |
| Pause all from a fresh process cancels every alarm; maintenance can't re-arm; stray alarm skips | ✅ automated (found and fixed 2 bugs) |
| Personal without auto-send → "message ready" card → wa.me link with the text → never "sent" | ✅ automated |
| Reject → nothing sent | ✅ automated |
| Phone locked → clear failure; retry later succeeds | ✅ automated |
| Dry run sends nothing and doesn't consume the slot | ✅ automated |
| Workflows survive restart | ✅ automated |
| Per-automation Business step hits `/{phone-id}/messages`; default stays Personal | ✅ automated (fake Graph API) |
| New weekly Sunday 18:00 automation, no code changes | ✅ automated |

## What still needs a real phone
Use **Settings → Background reliability**. Each test sets a real alarm and notifies you how late it fired. Results are kept in the delivery log.

| # | Situation | How | Pass = |
|---|---|---|---|
| 1 | App closed | "In 2 min", swipe AUTOMETA out of recents | notification ≤ 1 min late |
| 2 | Screen locked | "In 2 min", lock phone | ≤ 1 min late |
| 3 | Idle overnight | "In 8 h" at bedtime | ≤ a few min late |
| 4 | Battery optimisation ON | repeat 1 with optimisation on | note the delay |
| 5 | Battery optimisation OFF | repeat 1 after "Exempt" | ≤ 1 min late |
| 6 | Restart | "In 15 min", reboot | fires after boot |
| 7 | Auto-send | Make "Test" automation to yourself 2 min ahead, phone unlocked | message in WhatsApp; run says "Sent from your phone" |
| 8 | Auto-send while locked (with PIN) | same, phone locked | run fails "Phone is locked", nothing sent |
| 9 | Personal hand-off | auto-send off | card + notification "message ready"; tap → chat prefilled |
| 10 | Business | complete wizard with Meta test number, send to a tester number | message arrives; run shows "Delivered to WhatsApp" |

Infinix (XOS): also turn on Phone Master → Auto-start for AUTOMETA, set battery to "No restrictions", and lock the app in recents. The reliability screen links to these settings. Never force-stop the app.
