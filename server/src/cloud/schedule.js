// Time-zone aware schedules. A schedule is either
//   { cron: "0 7 * * 1-5" }            (minute hour day-of-month month day-of-week)
//   { times: ["07:00","20:00"], days: [1,2,3,4,5] }   (0 = Sunday; days omitted = every day)
//   { everyMinutes: 30 }
// Times are wall-clock in the automation's timezone; DST is handled by
// converting each candidate local time back to UTC.

const WD = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 };

function parseField(f, min, max, names = {}) {
  const out = new Set();
  for (const part of String(f).toLowerCase().split(',')) {
    const [range, stepStr] = part.split('/');
    const step = stepStr ? Number(stepStr) : 1;
    if (!(step >= 1)) throw new Error(`Bad step in "${f}"`);
    let lo, hi;
    if (range === '*') { lo = min; hi = max; }
    else {
      const [a, b] = range.split('-').map((x) => (names[x] ?? Number(x)));
      if (!Number.isInteger(a) || (b !== undefined && !Number.isInteger(b))) throw new Error(`Bad value "${part}"`);
      lo = a; hi = b ?? (stepStr ? max : a);
    }
    if (lo < min || hi > max || lo > hi) throw new Error(`"${part}" out of range ${min}-${max}`);
    for (let v = lo; v <= hi; v += step) out.add(v);
  }
  return out;
}

export function parseCron(expr) {
  const p = String(expr).trim().split(/\s+/);
  if (p.length !== 5) throw new Error('Cron needs 5 fields: minute hour day month weekday');
  const dow = parseField(p[4], 0, 7, WD);
  if (dow.has(7)) { dow.delete(7); dow.add(0); }
  return { minute: parseField(p[0], 0, 59), hour: parseField(p[1], 0, 23), dom: parseField(p[2], 1, 31), month: parseField(p[3], 1, 12), dow, domAny: p[2] === '*', dowAny: p[4] === '*' };
}

export function toCrons(s) {
  if (s.cron) return [s.cron];
  if (s.times?.length) {
    const days = s.days?.length ? [...new Set(s.days)].sort().join(',') : '*';
    return s.times.map((t) => {
      const m = /^(\d{1,2}):(\d{2})$/.exec(t);
      if (!m || +m[1] > 23 || +m[2] > 59) throw new Error(`Time "${t}" should look like 07:00`);
      return `${+m[2]} ${+m[1]} * * ${days}`;
    });
  }
  return [];
}

const fmtCache = new Map();
function parts(ms, tz) {
  let f = fmtCache.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short' });
    fmtCache.set(tz, f);
  }
  const o = Object.fromEntries(f.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return { y: +o.year, mo: +o.month, d: +o.day, h: +o.hour, mi: +o.minute, wd: WD[o.weekday.toLowerCase().slice(0, 3)] };
}

/** UTC ms for a wall-clock time in tz (DST gaps roll forward). */
export function zonedToUtc(y, mo, d, h, mi, tz) {
  let guess = Date.UTC(y, mo - 1, d, h, mi);
  for (let i = 0; i < 3; i++) {
    const p = parts(guess, tz);
    const diff = Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi) - Date.UTC(y, mo - 1, d, h, mi);
    if (diff === 0) return guess;
    guess -= diff;
  }
  return guess;
}

export function validTimezone(tz) {
  if (typeof tz !== 'string' || !tz) return false;
  try { new Intl.DateTimeFormat('en-US', { timeZone: tz }); return true; } catch { return false; }
}

/** Next run strictly after `after` (ms) or null. */
export function nextRun(schedule, tz, after) {
  if (!schedule) return null;
  if (schedule.everyMinutes) {
    const step = Math.max(1, Number(schedule.everyMinutes)) * 60e3;
    return Math.floor(after / step) * step + step;
  }
  const crons = toCrons(schedule).map(parseCron);
  if (!crons.length) return null;
  let best = null;
  const start = parts(after, tz);
  for (let dayOffset = 0; dayOffset < 400 && best == null; dayOffset++) {
    const day = new Date(Date.UTC(start.y, start.mo - 1, start.d + dayOffset));
    const y = day.getUTCFullYear(), mo = day.getUTCMonth() + 1, d = day.getUTCDate(), wd = day.getUTCDay();
    for (const c of crons) {
      if (!c.month.has(mo)) continue;
      const domOk = c.dom.has(d), dowOk = c.dow.has(wd);
      const dayOk = c.domAny && c.dowAny ? true : c.domAny ? dowOk : c.dowAny ? domOk : domOk || dowOk;
      if (!dayOk) continue;
      for (const h of [...c.hour].sort((a, b) => a - b)) {
        for (const mi of [...c.minute].sort((a, b) => a - b)) {
          const t = zonedToUtc(y, mo, d, h, mi, tz);
          if (t > after && (best == null || t < best)) best = t;
        }
      }
    }
  }
  return best;
}

export function describeSchedule(s) {
  if (!s) return 'No schedule';
  if (s.everyMinutes) return `Every ${s.everyMinutes} minutes`;
  if (s.cron) return `Cron: ${s.cron}`;
  const names = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const days = !s.days?.length || s.days.length === 7 ? 'Every day'
    : s.days.join() === '1,2,3,4,5' ? 'Every weekday'
    : s.days.join() === '0,6' ? 'Weekends' : s.days.map((d) => names[d]).join(', ');
  return `${days} at ${(s.times || []).join(', ')}`;
}
