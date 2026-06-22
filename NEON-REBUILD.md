# Keeping Cadence — Neon-native rebuild (history + gotchas)

Decision (2026-06-18): rebuild KC to **maximum Neon** on the free tier — browser →
Neon Data API (PostgREST) + Neon Auth, **no custom server** — replacing the
scrypt+JWT + Vercel-serverless design. Shipped and **verified live 2026-06-22**.
See **BACKEND.md** for the current architecture; this file keeps the history and
the two non-obvious things that cost the most debugging time.

## Status — DONE / live
- **DB layer** (`db/schema.sql`): `profiles`, `teams`, `team_members`, `schedules`,
  `weeks`, `team_invites` + RLS + `current_uid()` + public invoker wrappers + the
  `kc_private` SECURITY DEFINER workers + grants. Applied + verified on live Neon.
- **Client** (`app.html`): Neon Auth over REST (same-origin proxy), `/token` JWT
  with refresh-on-401, Data API reads, RPC writes; localStorage stays the offline
  cache. Many-to-many teams, invite links, plan-vs-actuals split.
- **Auth proxy** (`infra/neon-auth-proxy.js` + `vercel.json`): same-origin so the
  session cookie sticks on every browser.
- **Decommission** of the old serverless build: complete.

## Gotcha 1 — identity in SECURITY DEFINER returns NULL
The original schema called `auth.user_id()` inside `SECURITY DEFINER` RPCs and RLS
helpers. On this Neon project the JWT identity **only resolves while running as the
`authenticated` role** (RLS policies, `SECURITY INVOKER` functions). Inside a
`SECURITY DEFINER` function — running as the table owner — `auth.uid()` **and** the
`request.jwt.claims` GUC are both empty, so every write (and the RLS reads) saw a
NULL user and a fresh signup couldn't even create a profile.

**Fix:** read the id once in the invoker context via **`current_uid()`**
(`auth.uid()` with a `request.jwt.claims->>'sub'` fallback — needs no grant on the
`auth` schema), in thin `SECURITY INVOKER` wrappers, and pass it to the original
logic now in `SECURITY DEFINER` workers in the **unexposed `kc_private`** schema.
(`auth.uid()` is also the correct Neon accessor — the docs' `auth.user_id()` and a
manual `GRANT … ON SCHEMA auth` both proved insufficient/blocked here.)

## Gotcha 2 — the session cookie was cross-site (logout on refresh)
Neon Auth's HttpOnly session cookie is set by the `…neon.tech` host → third-party
to `app.keepingcadence.com`, so Safari ITP / Firefox ETP / iOS dropped it on
refresh. A same-site **subdomain** (`auth.keepingcadence.com`), with `SameSite=Lax`
and `Partitioned` stripped, *still* failed on iOS (WebKit won't persist a cookie
for a host never visited top-level).

**Fix:** proxy auth **same-origin** —
`app.keepingcadence.com/__neonauth` → (vercel.json rewrite) → Cloudflare Worker
(`auth.keepingcadence.com`) → Neon — so the cookie is set on the app's own origin.
The Worker also strips `x-forwarded-host` (Vercel adds it; Neon → `INVALID_HOSTNAME`).
**And** the client bug that masked it: `restoreSession()` only ran when a
localStorage token existed, but Neon returns no `set-auth-token`, so it *never*
ran — the cookie was never checked on reload. Now it always calls `/get-session`
(cookie-authenticated).

## Other notes
- **users_sync is async** (<1s): sidestepped by storing email in `profiles` at init
  (Better Auth's table is `neon_auth."user"`, not `users_sync`).
- **Email verification:** off = instant signup; turn on before a wider launch.
- **Open signups:** Neon Auth has no restricted-signup yet — anyone with the link
  can create an account (fine for a small private test).
