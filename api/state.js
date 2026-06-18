// GET /api/state?week=YYYY-MM-DD  (Bearer)
//   -> { schedules:[{id,name,colorVar,slug,assignedUserId,access}], weeks:{scheduleId:days}, settings, subscription }
//   access is 'plan'    — caller owns the schedule, edits the plan (title/times/buffers)
//          or 'actuals' — caller is the assigned member, edits only actualHours.
// PUT /api/state  (Bearer)  { weekStart, schedules:[{id,name,colorVar,assignedUserId?,days}], settings }
//   -> { schedules:[{localId,id,slug}] }   (client adopts the returned ids)
import { sql, cors, readJson, getUser, isUuid, slugify } from './_lib.js';

// actualHours is the only member-entered field; everything else is the owner's
// plan. Merge so an owner can't overwrite a member's hours, and a member can't
// touch the plan — regardless of what the client sends.
function mergeDay(existing = {}, incoming = {}, access) {
  if (access === 'actuals') {
    return { ...existing, actualHours: incoming.actualHours ?? existing.actualHours ?? '' };
  }
  return { ...incoming, actualHours: existing.actualHours ?? incoming.actualHours ?? '' };
}
function mergeDays(existing, incoming, access) {
  const ex = Array.isArray(existing) ? existing : [];
  const inc = Array.isArray(incoming) ? incoming : [];
  const n = Math.max(ex.length, inc.length);
  const out = [];
  for (let i = 0; i < n; i++) out.push(mergeDay(ex[i], inc[i], access));
  return out;
}

// A manager may only assign a schedule to a user on their own team.
async function resolveAssignee(managerId, assignedUserId) {
  if (!isUuid(assignedUserId)) return null;
  const [u] = await sql`select id from users where id = ${assignedUserId} and manager_id = ${managerId}`;
  return u ? u.id : null;
}

export default async function handler(req, res) {
  if (cors(req, res)) return;
  const me = await getUser(req);
  if (!me) return res.status(401).json({ error: 'not signed in' });
  const uid = me.id;

  try {
    if (req.method === 'GET') {
      const week = String(req.query.week || '');
      const rows = await sql`
        select id, name, color_var as "colorVar", slug,
               owner_id as "ownerId", assigned_user_id as "assignedUserId"
        from schedules
        where owner_id = ${uid} or assigned_user_id = ${uid}
        order by created_at`;
      const schedules = rows.map(s => ({
        id: s.id, name: s.name, colorVar: s.colorVar, slug: s.slug,
        assignedUserId: s.assignedUserId,
        access: s.ownerId === uid ? 'plan' : 'actuals'
      }));
      let weekRows = [];
      if (week) {
        weekRows = await sql`
          select w.schedule_id, w.days from weeks w
          join schedules s on s.id = w.schedule_id
          where (s.owner_id = ${uid} or s.assigned_user_id = ${uid}) and w.week_start = ${week}`;
      }
      const [st]  = await sql`select settings from operator_settings where user_id = ${uid}`;
      const [sub] = await sql`select status, current_period_end as "currentPeriodEnd"
                              from subscriptions where user_id = ${uid}`;
      return res.status(200).json({
        schedules,
        weeks: Object.fromEntries(weekRows.map(w => [w.schedule_id, w.days])),
        settings: st ? st.settings : null,
        subscription: sub || null
      });
    }

    if (req.method === 'PUT') {
      const { weekStart, schedules = [], settings } = await readJson(req);
      if (!weekStart) return res.status(400).json({ error: 'weekStart required' });

      const out = [];
      for (const s of schedules) {
        const name = String(s.name || 'Schedule');
        const color = String(s.colorVar || 'accent');

        // Resolve the target schedule and the caller's access to it.
        let row = null, access = 'plan';
        if (isUuid(s.id)) {
          const [existing] = await sql`
            select id, slug, owner_id as "ownerId", assigned_user_id as "assignedUserId"
            from schedules where id = ${s.id}`;
          if (!existing) continue;                       // unknown id — skip
          if (existing.ownerId === uid) access = 'plan';
          else if (existing.assignedUserId === uid) access = 'actuals';
          else continue;                                 // not the caller's schedule — skip
          row = { id: existing.id, slug: existing.slug };
          if (access === 'plan') {
            let assigned = existing.assignedUserId;       // a manager may reassign; otherwise unchanged
            if (me.role === 'manager' && s.assignedUserId !== undefined) {
              assigned = await resolveAssignee(uid, s.assignedUserId);
            }
            await sql`update schedules set name = ${name}, color_var = ${color},
                        assigned_user_id = ${assigned} where id = ${existing.id}`;
          }
        }
        if (!row) {
          // Create: only an owner creates. Solo users own their own schedules;
          // a manager may assign the new schedule to one of their team members.
          const assigned = me.role === 'manager' ? await resolveAssignee(uid, s.assignedUserId) : null;
          [row] = await sql`
            insert into schedules (owner_id, assigned_user_id, name, color_var, slug)
            values (${uid}, ${assigned}, ${name}, ${color}, ${slugify()})
            returning id, slug`;
          access = 'plan';
        }

        if (Array.isArray(s.days)) {
          const [w] = await sql`select days from weeks where schedule_id = ${row.id} and week_start = ${weekStart}`;
          const merged = mergeDays(w ? w.days : [], s.days, access);
          await sql`
            insert into weeks (schedule_id, week_start, days, updated_at)
            values (${row.id}, ${weekStart}, ${JSON.stringify(merged)}::jsonb, now())
            on conflict (schedule_id, week_start)
            do update set days = excluded.days, updated_at = now()`;
        }
        out.push({ localId: s.id, id: row.id, slug: row.slug });
      }

      if (settings && typeof settings === 'object') {
        await sql`
          insert into operator_settings (user_id, settings, updated_at)
          values (${uid}, ${JSON.stringify(settings)}::jsonb, now())
          on conflict (user_id) do update set settings = excluded.settings, updated_at = now()`;
      }
      return res.status(200).json({ schedules: out });
    }

    return res.status(405).json({ error: 'method not allowed' });
  } catch (err) {
    return res.status(500).json({ error: 'server error' });
  }
}
