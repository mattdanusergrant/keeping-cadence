# Keeping Cadence — Backend (Neon + serverless API)

The front-end (`index.html`) runs fully on its own. This backend is an optional
layer that adds **accounts, cross-device sync, share-by-slug, and Stripe
subscriptions**.

```
Browser (GitHub Pages)  ──HTTPS──>  Serverless API (/api on Vercel)  ──>  Neon Postgres
        index.html                    auth · state · share · billing         (private)
```

- The browser holds a signed session token (JWT) and sends it as
  `Authorization: Bearer …`. It never sees the database.
- The API (`/api/*.js`) holds `DATABASE_URL` as a server-side secret and
  enforces all access control in code (so we don't depend on Postgres RLS).

## Files

| Path | Purpose |
|---|---|
| `db/schema.sql` | Postgres schema (run once against Neon) |
| `api/_lib.js` | Shared: Neon client, JWT, scrypt password hashing, CORS |
| `api/auth.js` | `signup` / `login` / `me` |
| `api/state.js` | `GET`/`PUT` the signed-in user's schedules, weeks, settings |
| `api/share.js` | Anonymous read of a schedule by share slug |
| `api/billing-checkout.js` | Create a Stripe Checkout subscription session |
| `api/billing-webhook.js` | Stripe webhook → maintains the `subscriptions` table |
| `.env.example` | The environment variables to set |

## Setup

### 1. Neon database
1. Create a project at <https://neon.tech>.
2. Copy the **pooled** connection string (host contains `-pooler`).
3. Apply the schema:
   ```bash
   psql "postgres://…-pooler…/dbname?sslmode=require" -f db/schema.sql
   ```
   (Or paste `db/schema.sql` into the Neon SQL Editor.)

### 2. Deploy the API (Vercel)
1. Import this repo at <https://vercel.com/new>.
2. Add Environment Variables (see `.env.example`):
   - `DATABASE_URL` — the pooled Neon string
   - `JWT_SECRET` — any long random string
   - `ALLOWED_ORIGINS` — `https://mattdanusergrant.github.io`
3. Deploy. Note the resulting origin, e.g. `https://keeping-cadence.vercel.app`.

### 3. Turn on cloud in the client
In `index.html`, find the `CLOUD` config near the top of the script and set:
```js
const CLOUD = { enabled: true, apiBase: 'https://keeping-cadence.vercel.app' };
```
An **Account** button appears in the header; sign up, and edits sync to Neon and
follow you across devices. (Leaving `enabled: false` keeps the app fully local.)

### 4. Stripe (optional)
1. Create a subscription **Product → Price**; copy the price id (`price_…`).
2. In Vercel add: `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID`,
   `CHECKOUT_SUCCESS_URL`, `CHECKOUT_CANCEL_URL`.
3. Add a webhook at <https://dashboard.stripe.com/webhooks> pointing to
   `https://<your-api>/api/billing-webhook`, subscribed to
   `checkout.session.completed`, `customer.subscription.updated`,
   `customer.subscription.deleted`. Copy its signing secret into
   `STRIPE_WEBHOOK_SECRET`.

Billing endpoints return `503` until these are set, so the rest works without them.

### 5. Rename the GitHub repo (one-time)
To make `https://mattdanusergrant.github.io/keeping-cadence/` live:
1. GitHub → repo **Settings → General → Rename** to `keeping-cadence`.
2. **Settings → Pages** → confirm the branch/folder; the new URL appears.
3. GitHub auto-redirects the old `…/scheduler/` git remote, but update any
   bookmarks. The site card already points at the new URL.

## Verify (after provisioning)
This backend was authored without a live Neon/Vercel/Stripe to run against, so do
a first pass:
- [ ] `POST /api/auth?action=signup` returns `{ user, token }`
- [ ] With `CLOUD.enabled`, sign up → edit a day → reload on another device → it syncs
- [ ] `GET /api/share?slug=…` returns a schedule for a known slug
- [ ] A Stripe test checkout flips `subscriptions.status` to `active` via the webhook

## API reference
| Method & path | Auth | Body / query | Returns |
|---|---|---|---|
| `POST /api/auth?action=signup` | — | `{email,password}` | `{user,token}` |
| `POST /api/auth?action=login` | — | `{email,password}` | `{user,token}` |
| `GET /api/auth?action=me` | Bearer | — | `{user}` |
| `GET /api/state?week=YYYY-MM-DD` | Bearer | — | `{schedules,weeks,settings,subscription}` |
| `PUT /api/state` | Bearer | `{weekStart,schedules,settings}` | `{schedules:[{localId,id,slug}]}` |
| `GET /api/share?slug=…&from&to` | — | — | `{schedule,weeks}` |
| `POST /api/billing-checkout` | Bearer | — | `{url}` |
| `POST /api/billing-webhook` | Stripe sig | raw event | `{received:true}` |
