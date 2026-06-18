// Team membership for the manager/user model. All endpoints need a Bearer token.
//   GET  /api/team?action=team                  (manager) -> { users:[{id,email}] }
//   POST /api/team?action=invite  { email }      (manager) -> { ok:true }
//   GET  /api/team?action=invites               (user)    -> { invites:[{id,managerEmail}] }
//   POST /api/team?action=accept  { inviteId }   (user)    -> { ok:true, managerId }
//   POST /api/team?action=decline { inviteId }   (user)    -> { ok:true }
import { sql, cors, readJson, getUser, isUuid } from './_lib.js';

export default async function handler(req, res) {
  if (cors(req, res)) return;
  const me = await getUser(req);
  if (!me) return res.status(401).json({ error: 'not signed in' });
  const action = String(req.query.action || '');

  try {
    // --- manager side -------------------------------------------------------
    if (req.method === 'GET' && action === 'team') {
      if (me.role !== 'manager') return res.status(403).json({ error: 'managers only' });
      const users = await sql`select id, email from users where manager_id = ${me.id} order by email`;
      return res.status(200).json({ users });
    }

    if (req.method === 'POST' && action === 'invite') {
      if (me.role !== 'manager') return res.status(403).json({ error: 'managers only' });
      const { email } = await readJson(req);
      const e = String(email || '').trim().toLowerCase();
      if (!e.includes('@')) return res.status(400).json({ error: 'valid email required' });
      if (e === me.email) return res.status(400).json({ error: 'cannot invite yourself' });
      await sql`
        insert into team_invites (manager_id, email) values (${me.id}, ${e})
        on conflict (manager_id, email) do update set status = 'pending', created_at = now()`;
      return res.status(200).json({ ok: true });
    }

    // --- user side ----------------------------------------------------------
    if (req.method === 'GET' && action === 'invites') {
      const invites = await sql`
        select ti.id, mu.email as "managerEmail"
        from team_invites ti join users mu on mu.id = ti.manager_id
        where ti.email = ${me.email} and ti.status = 'pending'
        order by ti.created_at`;
      return res.status(200).json({ invites });
    }

    if (req.method === 'POST' && (action === 'accept' || action === 'decline')) {
      if (me.role !== 'user') return res.status(403).json({ error: 'only user accounts can join a team' });
      const { inviteId } = await readJson(req);
      if (!isUuid(inviteId)) return res.status(400).json({ error: 'inviteId required' });
      const [inv] = await sql`
        select id, manager_id as "managerId" from team_invites
        where id = ${inviteId} and email = ${me.email} and status = 'pending'`;
      if (!inv) return res.status(404).json({ error: 'invite not found' });
      if (action === 'accept') {
        await sql`update users set manager_id = ${inv.managerId} where id = ${me.id}`;
        await sql`update team_invites set status = 'accepted' where id = ${inv.id}`;
        return res.status(200).json({ ok: true, managerId: inv.managerId });
      }
      await sql`update team_invites set status = 'declined' where id = ${inv.id}`;
      return res.status(200).json({ ok: true });
    }

    return res.status(405).json({ error: 'unknown action' });
  } catch (err) {
    return res.status(500).json({ error: 'server error' });
  }
}
