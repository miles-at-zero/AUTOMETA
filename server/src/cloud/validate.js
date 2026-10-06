import { INTEGRATIONS } from './integrations/index.js';
import { requireFields } from './integrations/base.js';
import { cloudPlan } from './plans.js';
import { parseCron, toCrons, validTimezone } from './schedule.js';

// Canonical weekday variable is {{weekday}} ("Sunday"). {{day}} is accepted as
// an explicit compatibility alias for automations built before the rename.
export const VARIABLE_ALIASES = { day: 'weekday' };
const BASE_ROOTS = ['trigger', 'payload', 'headers', 'date', 'time', 'weekday', 'execution'];
const MAX_FREE_RULES = 3;
/** Checks a variable path like "email.subject" or "steps.s1.messageId". Returns an error string or null. */
export function variableProblem(path, { roots, priorStepIds }) {
  const p = String(path || '').replace(/^\{\{\s*|\s*\}\}$/g, '').trim();
  if (!/^[\w-]+(\.[\w-]+)*$/.test(p)) return `"${path}" isn't a valid variable`;
  const [root0, second] = p.split('.');
  const root = VARIABLE_ALIASES[root0] && !second ? VARIABLE_ALIASES[root0] : root0;
  if (root === 'steps') return second && priorStepIds.includes(second) ? null : `"${p}" refers to a step that doesn't run before this one`;
  return roots.includes(root) ? null : `Unknown variable "${p}" (available: ${roots.join(', ')}, steps.<id>)`;
}
const OPS = ['eq', 'neq', 'contains', 'not_contains', 'starts_with', 'gt', 'lt', 'exists', 'not_exists'];
export { OPS };

/**
 * Human-readable pre-activation checklist.
 * @returns {{ok:boolean, checks:{ok:boolean,label:string,fix?:string,stepId?:string}[]}}
 */
