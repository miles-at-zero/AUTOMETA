import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

export const newId = (prefix = '') => prefix + randomBytes(9).toString('base64url');
export const newToken = () => randomBytes(32).toString('base64url');
/** Short human-typeable code for onboarding/invites, e.g. "K7QF-2M9X-PA4D". */
export const newCode = () => {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const b = randomBytes(12);
  let s = '';
  for (let i = 0; i < 12; i++) s += alphabet[b[i] % alphabet.length];
  return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8)}`;
};
export const sha256 = (s) => createHash('sha256').update(String(s)).digest('hex');
export const normalizeCode = (c) => String(c || '').toUpperCase().replace(/[^A-Z0-9]/g, '');

function key(secret) {
  if (!secret || secret.length < 16) throw new Error('SECRET_KEY must be at least 16 characters');
  return createHash('sha256').update(secret).digest();
}

/** AES-256-GCM. Output: base64url(iv).base64url(tag).base64url(ciphertext) */
export function encrypt(plain, secret) {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key(secret), iv);
  const enc = Buffer.concat([c.update(String(plain), 'utf8'), c.final()]);
  return [iv, c.getAuthTag(), enc].map((b) => b.toString('base64url')).join('.');
}

export function decrypt(blob, secret) {
  if (!blob) return null;
  const [iv, tag, enc] = blob.split('.').map((p) => Buffer.from(p, 'base64url'));
  const d = createDecipheriv('aes-256-gcm', key(secret), iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(enc), d.final()]).toString('utf8');
}

/** Meta webhook signature: X-Hub-Signature-256: sha256=<hmac(appSecret, rawBody)> */
export function verifyMetaSignature(rawBody, header, appSecret) {
  if (!appSecret) return false;
  if (!header || !header.startsWith('sha256=')) return false;
  const expected = createHmac('sha256', appSecret).update(rawBody).digest();
  const got = Buffer.from(header.slice(7), 'hex');
  return got.length === expected.length && timingSafeEqual(got, expected);
}
