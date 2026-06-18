-- Keeping Cadence — Neon (Postgres) schema
-- Run once against your Neon database:
--   psql "$DATABASE_URL" -f db/schema.sql
--
-- The API enforces access control in code (no RLS). The browser never
-- connects to Neon directly — only the serverless functions in /api do,
-- and they hold DATABASE_URL as a server-side secret.

create extension if not exists pgcrypto;  -- gen_random_uuid(), gen_random_bytes()

-- App-managed accounts. Passwords are hashed in the API (scrypt); only
-- the resulting hash is stored here.
create table if not exists users (
  id            uuid primary key default gen_random_uuid(),
  email         text not null unique,
  password_hash text not null,
  created_at    timestamptz not null default now()
);

-- One row per schedule (a "tab" in the client). The owner manages it; an
-- optional viewer (the person at the shared link) can be linked by email.
-- `slug` backs the anonymous read-only share link.
create table if not exists schedules (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references users(id) on delete cascade,
  name            text not null,
  color_var       text not null default 'accent',
  slug            text not null unique
                  default replace(replace(encode(gen_random_bytes(9), 'base64'), '/', '_'), '+', '-'),
  viewer_email    text,
  viewer_user_id  uuid references users(id) on delete set null,
  created_at      timestamptz not null default now()
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

create index if not exists idx_schedules_owner on schedules(owner_id);
create index if not exists idx_weeks_schedule   on weeks(schedule_id, week_start);
