// AUTOMETA GUARDIAN v1.
//
// Read-only and deterministic. Derives per-automation health and the findings
// worth a user's attention from authoritative stored data:
//   automations, executions, connections, schedule_slots (expected-run tracking).
// Findings are computed on request, never persisted, so a fixed problem can't
// leave a stale finding behind. No AI, no scores, no invented history.
//
// Every finding answers WHAT happened → WHY Guardian cares → EVIDENCE → WHAT
// to do, and carries a `certainty`:
//   'certain' – a recorded fact (runs failed, connection marked broken, a
//               tracked slot has no run).
//   'unusual' – a deterministic heuristic that *looks* wrong but may be fine.
//               UIs must word these as "looks …", never as fact.
//
// Health rules mirror the app (docs/AUTOMATION_HEALTH.md): one health system,
// Guardian interprets it.

const DAY = 864e5;
export const GUARDIAN_RULES = Object.freeze({
  window: 7 * DAY,          // "recent" failures and missed-slot look-back
  criticalStreak: 3,        // consecutive failed runs → repeated failures
  overdueGrace: 15 * 60e3,  // current slot this late and still unprocessed → looks overdue
  slotSettle: 5 * 60e3,     // consumed slot younger than this may still be starting
  inactiveMinRuns: 5,       // need this much history before judging inactivity
  inactiveFactor: 3,        // silent for > factor × its own median gap …
  inactiveMinGap: DAY,      // … and at least a day
  sample: 50,               // recent runs examined per automation
});

// Spec order: critical failures, connections, missed schedules, other failures, inactivity.
const RANK = {
  paused_after_failures: 0, repeated_failures: 0, connection_attention: 1,
  missed_schedule: 2, schedule_overdue: 2, recent_failures: 3, looks_inactive: 4,
};
const FAILED = new Set(['failed', 'partial']);
const MISSED_PREFIX = 'Missed:'; // CloudEngine.tick's explicit "server offline" skip
const parse = (s, d) => { try { return JSON.parse(s); } catch { return d; } };

/** Health from newest-first finished, non-test runs. Pure; exported for tests. */
export function healthOf({ status, runs, now, rules = GUARDIAN_RULES }) {
  if (status === 'archived' || status === 'paused' || status === 'draft' || status === 'ready') {
    return { state: 'inactive', reasons: ['This automation is not active.'] };
  }
  if (status === 'error') {
    return { state: 'critical', reasons: ['Autometa paused this automation after repeated failures.'] };
  }
  const judged = runs.filter((r) => r.status !== 'skipped');
  if (!judged.length) {
    return { state: 'unknown', reasons: [runs.length ? 'Only skipped runs so far, so there is nothing to judge yet.' : 'No runs yet. Health appears after the first real run.'] };
  }
  let streak = 0;
  for (const r of judged) { if (!FAILED.has(r.status)) break; streak++; }
  const lastErr = judged.find((r) => FAILED.has(r.status))?.error || null;
  if (streak >= rules.criticalStreak) {
    return { state: 'critical', reasons: [`The last ${streak} runs failed.`, ...(lastErr ? [`Latest reason: ${lastErr}`] : [])] };
  }
  const recent = judged.filter((r) => FAILED.has(r.status) && now - r.started_at <= rules.window).length;
  if (streak > 0 || recent > 0) {
    return {
      state: 'attention',
      reasons: [
        ...(streak > 0 ? ['The latest run failed.'] : []),
        ...(recent > 0 ? [`${recent} failed ${recent === 1 ? 'run' : 'runs'} in the last 7 days.`] : []),
        ...(lastErr ? [`Latest reason: ${lastErr}`] : []),
      ],
    };
  }
  return { state: 'healthy', reasons: ['No failures in the last 7 days. The latest run succeeded.'] };
}

/**
 * Outcome of one tracked slot. Pure; exported for tests.
 * `execution` = the run row with scheduled_for = slot, or null.
 *   ran      – success
 *   failed   – failed / partial (a failure, NOT a missed run)
 *   skipped  – skipped on purpose (condition, limit, duplicate…)
 *   missed   – the engine recorded it as missed (server offline at the time)
 *   never    – consumed by the scheduler but no run exists at all
 *   pending  – consumed too recently to judge, or still running
 */
