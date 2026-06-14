-- Keeping Cadence — initial schema
-- Run this once in the Supabase SQL editor (or via `supabase db push`).
-- Assumes Supabase auth is enabled; uses auth.users for identity.

----------------------------------------------------------------------
-- Tables
----------------------------------------------------------------------

-- One row per scheduled person. The operator owns it; an optional
-- viewer (the person at the shared link) can be linked by email.
create table if not exists public.profiles (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references auth.users(id) on delete cascade,
  name            text not null,
  slug            text not null unique default encode(gen_random_bytes(9), 'base64'),
  color_var       text not null default 'accent',
  viewer_email    text,
  viewer_user_id  uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now()
);

-- One row per (profile, week). `days` carries the existing client
-- day structure (start/end/buffers/title/plan) verbatim.
create table if not exists public.weeks (
  id              uuid primary key default gen_random_uuid(),
  profile_id      uuid not null references public.profiles(id) on delete cascade,
  owner_id        uuid not null,
  week_start      date not null,
  days            jsonb not null,
  updated_at      timestamptz not null default now(),
  unique(profile_id, week_start)
);

-- Hours actually worked, kept separate so RLS can grant write
-- access to the viewer without exposing the scheduled times.
create table if not exists public.logged_hours (
  id              uuid primary key default gen_random_uuid(),
  profile_id      uuid not null references public.profiles(id) on delete cascade,
  week_start      date not null,
  day_index       int  not null check (day_index between 0 and 6),
  hours           numeric not null check (hours >= 0),
  logged_at       timestamptz not null default now(),
  unique(profile_id, week_start, day_index)
);

-- Per-operator settings (theme, mode, time ranges) so they persist
-- across devices once the user is signed in.
create table if not exists public.operator_settings (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  settings        jsonb not null default '{}'::jsonb,
  updated_at      timestamptz not null default now()
);

-- Stripe-backed subscription state; webhooks (service role) will
-- maintain this. Used to gate paid features in the client.
create table if not exists public.subscriptions (
  user_id                 uuid primary key references auth.users(id) on delete cascade,
  stripe_customer_id      text unique,
  stripe_subscription_id  text unique,
  status                  text,
  current_period_end      timestamptz,
  updated_at              timestamptz not null default now()
);

----------------------------------------------------------------------
-- Indexes
----------------------------------------------------------------------
create index if not exists idx_profiles_owner   on public.profiles(owner_id);
create index if not exists idx_profiles_viewer  on public.profiles(viewer_user_id);
create index if not exists idx_weeks_owner      on public.weeks(owner_id);
create index if not exists idx_weeks_profile_wk on public.weeks(profile_id, week_start);
create index if not exists idx_logged_profile_wk on public.logged_hours(profile_id, week_start);

----------------------------------------------------------------------
-- Row-level security
----------------------------------------------------------------------
alter table public.profiles          enable row level security;
alter table public.weeks             enable row level security;
alter table public.logged_hours      enable row level security;
alter table public.operator_settings enable row level security;
alter table public.subscriptions     enable row level security;

-- Profiles
create policy "operator manages own profiles"
  on public.profiles for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy "viewer reads linked profile"
  on public.profiles for select to authenticated
  using (viewer_user_id = auth.uid());

-- Weeks
create policy "operator manages own weeks"
  on public.weeks for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy "viewer reads weeks for linked profile"
  on public.weeks for select to authenticated
  using (exists (
    select 1 from public.profiles p
    where p.id = profile_id and p.viewer_user_id = auth.uid()
  ));

-- Logged hours
create policy "operator reads own logged hours"
  on public.logged_hours for select to authenticated
  using (exists (
    select 1 from public.profiles p
    where p.id = profile_id and p.owner_id = auth.uid()
  ));

create policy "viewer reads/writes own logged hours"
  on public.logged_hours for all to authenticated
  using (exists (
    select 1 from public.profiles p
    where p.id = profile_id and p.viewer_user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.profiles p
    where p.id = profile_id and p.viewer_user_id = auth.uid()
  ));

-- Operator settings
create policy "operator manages own settings"
  on public.operator_settings for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Subscriptions (read-only client side; webhook writes via service role)
create policy "operator reads own subscription"
  on public.subscriptions for select to authenticated
  using (user_id = auth.uid());

----------------------------------------------------------------------
-- RPC functions for the anonymous read-only viewer (share link)
----------------------------------------------------------------------

-- Resolve a slug to a minimal profile record (no auth required).
create or replace function public.get_public_profile(p_slug text)
returns table (id uuid, name text, color_var text)
language sql
security definer
set search_path = public
as $$
  select id, name, color_var
  from public.profiles
  where slug = p_slug
$$;

-- Fetch a range of weeks for a slug (no auth required).
create or replace function public.get_public_weeks(
  p_slug text, p_from date, p_to date
)
returns table (week_start date, days jsonb)
language sql
security definer
set search_path = public
as $$
  select w.week_start, w.days
  from public.weeks w
  join public.profiles p on p.id = w.profile_id
  where p.slug = p_slug
    and w.week_start between p_from and p_to
$$;

-- Link an authenticated viewer to a profile when their email matches
-- the operator-set viewer_email. Returns true on success.
create or replace function public.link_viewer_to_profile(p_slug text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
  v_count int;
begin
  select email into v_email from auth.users where id = auth.uid();
  if v_email is null then return false; end if;

  update public.profiles
    set viewer_user_id = auth.uid()
    where slug = p_slug
      and viewer_email is not distinct from v_email
      and (viewer_user_id is null or viewer_user_id = auth.uid());
  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$$;

grant execute on function public.get_public_profile(text)         to anon, authenticated;
grant execute on function public.get_public_weeks(text,date,date) to anon, authenticated;
grant execute on function public.link_viewer_to_profile(text)     to authenticated;
