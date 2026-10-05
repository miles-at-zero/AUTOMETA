# Deploying Autometa Cloud (server/)

There's no hosted instance. Everything below is a checklist for the operator.
Nothing here has been deployed by the build. **EXTERNAL CONFIG REQUIRED.**

## 1. Requirements
* Node ≥ 22.5 (built-in SQLite) or Docker. There are no npm dependencies.
* A public **HTTPS** hostname, e.g. `api.example.com` (Fly.io, Railway, Render, or a VPS behind Caddy/nginx).
* A persistent disk for the SQLite database (`/data`).
* Run **one instance**: the scheduler and the SQLite file are single-process. Scale vertically.

## 2. Environment (see `.env.example`)
| Var | Required | Notes |
|---|---|---|
| `SECRET_KEY` | **yes** | 32+ random chars (`openssl rand -hex 32`). Encrypts connection tokens. The server refuses to start in production without it. **Never rotate it without migrating secrets**, or every connection needs reconnecting. |
| `PUBLIC_URL` | **yes** | `https://api.example.com`, no trailing slash. Used for OAuth redirects and webhook URLs. |
| `ADMIN_KEY` | yes | Operator endpoints (`/admin/*`, `/v1/admin/*`). |
| `DATABASE_PATH` | Docker sets `/data/autometa.db` | Back up this file (with `-wal`). |
| `CORS_ORIGIN` | optional | Browser origins only; the Android app isn't affected. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | for Gmail | docs/GMAIL.md |
| `FCM_SERVICE_ACCOUNT_JSON` | for push | docs/NOTIFICATIONS.md |
| `META_APP_SECRET`, `WEBHOOK_VERIFY_TOKEN` | for WhatsApp Business mode | server/README.md |
| `RESEND_API_KEY`, `MAIL_FROM` | for password reset email | Without them, resets go through admin. |
| `CLOUD_TICK_MS` | optional | Scheduler pass interval, default 5000. |

## 3. Run
```bash
cd server
docker build -t autometa-server .
docker run -d --name autometa -p 8080:8080 -v autometa:/data --env-file .env --restart unless-stopped autometa-server
```
The image runs as the unprivileged `node` user. `/data` is created and owned by
that user, and a `HEALTHCHECK` polls `/health`. SIGTERM shuts down gracefully.

## 4. Verify
```bash
curl https://api.example.com/health
# {"ok":true,...,"cloud":{"scheduler":true,"gmail":true|false,"push":true|false,"publicUrl":true}}
```
The startup log prints the same booleans, never secret values.

## 5. Point the app at it
* Users can type the address on Settings → Cloud account, **or**
* build with a preset: `flutter build apk --flavor standard --dart-define=AUTOMETA_CLOUD_URL=https://api.example.com`
  (use a different value for dev and prod builds).

## 6. Production checklist
- [ ] HTTPS only (terminate TLS at the proxy). Forward `X-Forwarded-For`.
- [ ] `SECRET_KEY` and `ADMIN_KEY` set and stored in a secret manager.
- [ ] `PUBLIC_URL` matches the Google OAuth redirect URI exactly.
- [ ] Persistent volume mounted at `/data`, plus daily backups of `autometa.db*`.
- [ ] One replica only.
- [ ] Uptime monitor on `/health`.
- [ ] Logs collected (stdout/stderr). Errors are prefixed `[cloud]`, `cloud tick` or `jobs`.
- [ ] Optional: Gmail OAuth (Testing mode → verification before public launch).
- [ ] Optional: FCM service account, plus the app's Firebase config (not in the repo).

## Known limits
* SQLite with a single process. A Postgres move is planned but not part of V1.
* Gmail is polled about every 60 s, not pushed.
* Password-reset email uses Resend (`RESEND_API_KEY`, `MAIL_FROM`). Without them, reset links can only be issued by the operator through the admin endpoint.
