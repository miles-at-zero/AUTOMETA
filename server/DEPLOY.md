# Deploying Autometa Cloud (server/)

There is no hosted instance. This is the operator checklist.
Nothing here has been deployed by the build, and the Docker image has not been built or run by CI. **EXTERNAL CONFIG REQUIRED.**

What *has* been exercised:
* `npm test` (31 tests).
* A local production-mode run with `node src/index.js`, which showed:
  * startup log;
  * `/health` with `scheduler: "running"`;
  * clean SIGTERM exit;
  * refusal to start without `SECRET_KEY`.

## 1. Requirements
* Node ≥ 22.13 (built-in `node:sqlite` without the `--experimental-sqlite` flag; 22.5–22.12 fail at startup) or Docker (`node:22-alpine`, always a current 22.x). There are no npm dependencies.
* A public **HTTPS** hostname such as `api.example.com`, on Fly.io, Railway, Render, or a VPS behind Caddy/nginx. The Android release build refuses plain-http server addresses.
* A persistent disk for the SQLite database.
* **One instance only.** The scheduler loop and the SQLite file are single-process. Scale vertically.

## 2. Environment (see `.env.example`)
| Var | Required | Notes |
|---|---|---|
| `NODE_ENV` | **yes** = `production` | Enables the hard `SECRET_KEY` check. The Docker image sets it. |
| `SECRET_KEY` | **yes** | 32+ random chars (`openssl rand -hex 32`). Encrypts connection tokens at rest. The server refuses to start in production without it. **Never rotate it without migrating secrets**, or every connection needs reconnecting. |
| `PUBLIC_URL` | **yes** | `https://api.example.com`, with no trailing slash. Used for OAuth redirects (`PUBLIC_URL/oauth/google/callback`) and webhook URLs. The server warns at startup if it is missing. |
| `ADMIN_KEY` | yes | Operator endpoints (`/admin/*`, `/v1/admin/*`). |
| `DATABASE_PATH` | Docker sets `/data/autometa.db` | Its directory must be writable. |
| `PORT` | default 8080 | The server binds `0.0.0.0`. |
| `CORS_ORIGIN` | optional | Allowed browser origin for both API surfaces; default `*`. The Android app doesn't use CORS. Authentication is a bearer token, not cookies, so `*` doesn't expose sessions. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | for Gmail | docs/GMAIL.md. Without them, Gmail shows as "Unavailable: server configuration required" and OAuth start returns 503. |
| `FCM_SERVICE_ACCOUNT_JSON` | for push | docs/NOTIFICATIONS.md. Without it, alerts are stored and every push attempt is logged as `not_configured`. The app falls back to its in-app alerts poll. |
| `META_APP_SECRET`, `WEBHOOK_VERIFY_TOKEN`, `GRAPH_VERSION` | for WhatsApp Business | server/README.md |
| `RESEND_API_KEY`, `MAIL_FROM` | for password-reset email | Without them, resets go through the admin endpoint. The emailed link opens `PUBLIC_URL/reset?token=…`, a script-free form served by this server. |
| `CLOUD_TICK_MS` | optional | Scheduler pass interval; default 5000. |

## 3. Directories, permissions, database
* Keep the database in its own directory (`/data`). SQLite also writes `autometa.db-wal` and `autometa.db-shm` beside it, so the *directory* must be writable, not just the file.
* The Docker image creates `/data`, `chown`s it to the unprivileged `node` user, and runs as `node`. For a bare-metal install, use a dedicated user and run `install -d -o autometa -m 700 /var/lib/autometa`.
* **DB init is automatic.** `openDb()` runs idempotent `CREATE TABLE IF NOT EXISTS` statements on every start. WAL mode, foreign keys and a 5 s busy timeout are enabled. No separate migration step is needed for V1.
* **Backups:** use `sqlite3 /data/autometa.db ".backup '/backup/autometa-$(date +%F).db'"`. This is safe while running. Copying only the `.db` file while the server runs can miss WAL contents. Test a restore once.

## 4. Run (Docker; not tested by CI)
```bash
cd server
docker build -t autometa-server .
docker run -d --name autometa -p 8080:8080 -v autometa:/data --env-file .env --restart unless-stopped autometa-server
```
Or bare metal: `NODE_ENV=production node --disable-warning=ExperimentalWarning src/index.js`, run under systemd with `Restart=always`.

## 4b. Railway (EXTERNAL VERIFICATION REQUIRED: not deployed by CI)

`server/railway.json` configures the Dockerfile build, `/health` healthcheck and a single replica.

