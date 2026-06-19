# Keeping Cadence — Neon-native rebuild

Decision (2026-06-18): rebuild KC to use **maximum Neon** (Databricks ecosystem) while
staying on the free tier. Browser -> Neon Data API (PostgREST) with Neon Auth; **no custom
server**. Replaces the scrypt+JWT + Vercel serverless design.

## Architecture
- **Login -> Neon Auth** (email/password + Google), called over REST from the single-file
  client (`POST {NEON_AUTH_URL}/auth/sign-in/email` -> JWT `access_token`). No build step.
- **Data -> Neon Data API + RLS** — the browser reads tables directly with the JWT.
- **Roles/teams + plan-vs-actuals -> Postgres RPC functions** (`/rpc/*`), SECURITY DEFINER,
  authorized via `auth.user_id()`.
- **No-account sharing -> the existing client-side hash link** (`#s=`); the server slug
  share is dropped.
- **Net:** browser -> Neon only. (Stripe, if added later, needs one tiny function — Neon
  cannot receive webhooks. Deferred.)

## Status
- [x] **DB layer** — `db/schema.sql`: profiles, schedules, weeks, team_invites + RLS +
      RPCs (init_profile, invite_to_team, accept_invite, decline_invite, create_schedule,
      update_schedule, save_plan, save_actuals). **UNVERIFIED until run on live Neon.**
- [ ] **Client rewrite** (`index.html`) — the big next chunk:
      - Account modal -> Neon Auth REST (sign-up/in; store `access_token`; refresh).
      - Role choice at signup -> `init_profile(p_email, p_role)`.
      - `cloudPull` -> Data API GETs (`/schedules`, `/weeks`, `/profiles` for the team).
      - `cloudPush`/saves -> RPC POSTs (`/rpc/save_plan`, `/rpc/save_actuals`, ...).
      - Manager UI: team panel (invite/accept), assign schedule, member actuals-only mode.
      - `CLOUD` config -> Data API base URL + Neon Auth base URL.
- [ ] **Verification pass** on live Neon (RLS + each RPC; confirm `auth.user_id()` + grants).
- [ ] **Decommission** old build: delete `api/*.js`, `vercel.json`; rewrite `BACKEND.md`.

## What I need from you
1. On the KC Neon project: **enable Neon Auth + the Data API** (set the Neon Auth app/
   display name to "Keeping Cadence").
2. Send me the **Data API base URL** and the **Neon Auth base URL** (from the project's
   Data API / Auth pages).
3. Apply `db/schema.sql` to the project (SQL Editor) when ready — or I can walk you through it.

## Open considerations
- **Unverified SQL:** RLS + RPCs need a live pass. `auth.user_id()` name + grants are from
  the docs but not yet run.
- **Token refresh:** Neon Auth access tokens expire; the client needs a refresh path (or a
  `credentials: 'include'` session). To design in the client step.
- **users_sync is async** (<1s): sidestepped by storing email in `profiles` at init.
- **Email sender:** set to "Keeping Cadence" in Neon Auth so verification/reset emails are
  not from "Many Doors".
- **Google sign-in / email verification:** optional toggles in Neon Auth; decide for testers.

## RPC signatures (POST /rpc/<name>, JSON body uses these arg names)
- `init_profile(p_email, p_role)`
- `invite_to_team(p_email)` · `accept_invite(p_invite_id)` · `decline_invite(p_invite_id)`
- `create_schedule(p_name, p_color, p_assigned_user_id)`
- `update_schedule(p_schedule_id, p_name, p_color, p_assigned_user_id, p_clear_assignee)`
- `save_plan(p_schedule_id, p_week_start, p_days)` · `save_actuals(p_schedule_id, p_week_start, p_actuals)`
