-- Keeping Cadence — invite links (additive migration, 2026-06-20)
--
-- Adds shareable TEAM invite links: each team gets a secret `join_token`; the
-- owner can fetch/rotate it, and anyone signed in can join a team by token.
-- (The APP-level invite link is purely client-side — it just opens signup — so
-- it needs no schema.)
--
-- Apply on top of db/schema.sql (it's additive — no tables are dropped). Safe to
-- re-run. After running, the team-invite backend is live.

-- Each team carries a secret token used to build its invite link.
alter table teams add column if not exists join_token uuid not null default gen_random_uuid();

-- Keep the token secret: members may read a team's basic fields but NOT its
-- join_token (column-level grant). Owners fetch it through the RPC below.
revoke select on teams from authenticated;
grant select (id, owner_id, name, created_at) on teams to authenticated;

-- Owner: fetch this team's current invite token (to build a link).
create or replace function team_invite_link(p_team_id uuid)
returns text language plpgsql security definer set search_path = public as $$
  declare tok uuid;
begin
  select join_token into tok from teams where id = p_team_id and owner_id = auth.user_id();
  if tok is null then raise exception 'not your team'; end if;
  return tok::text;
end $$;

-- Owner: rotate the token, invalidating any links shared so far.
create or replace function regenerate_team_link(p_team_id uuid)
returns text language plpgsql security definer set search_path = public as $$
  declare tok uuid;
begin
  update teams set join_token = gen_random_uuid()
    where id = p_team_id and owner_id = auth.user_id()
    returning join_token into tok;
  if tok is null then raise exception 'not your team'; end if;
  return tok::text;
end $$;

-- Anyone signed in: join a team via its invite token (idempotent). Returns the
-- team's id + name only — never the token.
create or replace function join_by_token(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
  declare tm teams; my_email text;
begin
  select * into tm from teams where join_token = p_token;
  if tm is null then raise exception 'invalid or expired invite link'; end if;
  select email into my_email from profiles where user_id = auth.user_id();
  if tm.owner_id <> auth.user_id() then
    insert into team_members (team_id, user_id, email)
    values (tm.id, auth.user_id(), my_email)
    on conflict (team_id, user_id) do update set email = excluded.email;
  end if;
  return json_build_object('id', tm.id, 'name', tm.name, 'owner_id', tm.owner_id);
end $$;

grant execute on function
  team_invite_link(uuid), regenerate_team_link(uuid), join_by_token(uuid)
to authenticated;

notify pgrst, 'reload schema';
