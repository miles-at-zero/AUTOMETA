# Control Room, floating dock and Notification Center

The three surfaces that replaced the old Home screen and bottom bar.

## Control Room (tab 1 of 4)

The landing dashboard. It answers "is everything alright, and if not, what?" in
one glance:

| Section | What it shows |
| --- | --- |
| Header | Brand glyph, greeting, notification bell with the unread count |
| Hero | Engine state: `OPERATIONAL` / `PAUSED` / `ATTENTION` (+ critical count) |
| Metrics | Active, Needs you, Ran today (`ran/scheduled`), Failures |
| Approvals | Anything waiting on the user |
| Guardian | Live findings, capped at 3 (same widget the old Home used) |
| Next automation | What fires next and when |
| Today | Today's schedule slots and their outcome |
| Recent | Last five runs |
| Connections | One pill per integration, plus Cloud sign-in state |
| Actions | New automation, Business mode |

### State rules

- `PAUSED` wins over everything: the user paused the engine.
- `ATTENTION` with a count when Guardian has critical findings.
- `ATTENTION` when Guardian has any findings.
- `OPERATIONAL` otherwise.

The Guardian section only renders when at least one automation is active. With
nothing running, "nothing needs attention" would be a lie — as would "all
clear", which is why the empty case says **"Not enough history yet"** when
Guardian has no finished run to judge.

`ControlRoomView` is pure: it takes view models and callbacks, so it is driven
directly from `test/control_room_test.dart` without the service graph.

## Floating capsule dock

One capsule floating above the content instead of a full-bleed bottom bar. The
active destination gets a tinted pill that animates onto its icon; the bell at
the end of the same capsule opens the Notification Center and carries the
unread count (capped at `9+`).

Built for the edges the product actually ships to:

- every destination gets an equal share of the width
- labels scale down instead of wrapping
- text scaling is capped **inside the dock only** — content screens still honour
  the user's system setting in full
- each slot is ≥ 48 dp tall and announced as a selected button

## Guardian Notification Center

Opened from the dock bell or the Control Room bell.

### The de-duplication rule

Guardian re-derives its findings on every pass. Without a stable identity the
same failing automation would drop a fresh "unread" row into the inbox on every
refresh, which is exactly the "nagging" the audit flagged as the blocker for
this feature.

Identity is `kind | mode | subject`:

- **one row per problem**, however many times Guardian reports it
- **first-seen time survives refreshes**, so "2 h ago" doesn't reset
- **read stays read** across refreshes
- a row only returns as unread when Guardian's **wording changes** — that is new
  information, not a nag
- **dismissal sticks** until the wording changes or the problem resolves

### What is stored

Only what the user owns: which keys they read, and the signature of anything
they dismissed. Findings are always re-derived from a live Guardian pass, so the
inbox can never keep warning about something that is already fixed.

Encoding uses `\x1E` (record) and `\x1F` (field) separators, which the on-screen
keyboard cannot produce. Workflow names and error text are sanitised before
storing, so a stray separator in an automation name cannot corrupt the record.
NUL is deliberately **not** sanitised: it is the separator inside
`NotificationEntry.signature`, and sanitising it would store a signature that
could never match the live one, silently breaking dismissal.

## One Guardian pass, shared

`GuardianInboxController` runs a single pass at the shell and shares it through
`GuardianScope`, so the dock badge, the dashboard panel and the inbox cannot
disagree, and opening a screen fires no extra Cloud round-trip.

`loadGuardianSnapshot` and `openGuardianTarget` are extracted from the old Home
panel and reused by all three, so tapping a row in the inbox does exactly what
tapping the same finding on the dashboard does — including the honest "this
automation isn't on this phone yet" message instead of a dead tap.

The first pass is deliberately deferred until `AppState` has finished its own
initial load: competing for the SQLite lock during startup makes sqflite's
busy-wait arm a Timer that a widget test can then report as pending.
