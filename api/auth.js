// POST /api/auth?action=signup   { email, password } -> { user, token }
// POST /api/auth?action=login    { email, password } -> { user, token }
// GET  /api/auth?action=me       (Bearer)            -> { user }
// (Logout is client-side: discard the token.)
import { sql, cors, readJson, hashPassword, verifyPassword, makeToken, getUserId } from './_lib.js';

export default async function handler(req, res) {
  if (cors(req, res)) return;
  const action = String(req.query.action || '');
  try {
    if (req.method === 'GET' && action === 'me') {
      const uid = getUserId(req);
      if (!uid) return res.status(401).json({ error: 'not signed in' });
      const [u] = await sql`select id, email from users where id = ${uid}`;
      return res.status(200).json({ user: u || null });
    }

    if (req.method === 'POST' && (action === 'signup' || action === 'login')) {
      const { email, password } = await readJson(req);
      const e = String(email || '').trim().toLowerCase();
      const p = String(password || '');
      if (!e.includes('@') || p.length < 8) {
        return res.status(400).json({ error: 'valid email and 8+ character password required' });
      }

      if (action === 'signup') {
        const existing = await sql`select 1 from users where email = ${e}`;
        if (existing.length) return res.status(409).json({ error: 'an account with that email already exists' });
        const [u] = await sql`
          insert into users (email, password_hash) values (${e}, ${hashPassword(p)})
          returning id, email`;
        return res.status(200).json({ user: u, token: makeToken(u.id) });
      }

      const [u] = await sql`select id, email, password_hash from users where email = ${e}`;
      if (!u || !verifyPassword(p, u.password_hash)) {
        return res.status(401).json({ error: 'invalid email or password' });
      }
      return res.status(200).json({ user: { id: u.id, email: u.email }, token: makeToken(u.id) });
    }

    return res.status(405).json({ error: 'method not allowed' });
  } catch (err) {
    return res.status(500).json({ error: 'server error' });
  }
}
