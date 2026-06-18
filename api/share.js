// GET /api/share?slug=...&from=YYYY-MM-DD&to=YYYY-MM-DD   (no auth)
// Anonymous read-only view of a schedule by its share slug.
import { sql, cors } from './_lib.js';

export default async function handler(req, res) {
  if (cors(req, res)) return;
  if (req.method !== 'GET') return res.status(405).json({ error: 'method not allowed' });

  const slug = String(req.query.slug || '');
  if (!slug) return res.status(400).json({ error: 'slug required' });

  try {
    const [s] = await sql`select id, name, color_var as "colorVar" from schedules where slug = ${slug}`;
    if (!s) return res.status(404).json({ error: 'not found' });

    const { from, to } = req.query;
    const weeks = (from && to)
      ? await sql`select week_start as "weekStart", days from weeks
                  where schedule_id = ${s.id} and week_start between ${from} and ${to}
                  order by week_start`
      : await sql`select week_start as "weekStart", days from weeks
                  where schedule_id = ${s.id} order by week_start`;

    return res.status(200).json({ schedule: { name: s.name, colorVar: s.colorVar }, weeks });
  } catch (err) {
    return res.status(500).json({ error: 'server error' });
  }
}
