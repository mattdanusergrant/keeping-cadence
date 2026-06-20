-- Keeping Cadence — Neon-native schema (multi-team build, 2026-06-20)
--
-- Architecture: browser -> Neon Data API (PostgREST) using Neon Auth JWTs.
-- No custom server. Reads are direct table GETs guarded by RLS; writes go
-- through SECURITY DEFINER RPC functions (POST /rpc/<name>) that enforce the
-- teams rules and the plan-vs-actuals split.
--
-- Model: every account is equal — there is no manager/user role. An account can
-- OWN many teams (it created them) and JOIN many teams (by invite), at the same
-- time. A schedule belongs to a team; the team's owner authors the plan, and an
-- assigned member fills in actual hours.
--
-- Apply once (Neon SQL Editor or psql). Safe to re-run (idempotent-ish): it
-- drops the app tables first, so a clean rebuild. UNVERIFIED until run on live Neon.
--
-- auth.user_id() = signed-in user's id (JWT `sub`, text) = neon_auth.users_sync.id

create extension if not exists pgcrypto;  -- gen_random_uuid()

-- Clean rebuild: drop app tables (and the old single-team objects) first.
drop table if exists weeks, schedules, team_invites, team_members, teams, profiles cascade;

-- ===========================================================================
-- Tables (RLS on; SELECT via policy, writes via the RPCs below)
-- ===========================================================================

-- App data per Neon Auth user. No role — every account can own and join teams.
-- Email is denormalized here (set at init) so the client never needs
-- neon_auth.users_sync (which is updated asynchronously).
create table profiles (
  user_id     text primary key,            -- = auth.user_id()
  email       text,
  created_at  timestamptz not null default now()
);

-- A team, owned by its creator. An account can own many.
create table teams (
  id          uuid primary key default gen_random_uuid(),
  owner_id    text not null,
  name        text not null,
  created_at  timestamptz not null default now()
);
create index idx_teams_owner on teams(owner_id);

-- Membership (many-to-many: an account joins many teams). Email is denormalized
-- so an owner can show a roster without reading other profiles. The owner is the
-- team's owner (teams.owner_id) and is not stored as a member row.
create table team_members (
  team_id     uuid not null references teams(id) on delete cascade,
  user_id     text not null,
  email       text,
  created_at  timestamptz not null default now(),
  primary key (team_id, user_id)
);
create index idx_team_members_user on team_members(user_id);

-- A schedule "tab" belongs to a team. The team owner authors the plan; an
-- assigned member fills actual hours.
create table schedules (
  id                uuid primary key default gen_random_uuid(),
  team_id           uuid not null references teams(id) on delete cascade,
  assigned_user_id  text,
  name              text not null,
  color_var         text not null default 'accent',
  created_at        timestamptz not null default now()
);
create index idx_schedules_team     on schedules(team_id);
create index idx_schedules_assigned on schedules(assigned_user_id);

-- One row per (schedule, week). days jsonb = the client's 7-day array.
create table weeks (
  schedule_id  uuid not null references schedules(id) on delete cascade,
  week_start   date not null,
  days         jsonb not null,
  updated_at   timestamptz not null default now(),
  primary key (schedule_id, week_start)
);

-- Invite an email to a specific team; the invitee accepts to join it.
create table team_invites (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams(id) on delete cascade,
  email       text not null,
  status      text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at  timestamptz not null default now(),
  unique (team_id, email)
);
create index idx_invites_email on team_invites(email) where status = 'pending';

-- ===========================================================================
-- RLS helpers — SECURITY DEFINER so they bypass RLS on the tables they read,
-- which keeps the membership policies from recursing into each other.
-- ===========================================================================
create or replace function owned_team_ids()
returns setof uuid language sql security definer set search_path = public stable as $$
  select id from teams where owner_id = auth.user_id();
$$;

create or replace function my_team_ids()
returns setof uuid language sql security definer set search_path = public stable as $$
  select id from teams where owner_id = auth.user_id()
  union
  select team_id from team_members where user_id = auth.user_id();
$$;

alter table profiles      enable row level security;
alter table teams         enable row level security;
alter table team_members  enable row level security;
alter table schedules     enable row level security;
alter table weeks         enable row level security;
alter table team_invites  enable row level security;

create policy profiles_select on profiles for select to authenticated
  using ( user_id = auth.user_id() );

create policy teams_select on teams for select to authenticated
  using ( id in (select my_team_ids()) );

