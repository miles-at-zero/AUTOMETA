import { createApp } from './app.js';
import { openDb } from './db.js';

const port = Number(process.env.PORT || 8080);
const app = createApp({ db: openDb(process.env.DATABASE_PATH || 'autometa.db') });
app.server().listen(port, '0.0.0.0', () => console.log(`AUTOMETA server on :${port}`));

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
