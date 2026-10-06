// Business hours in the business's own time zone.
// hours = { mon: [["09:00","17:00"]], tue: [...], ..., sun: [] }; {} = always open.
const DAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

export function localParts(now, timeZone) {
  const f = new Intl.DateTimeFormat('en-GB', { timeZone, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  const parts = Object.fromEntries(f.formatToParts(new Date(now)).map((p) => [p.type, p.value]));
  return { day: parts.weekday.toLowerCase().slice(0, 3), minutes: Number(parts.hour) * 60 + Number(parts.minute) };
}

const toMin = (s) => {
  const [h, m] = String(s).split(':').map(Number);
  return h * 60 + (m || 0);
};

export function isOpen(hours, timeZone, now = Date.now()) {
  if (!hours || Object.keys(hours).length === 0) return true;
  const { day, minutes } = localParts(now, timeZone || 'UTC');
  const prev = DAYS[(DAYS.indexOf(day) + 6) % 7];
  const today = (hours[day] || []).some(([a, b]) => {
    const s = toMin(a), e = toMin(b);
    return e > s ? minutes >= s && minutes < e : minutes >= s; // overnight: evening part today
  });
  // Overnight range that started yesterday (e.g. Fri 18:00–02:00 covers Sat 01:30).
  const fromYesterday = (hours[prev] || []).some(([a, b]) => toMin(b) <= toMin(a) && minutes < toMin(b));
  return today || fromYesterday;
}

export function validateHours(hours) {
  const errors = [];
  for (const [d, ranges] of Object.entries(hours || {})) {
    if (!DAYS.includes(d)) errors.push(`Unknown day "${d}"`);
    if (!Array.isArray(ranges)) { errors.push(`${d}: expected a list of [open, close]`); continue; }
    for (const r of ranges) {
      if (!Array.isArray(r) || r.length !== 2 || !r.every((t) => /^\d{1,2}:\d{2}$/.test(t))) errors.push(`${d}: "${JSON.stringify(r)}" should look like ["09:00","17:00"]`);
      else if (r.some((t) => { const [h, m] = t.split(':').map(Number); return h > 24 || m > 59; })) errors.push(`${d}: time out of range in ${JSON.stringify(r)}`);
    }
  }
  return errors;
}