create policy team_members_select on team_members for select to authenticated
  using ( user_id = auth.user_id() or team_id in (select owned_team_ids()) );

create policy schedules_select on schedules for select to authenticated
  using ( assigned_user_id = auth.user_id() or team_id in (select owned_team_ids()) );

-- A week is visible iff its schedule is (schedules RLS already restricts that).
create policy weeks_select on weeks for select to authenticated
  using ( exists (select 1 from schedules s where s.id = weeks.schedule_id) );

create policy invites_select on team_invites for select to authenticated
  using ( team_id in (select owned_team_ids())
          or ( status = 'pending'
               and email = (select email from profiles where user_id = auth.user_id()) ) );

-- ===========================================================================
-- RPCs — all run SECURITY DEFINER and authorize via auth.user_id().
-- Exposed by the Data API as POST /rpc/<name> (JSON body uses these arg names).
-- ===========================================================================

-- Create your profile on first sign-in (idempotent). Also guarantees you own at
-- least one team — a personal default — so you always have a workspace.
create or replace function init_profile(p_email text)
returns profiles language plpgsql security definer set search_path = public as $$
  declare r profiles;
begin
  insert into profiles (user_id, email)
  values (auth.user_id(), lower(p_email))
  on conflict (user_id) do update set email = excluded.email;
  if not exists (select 1 from teams where owner_id = auth.user_id()) then
    insert into teams (owner_id, name)
    values (auth.user_id(), coalesce(nullif(split_part(lower(p_email), '@', 1), ''), 'My team'));
  end if;
  select * into r from profiles where user_id = auth.user_id();
  return r;
end $$;

-- Create a team you own.
create or replace function create_team(p_name text)
returns teams language plpgsql security definer set search_path = public as $$
  declare tm teams;
begin
  insert into teams (owner_id, name)
  values (auth.user_id(), coalesce(nullif(trim(p_name), ''), 'Team'))
  returning * into tm;
  return tm;
end $$;

-- Rename a team you own.
create or replace function rename_team(p_team_id uuid, p_name text)
returns teams language plpgsql security definer set search_path = public as $$
  declare tm teams;
begin
  update teams set name = coalesce(nullif(trim(p_name), ''), name)
    where id = p_team_id and owner_id = auth.user_id()
    returning * into tm;
  if tm is null then raise exception 'not your team'; end if;
  return tm;
end $$;

