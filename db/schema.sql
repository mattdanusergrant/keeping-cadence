-- Keeping Cadence — Neon (Postgres) schema
-- Run once against your Neon database:
--   psql "$DATABASE_URL" -f db/schema.sql
--
-- The API enforces access control in code (no RLS). The browser never
-- connects to Neon directly — only the serverless functions in /api do,
-- and they hold DATABASE_URL as a server-side secret.

create extension if not exists pgcrypto;  -- gen_random_uuid(), gen_random_bytes()

-- App-managed accounts. Passwords are hashed in the API (scrypt); only
-- the resulting hash is stored here. `role` is chosen at signup: a 'manager'
-- oversees a team of 'user' accounts; `manager_id` is the manager a user has
-- joined (null = solo / not on a team).
create table if not exists users (
  id            uuid primary key default gen_random_uuid(),
  email         text not null unique,
  password_hash text not null,
  role          text not null default 'user' check (role in ('user','manager')),
  manager_id    uuid references users(id) on delete set null,
  created_at    timestamptz not null default now()
);

-- One row per schedule (a "tab" in the client). `owner_id` is the author who
-- edits the plan (a manager, or a solo user); `assigned_user_id` is the team
-- member the schedule is for, who may fill in their actual hours. `slug` backs
-- the anonymous read-only share link.
create table if not exists schedules (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references users(id) on delete cascade,
  assigned_user_id  uuid references users(id) on delete set null,
  name              text not null,
  color_var         text not null default 'accent',
  slug              text not null unique
                    default replace(replace(encode(gen_random_bytes(9), 'base64'), '/', '_'), '+', '-'),
  created_at        timestamptz not null default now()
);

-- One row per (schedule, week). `days` carries the client's day array
-- verbatim (title/plan/start/end/buffers/actualHours).
create table if not exists weeks (
  id           uuid primary key default gen_random_uuid(),
  schedule_id  uuid not null references schedules(id) on delete cascade,
  week_start   date not null,
  days         jsonb not null,
  updated_at   timestamptz not null default now(),
  unique (schedule_id, week_start)
);

-- Per-user settings (theme, mode, time ranges) so they follow the account
-- across devices.
create table if not exists operator_settings (
  user_id     uuid primary key references users(id) on delete cascade,
  settings    jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- Stripe-backed subscription state; the billing webhook maintains this.
-- Read by the client to gate paid features.
create table if not exists subscriptions (
  user_id                 uuid primary key references users(id) on delete cascade,
  stripe_customer_id      text unique,
  stripe_subscription_id  text unique,
  status                  text,
  current_period_end      timestamptz,
  updated_at              timestamptz not null default now()
);

-- Pending team invitations. A manager invites a user by email; the user accepts
-- on their next visit, which sets their users.manager_id. App-managed (no email
-- is sent) — the invite simply appears for the matching signed-in account.
create table if not exists team_invites (
  id          uuid primary key default gen_random_uuid(),
  manager_id  uuid not null references users(id) on delete cascade,
  email       text not null,
  status      text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at  timestamptz not null default now(),
  unique (manager_id, email)
);

create index if not exists idx_users_manager     on users(manager_id);
create index if not exists idx_schedules_owner    on schedules(owner_id);
create index if not exists idx_schedules_assigned on schedules(assigned_user_id);
create index if not exists idx_weeks_schedule     on weeks(schedule_id, week_start);
create index if not exists idx_team_invites_email on team_invites(email) where status = 'pending';
