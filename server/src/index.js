import { createApp } from './app.js';
import { openDb } from './db.js';

const port = Number(process.env.PORT || 8080);
const app = createApp({ db: openDb(process.env.DATABASE_PATH || 'autometa.db') });
const server = app.server().listen(port, '0.0.0.0', () => {
  // Configuration summary: booleans only, never secret values.
  const h = app.cloud.health();
  console.log(`AUTOMETA server on :${port} env=${process.env.NODE_ENV || 'development'} publicUrl=${h.publicUrl} gmail=${h.gmail} push=${h.push} whatsappWebhook=${!!process.env.META_APP_SECRET}`);
  if (process.env.NODE_ENV === 'production' && !process.env.PUBLIC_URL) console.warn('PUBLIC_URL is not set: OAuth redirects and webhook URLs will not work.');
});
const shutdown = () => { console.log('Shutting down'); server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 5000).unref(); };
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// Delays and follow-ups. A plain interval is fine on a server process.
setInterval(() => app.engine.processDueJobs().catch((e) => console.error('jobs', e)), 30_000).unref();
// Cloud automations: scheduler + job queue. The server owns execution;
// phones are only clients.
let ticking = false;
setInterval(async () => {
  if (ticking) return;
  ticking = true;
  try { await app.cloud.engine.tick(); } catch (e) { console.error('cloud tick', e); } finally { ticking = false; }
}, Number(process.env.CLOUD_TICK_MS || 5000)).unref();
