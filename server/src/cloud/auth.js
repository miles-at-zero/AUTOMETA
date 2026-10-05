import { randomBytes, scrypt as _scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const scrypt = promisify(_scrypt);
const N = 16384;

export async function hashPassword(pw) {
  const salt = randomBytes(16);
  const dk = await scrypt(String(pw), salt, 64, { N, r: 8, p: 1 });
  return `scrypt$${N}$${salt.toString('base64url')}$${dk.toString('base64url')}`;
}

export async function verifyPassword(pw, stored) {
  const [alg, n, salt, hash] = String(stored || '').split('$');
  if (alg !== 'scrypt') return false;
  const expected = Buffer.from(hash, 'base64url');
  const dk = await scrypt(String(pw), Buffer.from(salt, 'base64url'), expected.length, { N: Number(n), r: 8, p: 1 });
  return timingSafeEqual(dk, expected);
}

export function passwordProblem(pw) {
  const s = String(pw || '');
  if (s.length < 10) return 'Use at least 10 characters.';
  if (s.length > 200) return 'Password is too long.';
  if (/^(.)\1+$/.test(s) || /^(password|1234567890|qwertyuiop)/i.test(s)) return 'That password is too easy to guess.';
  return null;
}

export const validEmail = (e) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(String(e || ''));

/** Fixed-window limiter in memory (per process). Good for one instance. */
export class RateLimiter {
  constructor(clock = () => Date.now()) { this.clock = clock; this.hits = new Map(); }
  hit(key, limit, windowMs) {
    const now = this.clock();
    const w = this.hits.get(key);
    if (!w || now - w.start >= windowMs) { this.hits.set(key, { start: now, n: 1 }); return true; }
    w.n++;
    if (this.hits.size > 50000) this.hits.clear();
    return w.n <= limit;
  }
}

/** Password-reset email via Resend's HTTP API if configured. */
export async function sendResetEmail({ env, fetchImpl, to, link }) {
  if (!env.RESEND_API_KEY || !env.MAIL_FROM) return false;
  const res = await fetchImpl('https://api.resend.com/emails', {
    method: 'POST', headers: { authorization: `Bearer ${env.RESEND_API_KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({ from: env.MAIL_FROM, to, subject: 'Reset your Autometa password', text: `Reset your password (valid 1 hour):\n${link}\n\nIf you didn't ask for this, ignore this email.` }),
  });
  return res.ok;
}
