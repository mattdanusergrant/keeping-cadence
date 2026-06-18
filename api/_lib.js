// Shared helpers for the Keeping Cadence serverless API.
import { neon } from '@neondatabase/serverless';
import crypto from 'node:crypto';
import jwt from 'jsonwebtoken';

export const sql = neon(process.env.DATABASE_URL);

const WEEK = 60 * 60 * 24 * 7;
const ORIGINS = (process.env.ALLOWED_ORIGINS || '')
  .split(',').map(s => s.trim()).filter(Boolean);

// Apply CORS headers. Returns true if the request was a preflight (already
// answered) and the caller should stop.
export function cors(req, res) {
  const origin = req.headers.origin;
  if (origin && (ORIGINS.includes('*') || ORIGINS.includes(origin))) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') { res.status(204).end(); return true; }
  return false;
}

// --- passwords (scrypt; no extra dependency) -------------------------------
export function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 64).toString('hex');
  return `${salt}:${hash}`;
}
export function verifyPassword(password, stored) {
  const [salt, hash] = String(stored).split(':');
  if (!salt || !hash) return false;
  const a = Buffer.from(hash, 'hex');
  const b = crypto.scryptSync(password, salt, 64);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// --- sessions (signed JWT, sent by the client as a Bearer token) -----------
export function makeToken(userId) {
  return jwt.sign({ uid: userId }, process.env.JWT_SECRET, { expiresIn: WEEK });
}
export function getUserId(req) {
  const m = (req.headers.authorization || '').match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  try { return jwt.verify(m[1], process.env.JWT_SECRET).uid; }
  catch { return null; }
}
// Like getUserId, but resolves the full account row (id, email, role, managerId).
export async function getUser(req) {
  const uid = getUserId(req);
  if (!uid) return null;
  const [u] = await sql`select id, email, role, manager_id as "managerId" from users where id = ${uid}`;
  return u || null;
}

// --- misc ------------------------------------------------------------------
export async function readJson(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks).toString('utf8');
  return raw ? JSON.parse(raw) : {};
}
export const isUuid = s => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s || '');
export function slugify() {
  return crypto.randomBytes(9).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
