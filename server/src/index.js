import { createApp } from './app.js';
import { openDb } from './db.js';

const port = Number(process.env.PORT || 8080);
const dbPath = process.env.DATABASE_PATH || 'autometa.db';
let db;
try {
  db = openDb(dbPath);
} catch (e) {
  // Most common production cause: the volume is mounted root-owned while the
  // image runs as the unprivileged `node` user (e.g. Railway volumes).
  console.error(`Cannot open database at ${dbPath}: ${e.message}`);
  console.error('Check that a volume is mounted there and is writable. On Railway set RAILWAY_RUN_UID=0 (see server/DEPLOY.md).');
  process.exit(1);
}
const app = createApp({ db });
const server = app.server().listen(port, '0.0.0.0', () => {
  // Configuration summary: booleans only, never secret values.
  const h = app.cloud.health();
  console.log(`AUTOMETA server on :${port} env=${process.env.NODE_ENV || 'development'} publicUrl=${h.publicUrl} gmail=${h.gmail} push=${h.push} whatsappWebhook=${!!process.env.META_APP_SECRET}`);
  if (process.env.NODE_ENV === 'production' && !process.env.PUBLIC_URL) console.warn('PUBLIC_URL is not set: OAuth redirects and webhook URLs will not work.');
});

// Delays and follow-ups. A plain interval is fine on a server process.
setInterval(() => app.engine.processDueJobs().catch((e) => console.error('jobs', e)), 30_000).unref();
// Cloud automations: scheduler + job queue. The server owns execution;
// phones are only clients.
let ticking = false;
let stopping = false;
setInterval(async () => {
  if (ticking || stopping) return;
  ticking = true;
  try { await app.cloud.engine.tick(); } catch (e) { console.error('cloud tick', e); } finally { ticking = false; }
}, Number(process.env.CLOUD_TICK_MS || 5000)).unref();

// Graceful shutdown: stop accepting requests and new ticks, let an in-flight
// tick finish (bounded), then close SQLite cleanly so the WAL is checkpointed.
async function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`Shutting down (${signal})`);
  const hardExit = setTimeout(() => process.exit(0), 15_000);
  hardExit.unref();
  await new Promise((resolve) => server.close(() => resolve()));
  const deadline = Date.now() + 10_000;
  while (ticking && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
  try { db.close(); } catch (e) { console.error('db close', e); }
  process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
