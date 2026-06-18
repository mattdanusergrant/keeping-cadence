// POST /api/billing-checkout  (Bearer) -> { url }
// Creates a Stripe Checkout subscription session. No-ops (503) until the
// Stripe env vars are set.
import Stripe from 'stripe';
import { sql, cors, getUserId } from './_lib.js';

export default async function handler(req, res) {
  if (cors(req, res)) return;
  if (req.method !== 'POST') return res.status(405).json({ error: 'method not allowed' });
  if (!process.env.STRIPE_SECRET_KEY || !process.env.STRIPE_PRICE_ID) {
    return res.status(503).json({ error: 'billing not configured' });
  }
  const uid = getUserId(req);
  if (!uid) return res.status(401).json({ error: 'not signed in' });

  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
    const [u] = await sql`select email from users where id = ${uid}`;
    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      line_items: [{ price: process.env.STRIPE_PRICE_ID, quantity: 1 }],
      customer_email: u ? u.email : undefined,
      client_reference_id: uid,
      success_url: process.env.CHECKOUT_SUCCESS_URL,
      cancel_url: process.env.CHECKOUT_CANCEL_URL
    });
    return res.status(200).json({ url: session.url });
  } catch (err) {
    return res.status(500).json({ error: 'server error' });
  }
}
