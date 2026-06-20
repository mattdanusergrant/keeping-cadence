# Keeping Cadence — Backend (Neon, server-less)

The front-end (`app.html`) runs fully on its own. The cloud layer adds
**accounts, cross-device sync, and many-to-many teams** (any account can create
and join many teams, invite people, assign schedules, and split the plan from the
actual hours). It is **"max-Neon"**: the browser talks directly to Neon, with
**no custom server**.

```
Browser (static, on Vercel)
  ├── Neon Auth  (Better Auth)        login → bearer session token → short-lived JWT
  ├── Neon Data API (PostgREST)       reads: GET /schedules, /weeks, /profiles, /team_invites  (RLS-filtered)
  └── Postgres RPCs  (POST /rpc/*)     writes: SECURITY DEFINER functions, authorized via auth.user_id()
```

- The browser holds a **session token** (localStorage) from Neon Auth and
  exchanges it for a short-lived **Data API JWT** (`/token`, refreshed on 401).
- **Reads** go straight to tables through the Data API; **row-level security**
  decides what each user can see.
- **Writes** never touch tables directly — they go through a fixed set of
  **`SECURITY DEFINER` RPCs** that enforce the roles/teams rules and the
  plan-vs-actuals split.

> This replaced an earlier design (a Vercel `/api` serverless layer with
> scrypt+JWT auth). Those files (`api/*.js`, `vercel.json`, `package.json`) have
> been removed — there is no server to deploy anymore.

## Accounts & teams

There are **no roles**. Every account is equal and can both **own** teams (it
created them) and **join** teams (by invite) — many of each, at the same time.
`init_profile(p_email)` also guarantees you a personal default team.

- A **team** is owned by its creator and groups **schedules**. The owner authors
  the **plan** and assigns each schedule to a member; members see the schedules
  assigned to them and fill in **actual hours only**.
- "Role" is therefore **per-team and derived**: you are the *owner* of a team you
  created (author plans, invite, assign) and a *member* of a team you joined (log
  hours). The client tracks an **active team**; schedules belong to it, and a
  toolbar selector switches between teams.

The plan-vs-actuals split is enforced in Postgres: `save_plan` (team owner)
preserves a member's `actualHours`; `save_actuals` (assigned member) preserves
the plan. The client mirrors it (a member sees the plan read-only and edits only
hours; an owner sees logged hours read-only beside the plan). Anonymous,
account-free sharing still uses the client-side `#s=` hash link.

## Files

| Path | Purpose |
|---|---|
| `db/schema.sql` | The whole backend: `profiles`, `teams`, `team_members`, `schedules`, `weeks`, `team_invites` + RLS policies + the RPCs + Data API grants. A clean rebuild — drops the app tables first, then recreates them. Run once against the Neon project. |
| `app.html` | Front-end **and** the cloud client (the `CLOUD` block + the auth / Data API / RPC calls). |
| `NEON-REBUILD.md` | Architecture decision + build status (Phase 1 solo, Phase 2 teams). |

## Setup

### 1. Neon project
1. Create a **dedicated** Neon project for Keeping Cadence at <https://neon.tech>.
2. Enable **Neon Auth** and the **Data API** on it. Set the Neon Auth app /
   display name (and email sender) to **"Keeping Cadence"** so verification /
   reset emails are branded. Email/password is required; Google sign-in and email
   verification are optional toggles.
3. From the project's **Data API** and **Auth** pages, copy the two base URLs
   (they look like
   `https://<endpoint>.neonauth.<region>.aws.neon.tech/<db>/auth` and
   `https://<endpoint>.apirest.<region>.aws.neon.tech/<db>/rest/v1`).
4. Apply the schema — paste `db/schema.sql` into the Neon **SQL Editor**, or:
   ```bash
   psql "postgres://…/<db>?sslmode=require" -f db/schema.sql
   ```

### 2. Point the client at Neon
In `app.html`, the `CLOUD` block near the top of the script:
```js
const CLOUD = {
  enabled: true,
  authBase: 'https://<endpoint>.neonauth.<region>.aws.neon.tech/<db>/auth',
  dataApi:  'https://<endpoint>.apirest.<region>.aws.neon.tech/<db>/rest/v1',
};
```
These URLs are public — security is enforced by Neon Auth + RLS — so they live in
the file. Set `enabled: false` to ship the app fully local (no Account button).

### 3. Deploy the static site (Vercel)
Import the repo at <https://vercel.com/new> and deploy. No environment variables
or build step.

**Domains & routing (one project, two surfaces).** All three hostnames are added
to the same Vercel project (no redirects between them); `vercel.json` routes by
host:
- `app.keepingcadence.com` → the app (`app.html`)
- `keepingcadence.com` + `www.keepingcadence.com` → the marketing page (`landing.html`)

The app is **not** named `index.html` on purpose: Vercel serves a static file at
`/` *before* it evaluates `vercel.json` rewrites, so an `index.html` at the root
would be returned on every host and the host rules could never run. With no file
at `/`, the rewrites decide: marketing hosts get `landing.html`, and the final
catch-all (`/(.*)` → `/app.html`) serves the app for `app.` and every other host
(previews, `*.vercel.app`) — so a host-match miss can only fail to show the
landing, never break the app.

## RPC reference (POST `/rpc/<name>`, JSON body uses these arg names)
| Function | Who | Effect |
|---|---|---|
| `init_profile(p_email)` | any signed-in | Create your profile on first sign-in (idempotent); guarantees you own a personal default team. |
| `create_team(p_name)` · `rename_team(p_team_id, p_name)` · `delete_team(p_team_id)` | any · owner | Create a team you own; rename / delete one you own (delete cascades). |
| `invite_to_team(p_team_id, p_email)` | team owner | Invite someone to that team by email. |
| `accept_invite(p_invite_id)` / `decline_invite(p_invite_id)` | invitee | Join (adds a `team_members` row) / dismiss a pending invite. |
| `create_schedule(p_team_id, p_name, p_color?, p_assigned_user_id?)` | team owner | New schedule in that team. |
| `update_schedule(p_schedule_id, p_name?, p_color?, p_assigned_user_id?, p_clear_assignee?)` | team owner | Rename / recolor / (re)assign. |
| `delete_schedule(p_schedule_id)` | team owner | Delete (its weeks cascade). |
| `save_plan(p_schedule_id, p_week_start, p_days)` | team owner | Write the week's plan; preserves a member's `actualHours`. |
| `save_actuals(p_schedule_id, p_week_start, p_actuals)` | assigned member | Write only the week's actual hours; preserves the plan. |
| `remove_member(p_team_id, p_user_id)` / `leave_team(p_team_id)` | owner / member | Remove a member from your team / leave a team you joined. |

## Verify (against live Neon)
The schema + client logic are unit-tested, but do a first live pass after
provisioning:
- [ ] Sign up → `init_profile` returns your row and you get a personal default team; reload keeps you signed in.
- [ ] Create a schedule, edit a day, reload on another device → it syncs.
- [ ] Create a second team and switch between them (toolbar selector) → each shows its own schedules.
- [ ] Owner invites an email → that account sees the invite, accepts, joins the team, and appears in the roster.
- [ ] Owner assigns a schedule → the member sees it, can set actual hours but **not** the plan; the owner sees the logged hours.
- [ ] One account is owner of team A and member of team B at the same time.
- [ ] RLS: you cannot read schedules of a team you neither own nor were assigned in; each RPC rejects non-owners / non-assignees.

## Deferred
**Billing (Stripe).** Neon can't receive webhooks, so subscriptions would need
one small serverless function (the only server this design would ever add).
Deferred until the product is monetized.
