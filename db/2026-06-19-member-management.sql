-- Keeping Cadence — Phase 2 follow-up: member management (2026-06-19)
-- Adds two RPCs: a manager removing a member, and a member leaving their team.
-- Safe to paste into the Neon SQL Editor (all statements are re-runnable; no
-- table/policy creation, so unlike the full schema.sql this won't error on re-run).

-- Manager removes a member from their team: unassign any of the manager's
-- schedules held by that member, then detach them (manager_id -> null).
create or replace function remove_member(p_user_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select role from profiles where user_id = auth.user_id()) <> 'manager' then
    raise exception 'managers only';
  end if;
  if (select manager_id from profiles where user_id = p_user_id) is distinct from auth.user_id() then
    raise exception 'not your team member';
  end if;
  update schedules set assigned_user_id = null
    where owner_id = auth.user_id() and assigned_user_id = p_user_id;
  update profiles set manager_id = null
    where user_id = p_user_id and manager_id = auth.user_id();
end $$;

-- Member leaves their team: unassign any schedules assigned to them (so the
-- manager isn't left with a ghost assignee), then detach (manager_id -> null).
create or replace function leave_team()
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select manager_id from profiles where user_id = auth.user_id()) is null then
    return;  -- not on a team: no-op
  end if;
  update schedules set assigned_user_id = null where assigned_user_id = auth.user_id();
  update profiles set manager_id = null where user_id = auth.user_id();
end $$;

grant execute on function remove_member(text), leave_team() to authenticated;

notify pgrst, 'reload schema';