-- Delete a team you own (members, invites, schedules and weeks cascade away).
create or replace function delete_team(p_team_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from teams where id = p_team_id and owner_id = auth.user_id();
end $$;

-- Owner invites a person to one of their teams by email.
create or replace function invite_to_team(p_team_id uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from teams where id = p_team_id and owner_id = auth.user_id()) then
    raise exception 'not your team';
  end if;
  insert into team_invites (team_id, email) values (p_team_id, lower(p_email))
  on conflict (team_id, email) do update set status = 'pending', created_at = now();
end $$;

-- Invitee accepts -> joins that team.
create or replace function accept_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public as $$
  declare inv team_invites; my_email text;
begin
  select email into my_email from profiles where user_id = auth.user_id();
  select * into inv from team_invites
    where id = p_invite_id and email = my_email and status = 'pending';
  if inv is null then raise exception 'invite not found'; end if;
  insert into team_members (team_id, user_id, email)
    values (inv.team_id, auth.user_id(), my_email)
    on conflict (team_id, user_id) do update set email = excluded.email;
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

-- Create a schedule in a team you own; optionally assign it to a member.
create or replace function create_schedule(p_team_id uuid, p_name text, p_color text default 'accent',
                                           p_assigned_user_id text default null)
returns schedules language plpgsql security definer set search_path = public as $$
  declare s schedules; assignee text := null;
begin
  if not exists (select 1 from teams where id = p_team_id and owner_id = auth.user_id()) then
    raise exception 'not your team';
  end if;
  if p_assigned_user_id is not null then
    if not exists (select 1 from team_members where team_id = p_team_id and user_id = p_assigned_user_id) then
      raise exception 'assignee is not on this team';
    end if;
    assignee := p_assigned_user_id;
  end if;
  insert into schedules (team_id, assigned_user_id, name, color_var)
  values (p_team_id, assignee, coalesce(p_name, 'Schedule'), coalesce(p_color, 'accent'))
  returning * into s;
  return s;
end $$;

-- Rename / recolor / (re)assign a schedule in a team you own.
create or replace function update_schedule(p_schedule_id uuid, p_name text default null,
                                           p_color text default null,
                                           p_assigned_user_id text default null,
                                           p_clear_assignee boolean default false)
returns schedules language plpgsql security definer set search_path = public as $$
  declare s schedules; tid uuid;
begin
  select team_id into tid from schedules where id = p_schedule_id;
  if tid is null or not exists (select 1 from teams where id = tid and owner_id = auth.user_id()) then
    raise exception 'not your schedule';
  end if;
  if p_clear_assignee then
    update schedules set assigned_user_id = null where id = p_schedule_id;
  elsif p_assigned_user_id is not null then
    if not exists (select 1 from team_members where team_id = tid and user_id = p_assigned_user_id) then
      raise exception 'assignee is not on this team';
    end if;
    update schedules set assigned_user_id = p_assigned_user_id where id = p_schedule_id;
  end if;
  update schedules set name = coalesce(p_name, name), color_var = coalesce(p_color, color_var)
    where id = p_schedule_id;
  select * into s from schedules where id = p_schedule_id;
  return s;
end $$;

-- Team owner writes the plan; each day's actualHours is preserved.
create or replace function save_plan(p_schedule_id uuid, p_week_start date, p_days jsonb)
returns void language plpgsql security definer set search_path = public as $$
  declare existing jsonb; merged jsonb; has_assignee boolean; tid uuid; aid text;
begin
  select team_id, assigned_user_id into tid, aid from schedules where id = p_schedule_id;
  if tid is null or not exists (select 1 from teams where id = tid and owner_id = auth.user_id()) then
    raise exception 'not your schedule';
  end if;
  has_assignee := aid is not null;
  if has_assignee then
    -- a member owns the actuals, so carry over each day's existing actualHours
    select days into existing from weeks where schedule_id = p_schedule_id and week_start = p_week_start;
    select jsonb_agg(
             (p_days -> idx) || jsonb_build_object('actualHours',
               coalesce(existing -> idx ->> 'actualHours', p_days -> idx ->> 'actualHours', ''))
             order by idx)
      into merged
      from generate_series(0, jsonb_array_length(p_days) - 1) as t(idx);
  else
    merged := p_days;  -- no assignee: the owner controls both plan and actuals
  end if;
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

-- Delete a schedule in a team you own (its weeks cascade away via the FK).
create or replace function delete_schedule(p_schedule_id uuid)
returns void language plpgsql security definer set search_path = public as $$
  declare tid uuid;
begin
  select team_id into tid from schedules where id = p_schedule_id;
  if tid is not null and exists (select 1 from teams where id = tid and owner_id = auth.user_id()) then
    delete from schedules where id = p_schedule_id;
  end if;
end $$;

-- Owner removes a member from one of their teams: unassign that team's schedules
-- held by the member, then drop the membership.
create or replace function remove_member(p_team_id uuid, p_user_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from teams where id = p_team_id and owner_id = auth.user_id()) then
    raise exception 'not your team';
  end if;
  update schedules set assigned_user_id = null
    where team_id = p_team_id and assigned_user_id = p_user_id;
  delete from team_members where team_id = p_team_id and user_id = p_user_id;
end $$;

-- Member leaves a team: unassign any of that team's schedules assigned to them,
-- then drop their own membership.
create or replace function leave_team(p_team_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update schedules set assigned_user_id = null
    where team_id = p_team_id and assigned_user_id = auth.user_id();
  delete from team_members where team_id = p_team_id and user_id = auth.user_id();
end $$;

-- ===========================================================================
-- Grants for the Data API roles. Reads = SELECT (RLS-filtered); every write goes
-- through an RPC. The RLS-helper functions are EXECUTEd inside the policies.
-- ===========================================================================
grant usage on schema public to authenticated;
grant select on profiles, teams, team_members, schedules, weeks, team_invites to authenticated;
grant execute on function owned_team_ids(), my_team_ids() to authenticated;
grant execute on function
  init_profile(text),
  create_team(text),
  rename_team(uuid, text),
  delete_team(uuid),
  invite_to_team(uuid, text),
  accept_invite(uuid),
  decline_invite(uuid),
  create_schedule(uuid, text, text, text),
  update_schedule(uuid, text, text, text, boolean),
  save_plan(uuid, date, jsonb),
  save_actuals(uuid, date, jsonb),
  delete_schedule(uuid),
  remove_member(uuid, text),
  leave_team(uuid)
to authenticated;

notify pgrst, 'reload schema';
