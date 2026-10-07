// AUTOMETA GUARDIAN (foundation).
//
// Read-only: derives per-automation health and "worth your attention" findings
// from data the Cloud already stores (automations, executions, connections).
// No schema changes, no side effects, no invented numbers, no AI.
//
// Every finding carries `evidence` (the facts it was derived from) and a
// `certainty`:
//   'certain'  – a recorded fact (a connection is marked needs_reauth, the
//                last 3 runs failed, the automation was paused after failures)
//   'unusual'  – a deterministic heuristic that *looks* wrong but may be fine
//                (overdue schedule, unusually quiet event-driven automation).
//                The UI must word these as "looks unusual", never "broken".
//
// Health rules mirror the app (docs/AUTOMATION_HEALTH.md) so a Cloud
// automation shows the same state in both places.

const DAY = 864e5;
export const GUARDIAN_RULES = Object.freeze({
  window: 7 * DAY,          // "recent" failures
  criticalStreak: 3,        // consecutive failed runs → critical
  overdueGrace: 15 * 60e3,  // scheduler slack before a due run counts as overdue
  quietMinRuns: 5,          // need this many runs before judging "quiet"
  quietFactor: 3,           // silent for > factor × typical gap …
  quietMinGap: DAY,         // … and at least a day
  sample: 50,               // recent runs examined per automation
});

const FAILED = new Set(['failed', 'partial']);
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

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
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

  const findings = [];
  const add = (f) => findings.push(f);

  const automations = autos.map((a) => {
    const runs = runsStmt.all(a.id, rules.sample);
    const tot = totalsStmt.get(a.id);
    const health = healthOf({ status: a.status, runs, now, rules });
    const lastRun = runs[0]?.started_at ?? null;
    const lastFail = runs.find((r) => FAILED.has(r.status)) || null;
    const trigger = parse(a.trigger, {});
    const ref = { automationId: a.id, automationName: a.name };

    // Recorded facts.
    if (a.status === 'error') {
      add({ kind: 'paused_after_failures', severity: 'critical', certainty: 'certain', ...ref,
        title: 'Paused after repeated failures',
        body: a.status_reason || 'Autometa stopped running this automation because it kept failing.',
        evidence: { consecutiveFailures: a.consecutive_failures } });
    } else if (health.state === 'critical') {
      add({ kind: 'repeated_failures', severity: 'critical', certainty: 'certain', ...ref,
        title: health.reasons[0], body: lastFail?.error || 'Open the latest run to see what went wrong.',
        evidence: { lastFailureAt: lastFail?.started_at ?? null } });
    } else if (health.state === 'attention') {
      add({ kind: 'recent_failures', severity: 'attention', certainty: 'certain', ...ref,
        title: health.reasons[0], body: lastFail?.error || 'Open the latest run to see what went wrong.',
        evidence: { lastFailureAt: lastFail?.started_at ?? null } });
    }

    // Heuristics (only for active automations).
    if (a.status === 'active') {
      if (a.next_run_at != null && now - a.next_run_at > rules.overdueGrace) {
        add({ kind: 'overdue_schedule', severity: 'attention', certainty: 'unusual', ...ref,
          title: 'A scheduled run looks overdue',
          body: 'It was due earlier and hasn\'t run yet. This can be a short server delay; if it persists, check the schedule.',
          evidence: { dueAt: a.next_run_at, minutesLate: Math.round((now - a.next_run_at) / 60e3) } });
      } else if (a.next_run_at == null && runs.length >= rules.quietMinRuns && lastRun != null) {
        // Event-driven (webhook / Gmail): compare silence with its own rhythm.
        const gaps = [];
        for (let i = 0; i + 1 < runs.length; i++) gaps.push(runs[i].started_at - runs[i + 1].started_at);
        const typical = median(gaps);
        const silent = now - lastRun;
        if (typical > 0 && silent > Math.max(rules.quietMinGap, rules.quietFactor * typical)) {
          add({ kind: 'unusually_quiet', severity: 'info', certainty: 'unusual', ...ref,
            title: 'Looks unusually quiet',
            body: `It usually runs about every ${humanGap(typical)}, but hasn't run for ${humanGap(silent)}. That may be expected if nothing happened.`,
            evidence: { typicalGapMs: Math.round(typical), silentMs: silent, triggerType: trigger.type ?? null } });
        }
      }
    }

    return {
      id: a.id, name: a.name, status: a.status, mode: 'cloud',
      health,
      totals: { runs: tot.runs || 0, succeeded: tot.ok || 0, failed: tot.bad || 0, skipped: tot.skipped || 0 },
      createdAt: a.created_at, updatedAt: a.updated_at, firstRunAt: tot.first ?? null,
      lastRunAt: lastRun, lastFailureAt: lastFail?.started_at ?? null, lastError: lastFail?.error ?? null,
      nextRunAt: a.next_run_at,
    };
  });

  // Connections: a recorded status, so certain. Link the active automations
  // that reference the connection (by id in their stored trigger/steps).
  for (const c of conns) {
    if (c.status === 'connected' || c.status === 'disconnected') continue;
    const users = autos.filter((a) => a.status !== 'archived' && (a.steps.includes(c.id) || a.trigger.includes(c.id)));
    add({ kind: 'connection_attention', severity: 'critical', certainty: 'certain',
      connectionId: c.id, integration: c.integration,
      title: c.status === 'needs_reauth' ? `${c.label || c.integration} needs to be reconnected` : `${c.label || c.integration} has a connection problem`,
      body: c.last_error || 'Reconnect it so the automations that use it can run.',
      evidence: { status: c.status, affectedAutomations: users.map((a) => ({ id: a.id, name: a.name })) } });
  }

  const order = { critical: 0, attention: 1, info: 2 };
  findings.sort((x, y) => order[x.severity] - order[y.severity]);
  const counts = { healthy: 0, attention: 0, critical: 0, inactive: 0, unknown: 0 };
  for (const a of automations) counts[a.health.state]++;
  return { generatedAt: now, rules: { ...rules }, summary: counts, findings, automations };
}

function humanGap(ms) {
  if (ms >= 2 * DAY) return `${Math.round(ms / DAY)} days`;
  if (ms >= 2 * 3600e3) return `${Math.round(ms / 3600e3)} hours`;
  return `${Math.max(1, Math.round(ms / 60e3))} minutes`;
}
