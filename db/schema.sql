-- Keeping Cadence — Neon-native schema (max-Neon build, 2026-06-18)
--
-- Architecture: browser -> Neon Data API (PostgREST) using Neon Auth JWTs.
-- No custom server. Reads are direct table GETs guarded by RLS; writes go
-- through SECURITY DEFINER RPC functions (POST /rpc/<name>) that enforce the
-- roles/teams rules and the plan-vs-actuals split.
--
-- Prerequisites on the Neon project: enable **Neon Auth** and the **Data API**.
-- Apply once (Neon SQL Editor or psql). UNVERIFIED until run against live Neon.
--
-- auth.user_id() = signed-in user's id (JWT `sub`, text) = neon_auth.users_sync.id

create extension if not exists pgcrypto;  -- gen_random_uuid()

-- ===========================================================================
-- Tables (RLS on; SELECT via policy, writes via the RPCs below)
-- ===========================================================================

-- App data per Neon Auth user: role + which manager they joined. Email is
-- denormalized here (set at init) so the client can list a team without
-- reading neon_auth.users_sync (which is updated asynchronously).
create table if not exists profiles (
  user_id     text primary key,            -- = auth.user_id()
  email       text,
  role        text not null default 'user' check (role in ('user','manager')),
  manager_id  text references profiles(user_id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table profiles enable row level security;
create policy profiles_select on profiles for select to authenticated
  using ( user_id = auth.user_id() or manager_id = auth.user_id() );

-- A schedule "tab". Owner authors the plan; assigned member fills actual hours.
create table if not exists schedules (
  id                uuid primary key default gen_random_uuid(),
  owner_id          text not null,
  assigned_user_id  text,
  name              text not null,
  color_var         text not null default 'accent',
  created_at        timestamptz not null default now()
);
alter table schedules enable row level security;
create policy schedules_select on schedules for select to authenticated
  using ( owner_id = auth.user_id() or assigned_user_id = auth.user_id() );
create index if not exists idx_schedules_owner    on schedules(owner_id);
create index if not exists idx_schedules_assigned on schedules(assigned_user_id);

-- One row per (schedule, week). days jsonb = the client's 7-day array.
create table if not exists weeks (
  schedule_id  uuid not null references schedules(id) on delete cascade,
  week_start   date not null,
  days         jsonb not null,
  updated_at   timestamptz not null default now(),
  primary key (schedule_id, week_start)
);
alter table weeks enable row level security;
create policy weeks_select on weeks for select to authenticated
  using ( exists ( select 1 from schedules s
                   where s.id = weeks.schedule_id
                     and ( s.owner_id = auth.user_id() or s.assigned_user_id = auth.user_id() ) ) );

-- Manager invites a user by email; the user accepts to set their manager_id.
create table if not exists team_invites (
  id          uuid primary key default gen_random_uuid(),
  manager_id  text not null,
  email       text not null,
  status      text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at  timestamptz not null default now(),
  unique (manager_id, email)
);
alter table team_invites enable row level security;
create policy invites_select on team_invites for select to authenticated
  using ( manager_id = auth.user_id()
          or ( status = 'pending'
               and email = (select email from profiles where user_id = auth.user_id()) ) );
create index if not exists idx_invites_email on team_invites(email) where status = 'pending';

-- ===========================================================================
-- RPCs — all run SECURITY DEFINER and authorize via auth.user_id().
-- Exposed by the Data API as POST /rpc/<name> (JSON body uses these arg names).
-- ===========================================================================

-- Create your profile on first sign-in (idempotent). Role is chosen at signup;
-- it is NOT changed on later calls (only email is refreshed).
create or replace function init_profile(p_email text, p_role text default 'user')
returns profiles language plpgsql security definer set search_path = public as $$
  declare r profiles;
begin
  insert into profiles (user_id, email, role)
  values (auth.user_id(), lower(p_email),
          case when p_role = 'manager' then 'manager' else 'user' end)
  on conflict (user_id) do update set email = excluded.email;
  select * into r from profiles where user_id = auth.user_id();
  return r;
end $$;

-- Manager invites a user by email.
create or replace function invite_to_team(p_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select role from profiles where user_id = auth.user_id()) <> 'manager' then
    raise exception 'managers only';
  end if;
  insert into team_invites (manager_id, email) values (auth.user_id(), lower(p_email))
  on conflict (manager_id, email) do update set status = 'pending', created_at = now();
end $$;

-- Invitee accepts -> joins the manager's team.
create or replace function accept_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public as $$
  declare inv team_invites; my_email text;
begin
  select email into my_email from profiles where user_id = auth.user_id();
  select * into inv from team_invites
    where id = p_invite_id and email = my_email and status = 'pending';
  if inv is null then raise exception 'invite not found'; end if;
  update profiles set manager_id = inv.manager_id where user_id = auth.user_id();
  update team_invites set status = 'accepted' where id = inv.id;
end $$;

create or replace function decline_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public as $$
  declare my_email text;
begin
  select email into my_email from profiles where user_id = auth.user_id();
  update team_invites set status = 'declined'
    where id = p_invite_id and email = my_email and status = 'pending';
end $$;

-- Create a schedule (owner = you); a manager may assign it to a team member.
create or replace function create_schedule(p_name text, p_color text default 'accent',
                                           p_assigned_user_id text default null)
returns schedules language plpgsql security definer set search_path = public as $$
  declare s schedules; assignee text := null;
begin
  if p_assigned_user_id is not null then
    if (select role from profiles where user_id = auth.user_id()) <> 'manager' then
      raise exception 'managers only can assign';
    end if;
    if (select manager_id from profiles where user_id = p_assigned_user_id)
         is distinct from auth.user_id() then
      raise exception 'assignee is not on your team';
    end if;
    assignee := p_assigned_user_id;
  end if;
  insert into schedules (owner_id, assigned_user_id, name, color_var)
  values (auth.user_id(), assignee, coalesce(p_name,'Schedule'), coalesce(p_color,'accent'))
  returning * into s;
  return s;
end $$;

-- Rename / recolor / (re)assign a schedule you own.
create or replace function update_schedule(p_schedule_id uuid, p_name text default null,
                                           p_color text default null,
                                           p_assigned_user_id text default null,
                                           p_clear_assignee boolean default false)
returns schedules language plpgsql security definer set search_path = public as $$
  declare s schedules;
begin
  if not exists (select 1 from schedules where id = p_schedule_id and owner_id = auth.user_id()) then
    raise exception 'not your schedule';
  end if;
  if p_clear_assignee then
    update schedules set assigned_user_id = null where id = p_schedule_id;
  elsif p_assigned_user_id is not null then
    if (select manager_id from profiles where user_id = p_assigned_user_id)
         is distinct from auth.user_id() then
      raise exception 'assignee is not on your team';
    end if;
    update schedules set assigned_user_id = p_assigned_user_id where id = p_schedule_id;
  end if;
  update schedules set name = coalesce(p_name, name), color_var = coalesce(p_color, color_var)
    where id = p_schedule_id;
  select * into s from schedules where id = p_schedule_id;
  return s;
end $$;

-- Owner writes the plan; each day's actualHours is preserved.
create or replace function save_plan(p_schedule_id uuid, p_week_start date, p_days jsonb)
returns void language plpgsql security definer set search_path = public as $$
  declare existing jsonb; merged jsonb;
begin
  if not exists (select 1 from schedules where id = p_schedule_id and owner_id = auth.user_id()) then
    raise exception 'not your schedule';
  end if;
  select days into existing from weeks where schedule_id = p_schedule_id and week_start = p_week_start;
  select jsonb_agg(
           (p_days -> idx) || jsonb_build_object('actualHours',
             coalesce(existing -> idx ->> 'actualHours', p_days -> idx ->> 'actualHours', ''))
           order by idx)
    into merged
    from generate_series(0, jsonb_array_length(p_days) - 1) as t(idx);
  insert into weeks (schedule_id, week_start, days, updated_at)
    values (p_schedule_id, p_week_start, merged, now())
    on conflict (schedule_id, week_start) do update set days = excluded.days, updated_at = now();
end $$;

-- Assigned member writes only actualHours; the plan is preserved.
create or replace function save_actuals(p_schedule_id uuid, p_week_start date, p_actuals jsonb)
returns void language plpgsql security definer set search_path = public as $$
  declare existing jsonb; merged jsonb;
begin
  if not exists (select 1 from schedules where id = p_schedule_id and assigned_user_id = auth.user_id()) then
    raise exception 'not assigned to you';
  end if;
  select days into existing from weeks where schedule_id = p_schedule_id and week_start = p_week_start;
  if existing is null then raise exception 'no plan for this week yet'; end if;
  select jsonb_agg(
           (existing -> idx) || jsonb_build_object('actualHours',
             coalesce(p_actuals ->> idx, existing -> idx ->> 'actualHours', ''))
           order by idx)
    into merged
    from generate_series(0, jsonb_array_length(existing) - 1) as t(idx);
  update weeks set days = merged, updated_at = now()
    where schedule_id = p_schedule_id and week_start = p_week_start;
end $$;

-- ===========================================================================
-- Grants for the Data API roles. Reads = SELECT (RLS-filtered); every write
-- goes through an RPC (no direct INSERT/UPDATE/DELETE granted to authenticated).
-- ===========================================================================
grant usage on schema public to authenticated;
grant select on profiles, schedules, weeks, team_invites to authenticated;
grant execute on all functions in schema public to authenticated;

notify pgrst, 'reload schema';
