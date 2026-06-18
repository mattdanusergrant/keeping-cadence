# Keeping Cadence — Backend (Neon + serverless API)

The front-end (`index.html`) runs fully on its own. This backend is an optional
layer that adds **accounts (user + manager), teams, cross-device sync,
share-by-slug, and Stripe subscriptions**.

```
Browser (GitHub Pages)  ──HTTPS──>  Serverless API (/api on Vercel)  ──>  Neon Postgres
        index.html                    auth · state · team · share · billing    (private)
```

- The browser holds a signed session token (JWT) and sends it as
  `Authorization: Bearer …`. It never sees the database.
- The API (`/api/*.js`) holds `DATABASE_URL` as a server-side secret and
  enforces all access control in code (so we don't depend on Postgres RLS).

## Accounts & teams

Two account types, both **self-serve** (no app-admin step):

- **Manager** — signs up choosing the manager role, creates schedules, and
  invites users to their team by email. Sees and edits every team member's
  schedule (the plan), so the client can overlay them.
- **User** — signs up as a normal account, accepts a manager's invite, then
  sees the schedules assigned to them and fills in their **actual hours**.

The split is enforced server-side: the schedule **owner** (a manager, or a solo
user) edits the plan; the **assigned member** edits only `actualHours` — neither
can clobber the other. A user with no manager is just a solo account: the
original single-person flow, unchanged.

## Files

| Path | Purpose |
|---|---|
| `db/schema.sql` | Postgres schema (run once against Neon) — accounts, roles, teams, schedules, weeks, billing |
| `api/_lib.js` | Shared: Neon client, JWT, scrypt password hashing, CORS, `getUser` |
| `api/auth.js` | `signup` (as user or manager) / `login` / `me` |
| `api/state.js` | `GET`/`PUT` schedules, weeks, settings — role-aware (owner edits the plan, assigned member edits actual hours) |
| `api/team.js` | Manager ↔ user teams: invite, accept/decline, list members |
| `api/share.js` | Anonymous read of a schedule by share slug |
| `api/billing-checkout.js` | Create a Stripe Checkout subscription session |
| `api/billing-webhook.js` | Stripe webhook → maintains the `subscriptions` table |
| `.env.example` | The environment variables to set |

## Setup

### 1. Neon database
1. Create a **dedicated** Neon project for Keeping Cadence at <https://neon.tech> — its
   own project (not shared with Invisible Ink or other apps). KC uses a direct connection
   only, so **don't enable the Data API or Neon Auth** on it.
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
- [ ] Sign up as a **manager**, invite a user's email; that user sees the invite via
      `GET /api/team?action=invites`, accepts, and appears in `GET /api/team?action=team`
- [ ] Manager assigns a schedule to the user; the user can set `actualHours` but not the plan
- [ ] `GET /api/share?slug=…` returns a schedule for a known slug
- [ ] A Stripe test checkout flips `subscriptions.status` to `active` via the webhook

## API reference
| Method & path | Auth | Body / query | Returns |
|---|---|---|---|
| `POST /api/auth?action=signup` | — | `{email,password,role?}` | `{user,token}` |
| `POST /api/auth?action=login` | — | `{email,password}` | `{user,token}` |
| `GET /api/auth?action=me` | Bearer | — | `{user}` (incl. `role`, `managerId`) |
| `GET /api/state?week=YYYY-MM-DD` | Bearer | — | `{schedules,weeks,settings,subscription}` — each schedule carries `access` (`plan`\|`actuals`) + `assignedUserId` |
| `PUT /api/state` | Bearer | `{weekStart,schedules:[{…,assignedUserId?,days}],settings}` | `{schedules:[{localId,id,slug}]}` |
| `GET /api/team?action=team` | Bearer (manager) | — | `{users:[{id,email}]}` |
| `POST /api/team?action=invite` | Bearer (manager) | `{email}` | `{ok}` |
| `GET /api/team?action=invites` | Bearer (user) | — | `{invites:[{id,managerEmail}]}` |
| `POST /api/team?action=accept` | Bearer (user) | `{inviteId}` | `{ok,managerId}` |
| `POST /api/team?action=decline` | Bearer (user) | `{inviteId}` | `{ok}` |
| `GET /api/share?slug=…&from&to` | — | — | `{schedule,weeks}` |
| `POST /api/billing-checkout` | Bearer | — | `{url}` |
| `POST /api/billing-webhook` | Stripe sig | raw event | `{received:true}` |
