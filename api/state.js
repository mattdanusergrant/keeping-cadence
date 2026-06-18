// GET /api/state?week=YYYY-MM-DD  (Bearer)
//   -> { schedules:[{id,name,colorVar,slug}], weeks:{scheduleId:days}, settings, subscription }
// PUT /api/state  (Bearer)  { weekStart, schedules:[{id,name,colorVar,days}], settings }
//   -> { schedules:[{localId,id,slug}] }   (client adopts the returned ids)
import { sql, cors, readJson, getUserId, isUuid, slugify } from './_lib.js';

export default async function handler(req, res) {
  if (cors(req, res)) return;
  const uid = getUserId(req);
  if (!uid) return res.status(401).json({ error: 'not signed in' });

  try {
    if (req.method === 'GET') {
      const week = String(req.query.week || '');
      const schedules = await sql`
        select id, name, color_var as "colorVar", slug
        from schedules where owner_id = ${uid} order by created_at`;
      let weekRows = [];
      if (week) {
        weekRows = await sql`
          select w.schedule_id, w.days from weeks w
          join schedules s on s.id = w.schedule_id
          where s.owner_id = ${uid} and w.week_start = ${week}`;
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
        let row;
        if (isUuid(s.id)) {
          [row] = await sql`
            update schedules set name = ${name}, color_var = ${color}
            where id = ${s.id} and owner_id = ${uid} returning id, slug`;
        }
        if (!row) {
          [row] = await sql`
            insert into schedules (owner_id, name, color_var, slug)
            values (${uid}, ${name}, ${color}, ${slugify()}) returning id, slug`;
        }
        if (Array.isArray(s.days)) {
          await sql`
            insert into weeks (schedule_id, week_start, days, updated_at)
            values (${row.id}, ${weekStart}, ${JSON.stringify(s.days)}::jsonb, now())
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