export function slotOutcome({ consumedAt, execution, now, rules = GUARDIAN_RULES }) {
  if (!execution) return now - consumedAt < rules.slotSettle ? 'pending' : 'never';
  if (execution.status === 'running') return 'pending';
  if (execution.status === 'success') return 'ran';
  if (FAILED.has(execution.status)) return 'failed';
  if (execution.status === 'skipped' && String(execution.error || '').startsWith(MISSED_PREFIX)) return 'missed';
  if (execution.status === 'skipped') return 'skipped';
  return 'pending'; // cancelled / unknown: not evidence of anything
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function humanGap(ms) {
  if (ms >= 2 * DAY) return `${Math.round(ms / DAY)} days`;
  if (ms >= 2 * 3600e3) return `${Math.round(ms / 3600e3)} hours`;
  return `${Math.max(1, Math.round(ms / 60e3))} minutes`;
}

/** Guardian report for one workspace. */
export function guardianReport(db, workspaceId, now, rules = GUARDIAN_RULES) {
  const autos = db.prepare(`SELECT * FROM automations WHERE workspace_id = ? AND status != 'archived' ORDER BY name`).all(workspaceId);
  const conns = db.prepare('SELECT id, integration, label, identity, status, last_error, last_ok_at FROM connections WHERE workspace_id = ?').all(workspaceId);
  const runsStmt = db.prepare(`SELECT status, started_at, error FROM executions
    WHERE automation_id = ? AND is_test = 0 AND status NOT IN ('running','cancelled')
    ORDER BY started_at DESC LIMIT ?`);
  const totalsStmt = db.prepare(`SELECT COUNT(*) runs, SUM(status = 'success') ok, SUM(status IN ('failed','partial')) bad,
    SUM(status = 'skipped') skipped, MIN(started_at) first FROM executions
    WHERE automation_id = ? AND is_test = 0 AND status NOT IN ('running','cancelled')`);
  const slotsStmt = db.prepare(`SELECT s.slot, s.consumed_at, e.id exec_id, e.status, e.error FROM schedule_slots s
    LEFT JOIN executions e ON e.automation_id = s.automation_id AND e.scheduled_for = s.slot AND e.is_test = 0
    WHERE s.automation_id = ? AND s.slot >= ? ORDER BY s.slot DESC`);

  const findings = [];
  const add = (f) => findings.push({ id: `${f.kind}:${f.automationId || f.connectionId}`, detectedAt: now, ...f });
  const usesConn = (a, c) => a.steps.includes(c.id) || a.trigger.includes(c.id);

  const automations = autos.map((a) => {
    const runs = runsStmt.all(a.id, rules.sample);
    const tot = totalsStmt.get(a.id);
    const health = healthOf({ status: a.status, runs, now, rules });
    const lastRun = runs[0]?.started_at ?? null;
    const lastFail = runs.find((r) => FAILED.has(r.status)) || null;
    const trigger = parse(a.trigger, {});
    const ref = { automationId: a.id, automationName: a.name };
    const view = { type: 'open_automation', id: a.id, label: 'View automation' };

    // A. Repeated failures (and the engine's own pause after failures).
    if (a.status === 'error') {
      add({ kind: 'paused_after_failures', severity: 'critical', certainty: 'certain', ...ref,
        title: 'Paused after repeated failures',
        why: 'Autometa stopped running it, so nothing it does is happening until it is fixed and turned back on.',
        body: a.status_reason || 'It kept failing, so Autometa paused it.',
        evidence: { consecutiveFailures: a.consecutive_failures, reason: a.status_reason ?? null },
        action: view });
    } else if (health.state === 'critical') {
      add({ kind: 'repeated_failures', severity: 'critical', certainty: 'certain', ...ref,
        title: `Failed ${health.reasons[0].match(/\d+/)[0]} times in a row`,
        why: 'Repeated failures usually mean something changed, such as a connection, a recipient or a website, and it will keep failing until it is fixed.',
        body: lastFail?.error ? `Last error: ${lastFail.error}` : 'Open the latest run to see what went wrong.',
        evidence: { consecutiveFailures: Number(health.reasons[0].match(/\d+/)[0]), lastFailureAt: lastFail?.started_at ?? null, lastError: lastFail?.error ?? null },
        action: view });
    } else if (health.state === 'attention') {
      add({ kind: 'recent_failures', severity: 'attention', certainty: 'certain', ...ref,
        title: health.reasons[0],
        why: 'A recent failure means at least one run did not do its job.',
        body: lastFail?.error ? `Last error: ${lastFail.error}` : 'Open the latest run to see what went wrong.',
        evidence: { lastFailureAt: lastFail?.started_at ?? null, lastError: lastFail?.error ?? null },
        action: view });
    }

    // C. Missed schedules: tracked slots only (see schedule_slots).
    let slotsTracked = 0;
    let lastMissed = null;
    const missed = [];
    for (const s of slotsStmt.all(a.id, now - rules.window)) {
      slotsTracked++;
      const o = slotOutcome({ consumedAt: s.consumed_at, execution: s.exec_id ? s : null, now, rules });
      if (o === 'missed' || o === 'never') { missed.push({ slot: s.slot, outcome: o }); lastMissed ??= s.slot; }
    }
    if (missed.length) {
      const offline = missed.every((m) => m.outcome === 'missed');
      add({ kind: 'missed_schedule', severity: 'attention', certainty: 'certain', ...ref,
        title: missed.length === 1 ? 'Scheduled run was missed' : `${missed.length} scheduled runs were missed`,
        why: 'It was expected to run at a set time and didn\'t, so whatever it does didn\'t happen.',
        body: offline
          ? 'The Autometa server was offline at the scheduled time.'
          : 'The scheduler picked up the time slot, but no run was recorded for it.',
        evidence: { missedSlots: missed.slice(0, 10), lastMissedAt: lastMissed, lookbackDays: rules.window / DAY },
        action: view });
    } else if (a.status === 'active' && a.next_run_at != null && now - a.next_run_at > rules.overdueGrace) {
      add({ kind: 'schedule_overdue', severity: 'attention', certainty: 'unusual', ...ref,
        title: 'Scheduled run looks overdue',
        why: 'It was due and hasn\'t started yet.',
        body: 'This can be a short server delay. If it lasts, the run will be recorded as missed.',
        evidence: { dueAt: a.next_run_at, minutesLate: Math.round((now - a.next_run_at) / 60e3) },
        action: view });
    }

    // D. Long inactivity: event-driven automations with an established rhythm.
    if (a.status === 'active' && a.next_run_at == null && runs.length >= rules.inactiveMinRuns && lastRun != null) {
      const gaps = [];
      for (let i = 0; i + 1 < runs.length; i++) gaps.push(runs[i].started_at - runs[i + 1].started_at);
      const typical = median(gaps);
      const silent = now - lastRun;
      const threshold = Math.max(rules.inactiveMinGap, rules.inactiveFactor * typical);
      if (typical > 0 && silent > threshold) {
        add({ kind: 'looks_inactive', severity: 'info', certainty: 'unusual', ...ref,
          title: 'Looks inactive',
          why: `It usually runs about every ${humanGap(typical)}, but hasn't run for ${humanGap(silent)}.`,
          body: 'That may be expected if nothing triggered it. If not, check its trigger and connection.',
          evidence: { typicalGapMs: Math.round(typical), silentMs: silent, thresholdMs: Math.round(threshold), basedOnRuns: runs.length, triggerType: trigger.type ?? trigger.key ?? null },
          action: { type: 'open_automation', id: a.id, label: 'Review automation' } });
      }
    }

    return {
      id: a.id, name: a.name, status: a.status, enabled: a.status === 'active', mode: 'cloud',
      health,
      totals: { runs: tot.runs || 0, succeeded: tot.ok || 0, failed: tot.bad || 0, skipped: tot.skipped || 0 },
      createdAt: a.created_at, updatedAt: a.updated_at, firstRunAt: tot.first ?? null,
      lastRunAt: lastRun, lastFailureAt: lastFail?.started_at ?? null, lastError: lastFail?.error ?? null,
      nextRunAt: a.next_run_at,
      schedule: { slotsTracked, missed: missed.length },
      connections: conns.filter((c) => usesConn(a, c)).map((c) => ({ id: c.id, integration: c.integration, status: c.status })),
    };
  });

  // B. Connections: an explicit broken state recorded by the backend.
  for (const c of conns) {
    if (c.status === 'connected' || c.status === 'disconnected' || !c.status) continue;
    const users = autos.filter((a) => usesConn(a, c));
    const name = c.label || c.integration;
    add({ kind: 'connection_attention', severity: users.some((a) => a.status === 'active' || a.status === 'error') ? 'critical' : 'attention',
      certainty: 'certain', connectionId: c.id, integration: c.integration,
      title: `${name} connection needs attention`,
      why: users.length ? `${users.length} ${users.length === 1 ? 'automation uses' : 'automations use'} it and can't run until it is reconnected.` : 'Automations that use it can\'t run until it is reconnected.',
      body: c.status === 'needs_reauth' ? `${name} needs to be reconnected.` : (c.last_error || `${name} reported a connection error.`),
      evidence: { status: c.status, lastError: c.last_error ?? null, lastOkAt: c.last_ok_at ?? null, affectedAutomations: users.map((a) => ({ id: a.id, name: a.name })) },
      action: { type: 'reconnect', id: c.id, label: 'Reconnect' } });
  }

  findings.sort((x, y) => (RANK[x.kind] ?? 9) - (RANK[y.kind] ?? 9));
  const counts = { healthy: 0, attention: 0, critical: 0, inactive: 0, unknown: 0 };
  for (const a of automations) counts[a.health.state]++;
  return { generatedAt: now, rules: { ...rules }, summary: counts, findings, automations };
}
