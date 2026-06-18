// POST /api/billing-webhook  — Stripe webhook. Verifies the signature over
// the raw body, then maintains the subscriptions table.
import Stripe from 'stripe';
import { sql } from './_lib.js';

export const config = { api: { bodyParser: false } };

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).end();
  if (!process.env.STRIPE_SECRET_KEY || !process.env.STRIPE_WEBHOOK_SECRET) return res.status(503).end();

  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks);

  let event;
  try {
    event = stripe.webhooks.constructEvent(raw, req.headers['stripe-signature'], process.env.STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    return res.status(400).send('invalid signature');
  }

  try {
    const o = event.data.object;
    if (event.type === 'checkout.session.completed') {
      const uid = o.client_reference_id;
      if (uid) {
        await sql`
          insert into subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, updated_at)
          values (${uid}, ${o.customer}, ${o.subscription}, 'active', now())
          on conflict (user_id) do update set
            stripe_customer_id = excluded.stripe_customer_id,
            stripe_subscription_id = excluded.stripe_subscription_id,
            status = 'active', updated_at = now()`;
      }
    } else if (event.type === 'customer.subscription.updated' || event.type === 'customer.subscription.deleted') {
      const end = o.current_period_end ? new Date(o.current_period_end * 1000).toISOString() : null;
      await sql`
        update subscriptions set status = ${o.status}, current_period_end = ${end}, updated_at = now()
        where stripe_subscription_id = ${o.id}`;
    }
    return res.status(200).json({ received: true });
  } catch (err) {
    return res.status(500).end();
  }
}
