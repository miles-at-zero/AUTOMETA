import { J } from './db.js';

const DAY = 864e5;

export function analytics(db, businessId, { days = 30, now = Date.now(), advanced = false } = {}) {
  const since = now - days * DAY;
  const count = (type) => db.prepare('SELECT COUNT(*) n FROM events WHERE business_id = ? AND type = ? AND ts >= ?').get(businessId, type, since).n;
  const avg = (type) => db.prepare('SELECT AVG(value) v FROM events WHERE business_id = ? AND type = ? AND ts >= ? AND value IS NOT NULL').get(businessId, type, since).v;

  const conversations = db.prepare(`SELECT COUNT(DISTINCT customer_id) n FROM events WHERE business_id = ? AND type = 'incoming' AND ts >= ?`).get(businessId, since).n;
  const totals = {
    incomingMessages: count('incoming'),
    conversations,
    newCustomers: count('new_customer'),
    automatedReplies: count('auto_reply'),
    faqAnswers: count('faq_answered'),
    leadsCaptured: count('lead_captured'),
    ordersStarted: count('order_started'),
    ordersCompleted: count('order_completed'),
    handoffs: count('handoff'),
    flowRuns: count('flow_started'),
    flowCompleted: count('flow_completed'),
    flowFailed: count('flow_failed'),
    sendFailures: count('send_failed'),
    followupsSent: count('followup_sent'),
    staffReplies: count('staff_reply'),
  };
  const out = {
    days,
    totals,
    automationRate: totals.incomingMessages ? Math.round((totals.automatedReplies + totals.faqAnswers) / Math.max(totals.incomingMessages, 1) * 100) : 0,
    orderConversion: totals.ordersStarted ? Math.round(totals.ordersCompleted / totals.ordersStarted * 100) : null,
    responseTimes: {
      automatedMs: Math.round(avg('auto_reply') || 0),
      staffFirstReplyMs: Math.round(avg('staff_reply') || 0) || null,
    },
    daily: db.prepare(`SELECT CAST((ts - ?) / ? AS INTEGER) d, type, COUNT(*) n FROM events WHERE business_id = ? AND ts >= ? AND type IN ('incoming','auto_reply','order_completed','lead_captured','handoff') GROUP BY d, type`)
      .all(since, DAY, businessId, since)
      .reduce((acc, r) => { (acc[r.d] ||= { day: r.d }); acc[r.d][r.type] = r.n; return acc; }, Array.from({ length: days }, (_, d) => ({ day: d }))),
    topFlows: db.prepare(`SELECT f.id, f.name, COUNT(*) runs,
        SUM(CASE WHEN r.status='completed' THEN 1 ELSE 0 END) completed,
        SUM(CASE WHEN r.status='failed' THEN 1 ELSE 0 END) failed,
        SUM(CASE WHEN r.status='handoff' THEN 1 ELSE 0 END) handoffs
      FROM flow_runs r JOIN flows f ON f.id = r.flow_id WHERE r.business_id = ? AND r.started_at >= ? AND r.is_test = 0
      GROUP BY f.id ORDER BY runs DESC LIMIT 10`).all(businessId, since),
    categories: db.prepare(`SELECT category, COUNT(*) n FROM customers WHERE business_id = ? AND is_test = 0 AND last_seen >= ? AND category != '' GROUP BY category ORDER BY n DESC`).all(businessId, since),
    activeCustomers: db.prepare('SELECT COUNT(*) n FROM customers WHERE business_id = ? AND is_test = 0 AND last_seen >= ?').get(businessId, since).n,
    waitingForStaff: db.prepare(`SELECT COUNT(*) n FROM customers WHERE business_id = ? AND status = 'needs_human' AND is_test = 0`).get(businessId).n,
  };
  if (advanced) {
    out.busiestHours = db.prepare(`SELECT CAST(strftime('%H', ts / 1000, 'unixepoch') AS INTEGER) hourUtc, COUNT(*) n FROM events WHERE business_id = ? AND type = 'incoming' AND ts >= ? GROUP BY hourUtc ORDER BY hourUtc`).all(businessId, since);
    out.recentErrors = db.prepare(`SELECT type, data, ts, flow_id FROM events WHERE business_id = ? AND type IN ('flow_failed','send_failed','followup_skipped') ORDER BY ts DESC LIMIT 20`).all(businessId)
      .map((e) => ({ ...e, data: J.parse(e.data, {}) }));
  }
  return out;
}