1. New Project → Deploy from GitHub repo → this repository.
2. Service → Settings → **Root Directory: `/server`**, so Railway uses `server/Dockerfile` and `server/railway.json`.
3. Service → **Volumes → Add volume, mount path `/data`**. Without it, the SQLite database is wiped on every deploy.
4. Variables:
   * `NODE_ENV=production`
   * `SECRET_KEY` (32+ random characters; **never change it after launch**, because stored tokens are encrypted with it)
   * `ADMIN_KEY`
   * `PUBLIC_URL=https://<your-service>.up.railway.app` (or your custom domain, without a trailing slash)
   * `DATABASE_PATH=/data/autometa.db` (already the image default)
   * **`RAILWAY_RUN_UID=0`**. Railway mounts volumes root-owned and the image runs as the unprivileged `node` user, so without this the server cannot write `/data`. It exits with a clear "Cannot open database" message instead of half-starting.
   * Optional: the Gmail, FCM and mail variables from `.env.example`.
   Do **not** set `PORT`: Railway injects it and the server binds `0.0.0.0:$PORT`.
5. Settings → Networking → Generate Domain. Use that HTTPS URL as `PUBLIC_URL` and as the app's `AUTOMETA_CLOUD_URL`.
6. Keep **one replica**. The scheduler and SQLite are single-process by design.

Shutdown: on redeploy Railway sends SIGTERM. The server stops accepting requests and new scheduler ticks, waits up to 10 s for an in-flight tick, closes SQLite and exits. A run whose slot passed during a short restart still fires if it is within the scheduler's grace window (`MISSED_GRACE_MS`). Older slots are recorded once as `skipped` ("Missed: the server was offline") rather than fired late, and the unique slot key prevents duplicates.

Note: the Dockerfile intentionally has no `VOLUME` instruction, because Railway rejects it. With plain Docker, mount the volume explicitly (`-v autometa-data:/data`).

## 5. Health
`GET /health` is public and returns **booleans and status words only, never secret values**. A test asserts this with every secret configured.
```json
{"ok":true,"time":...,"whatsapp":false,"ai":false,"googlePlay":false,
 "cloud":{"scheduler":"running","gmail":true,"push":false,"publicUrl":true}}
```
`cloud.scheduler` is real:
* `not_started`: no tick yet.
* `running`: a tick within the last 60 s.
* `stale`: the loop is stuck. Restart and check the logs.

Point the uptime monitor at `/health` and alert on `scheduler != "running"`. The Docker `HEALTHCHECK` only checks that the process answers.

## 6. Scheduler, workers, shutdown
* The scheduler and workers live in the same process. A tick every `CLOUD_TICK_MS` runs due automations and queued jobs (delays, retries, Gmail polling at about 60 s). The run lock is a per-slot idempotency key, so a restart doesn't double-run a slot.
* SIGTERM/SIGINT stops accepting connections and exits after in-flight requests finish, with a hard exit after 5 s. A tick interrupted mid-run is not resumed. That run stays as the stored execution, and the next slot runs normally.

## 7. Sessions & auth
* Session tokens are random. Only their SHA-256 hash is stored (`user_sessions`), so a database leak doesn't reveal usable tokens. Sessions last 30 days, and `last_seen` is updated hourly.
* A password change signs out the other sessions. Sign-out deletes the session and the device's push token.

## 8. Logging
* stdout: one startup line with configuration booleans, plus "Shutting down".
* stderr: only 5xx errors (prefixed `[cloud]`), plus `cloud tick` and `jobs` failures. Request bodies, tokens and secrets are not logged.
* Collect stdout/stderr with the platform's log driver.

## 9. Point the app at it
* Users type the address under Settings → Cloud account. It must be `https://` in release builds. **or**
* Build with a preset: `flutter build apk --flavor standard --dart-define=AUTOMETA_CLOUD_URL=https://api.example.com`.
* There is **no silent fallback**. Plain builds have no default server, and nothing falls back to localhost.

## 10. Production checklist
- [ ] HTTPS only; TLS terminated at the proxy, which forwards `X-Forwarded-For`.
- [ ] `NODE_ENV=production`; `SECRET_KEY` and `ADMIN_KEY` held in a secret manager.
- [ ] `PUBLIC_URL` matches the Google OAuth redirect URI exactly.
- [ ] Persistent volume at `/data`; daily `.backup`; one restore tested.
- [ ] One replica.
- [ ] Uptime monitor on `/health`, alerting on `scheduler`.
- [ ] Logs collected.
- [ ] Optional: Gmail OAuth. Testing mode first, then Google verification before a public launch (docs/GMAIL.md).
- [ ] Optional: the FCM service account, plus the app's Firebase config (`google-services.json`, never in the repo).

## Known limits
* SQLite with a single process. Moving to Postgres is not part of V1.
* Gmail is polled about every 60 s, not pushed.
* Password-reset email needs Resend.