export function validateAutomation(a, { connections = [], webhooks = [], planId = 'free', env = process.env } = {}) {
  const checks = [];
  const add = (ok, label, fix, stepId) => checks.push({ ok, label, ...(ok ? {} : { fix }), ...(stepId ? { stepId } : {}) });
  const plan = cloudPlan(planId);
  const t = a.trigger || {};

  add(!!String(a.name || '').trim(), 'Automation has a name', 'Give it a name.');
  add(validTimezone(a.timezone || 'UTC'), `Timezone ${a.timezone || 'UTC'}`, 'Pick a valid timezone.');

  const ti = INTEGRATIONS[t.integration];
  const tdef = ti?.triggers?.[t.key];
  add(!!tdef, tdef ? `Trigger: ${tdef.label}` : 'Trigger chosen', 'Choose what starts this automation.');
  if (tdef && t.key === 'schedule') {
    let ok = true; let msg = 'Schedule configured';
    try {
      const s = t.schedule || {};
      if (s.everyMinutes) {
        if (Number(s.everyMinutes) < plan.limits.minIntervalMinutes) { ok = false; msg = `${plan.name} runs at most every ${plan.limits.minIntervalMinutes} minutes`; }
      } else {
        const crons = toCrons(s);
        if (!crons.length) { ok = false; msg = 'Add at least one time'; }
        crons.forEach(parseCron);
      }
    } catch (e) { ok = false; msg = e.message; }
    add(ok, ok ? 'Schedule configured' : `Schedule: ${msg}`, 'Fix the schedule times.');
  }
  if (ti && ti.available && !ti.available(env)) add(false, `${ti.name} is not available on this server`, ti.unavailableReason);
  if (tdef && ti.auth.type !== 'none') {
    const c = connections.find((x) => x.id === t.connectionId && x.integration === ti.id);
    add(!!c && c.status === 'connected', c ? `${ti.name} ${c.status === 'connected' ? `connected (${c.identity})` : 'needs attention'}` : `${ti.name} connection chosen for the trigger`, c ? `Reconnect ${ti.name}.` : `Connect ${ti.name} and select it in the trigger.`);
  }
  if (tdef && t.integration === 'webhook') {
    const wh = webhooks.find((w) => w.id === t.config?.webhookId);
    add(!!wh && !!wh.enabled, wh ? `Webhook "${wh.name}" ${wh.enabled ? 'enabled' : 'disabled'}` : 'Webhook selected', wh ? 'Enable the webhook.' : 'Create or choose a webhook.');
  }

  const steps = Array.isArray(a.steps) ? a.steps : [];
  const actions = steps.filter((s) => s.type === 'action' && s.enabled !== false);
  add(actions.length > 0, actions.length ? `${actions.length} action${actions.length > 1 ? 's' : ''}` : 'At least one action', 'Add something for Autometa to do.');
  add(steps.length <= plan.limits.stepsPerAutomation, `${steps.length} of ${plan.limits.stepsPerAutomation} steps allowed on ${plan.name}`, 'Remove steps or upgrade.');

  const ids = new Set();
  const roots = [...BASE_ROOTS, ...new Set((tdef?.variables || []).map((v) => v.split('.')[0]))];
  steps.forEach((s, i) => {
    const n = `Step ${i + 1}`;
    if (!s.id || ids.has(s.id)) add(false, `${n} has a unique id`, 'Re-add this step.', s.id);
    ids.add(s.id);
    if (s.enabled === false) return;
    if (s.type === 'delay') {
      add(Number(s.minutes) > 0 && Number(s.minutes) <= 7 * 1440, `${n}: wait ${s.minutes || '?'} min`, 'Wait between 1 minute and 7 days.', s.id);
    } else if (s.type === 'condition') {
      const rules = s.rules || [];
      const prior = steps.slice(0, i).map((x) => x.id);
      const problems = [];
      if (!rules.length) problems.push('add at least one condition');
      if (s.mode && !['all', 'any'].includes(s.mode)) problems.push(`match mode "${s.mode}" isn't supported (use all or any)`);
      for (const r of rules) {
        if (!String(r.field || '').trim()) { problems.push('a condition has no field'); continue; }
        if (!OPS.includes(r.op || 'eq')) { problems.push(`comparison "${r.op}" isn't supported`); continue; }
        const vp = variableProblem(r.field, { roots, priorStepIds: prior });
        if (vp) problems.push(vp);
        for (const m of String(r.value ?? '').matchAll(/\{\{\s*([^}]+?)\s*\}\}/g)) { const p2 = variableProblem(m[1], { roots, priorStepIds: prior }); if (p2) problems.push(p2); }
      }
      add(!problems.length, problems.length ? `${n}: ${problems[0]}` : `${n}: condition${rules.length > 1 ? 's' : ''} set`, 'Each condition needs a known variable, a supported comparison and a value.', s.id);
      if (rules.length > MAX_FREE_RULES && !plan.features.includes('advancedConditions')) add(false, `${n}: more than ${MAX_FREE_RULES} conditions in one step need Plus`, `Use up to ${MAX_FREE_RULES} conditions or upgrade to Plus.`, s.id);
    } else if (s.type === 'action') {
      const integ = INTEGRATIONS[s.integration];
      const def = integ?.actions?.[s.action];
      if (!def) { add(false, `${n}: action chosen`, 'Choose an action.', s.id); return; }
      if (integ.available && !integ.available(env)) add(false, `${n}: ${integ.name} is not available on this server`, integ.unavailableReason, s.id);
      const errs = [...requireFields(s.config || {}, def.config), ...(def.validate?.(s.config || {}) || [])];
      add(!errs.length, errs.length ? `${n}: ${errs[0]}` : `${n}: ${def.label} configured`, 'Fill in this step.', s.id);
      if (integ.auth.type !== 'none') {
        const c = connections.find((x) => x.id === s.connectionId && x.integration === integ.id);
        add(!!c && c.status === 'connected', c ? `${integ.name} ${c.status === 'connected' ? `connected (${c.identity})` : 'needs attention'}` : `${integ.name} connection chosen`, c ? `Reconnect ${integ.name}.` : `Connect ${integ.name} and select it in this step.`, s.id);
      }
    } else add(false, `${n}: unknown step type`, 'Remove this step.', s.id);
  });
  if (a.retry?.policy && a.retry.policy !== 'none' && !plan.features.includes('retries')) add(false, 'Retries need Plus', 'Set retries to "No retry" or upgrade.');
  return { ok: checks.every((c) => c.ok), checks };
}
