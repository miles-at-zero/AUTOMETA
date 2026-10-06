# Writing an Autometa integration

Cloud integrations live in `server/src/cloud/integrations/`. Each module exports one object, and `index.js` registers it.
Only list triggers and actions that are really implemented and that the provider's official API allows.

- `auth`: `{ type: 'token' | 'oauth' | 'none', fields: [...] }`
- `connect(fields, ctx)` → `{ identity, secret, scopes, meta }`: verifies the credentials and throws `ActionError` when they're wrong.
- `test(conn, ctx)` → `{ identity }`: a health check.
- `triggers` / `actions`: `{ key: { label, description, config: [fields], idempotent, run(conn, cfg, ctx) } }`
  - `run` returns `{ summary, output, externalId }`.

Rules:
- Use `callApi(ctx.fetch, …)` so tests can inject a fake fetch. Never log secrets.
- Throw `ActionError(message, { kind, fix, retryAfterMs })`, where kind is one of:
  - `auth`: pauses the automation and asks the user to reconnect;
  - `config`: the user must change the step;
  - `rate_limit` / `transient`: retried per policy;
  - `ambiguous`: the request may have been delivered, so it's retried only when the action is `idempotent`;
  - `permanent`: not retried.
- `fix` is one plain sentence telling the user what to do.
- Test runs only call `run` after the user confirms a live test. Otherwise the step is recorded as "simulated".
- Secrets are stored AES-GCM encrypted with `SECRET_KEY` and are only decrypted inside the engine.
- Add tests with a fake `fetchImpl` (see `server/test/cloud.test.js`).

## Cloud API (summary)
- Auth: `/v1/auth/{signup,login,logout,logout-all,forgot,reset}`
- Account: `/v1/me` (`PATCH`, `DELETE`, `/password`, `/sessions`, `/export`)
- `/v1/integrations`, `/v1/connections[/:id/{test,reconnect,chats}]`
- `/v1/automations[/:id/{activate,pause,archive,duplicate,run,test,validate,steps/:sid/test}]`
- `/v1/executions[/:id/{retry,cancel}]`
- `/v1/webhooks[/:id/{secret,rotate-url,test}]`; public intake is `POST /hooks/:publicId` (header `X-Autometa-Secret`)
- `/v1/templates[/:id/install]`, `/v1/dashboard`, `/v1/usage`, `/v1/notifications`, `/v1/search`, `/v1/billing`
- Admin (header `X-Admin-Key`): `/v1/admin/{overview,users,failed-jobs,executions,abuse}`
