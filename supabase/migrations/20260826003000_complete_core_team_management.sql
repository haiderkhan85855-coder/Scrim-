begin;

revoke insert, update on table public.team_roster_members
  from authenticated;
revoke insert (team_id, pubg_uid, pubg_ign, display_name, role)
  on table public.team_roster_members from authenticated;
revoke update (pubg_uid, pubg_ign, display_name, role, status)
  on table public.team_roster_members from authenticated;

drop policy "Captains can add unclaimed roster members"
  on public.team_roster_members;
drop policy "Captains can manage non-captain roster members"
  on public.team_roster_members;

create function public.levelledup_validate_join_request_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if not exists (
    select 1
    from public.profiles
    where profiles.id = new.profile_id
      and nullif(btrim(profiles.display_name), '') is not null
      and nullif(btrim(profiles.pubg_ign), '') is not null
      and nullif(btrim(profiles.pubg_uid), '') is not null
  ) then
    raise exception 'Complete the player profile before requesting team membership.'
      using errcode = 'P3006';
  end if;

  return new;
end;
$$;

alter function public.levelledup_validate_join_request_profile()
  owner to postgres;

revoke all on function public.levelledup_validate_join_request_profile()
  from public, anon, authenticated;

create trigger team_join_requests_validate_profile
before insert on public.team_join_requests
for each row
execute function public.levelledup_validate_join_request_profile();

create function public.levelledup_get_pending_join_requests()
returns table (
  request_id uuid,
  team_id uuid,
  display_name text,
  pubg_ign text,
  pubg_uid text,
  requested_at timestamptz
)
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select
    team_join_requests.id,
    team_join_requests.team_id,
    profiles.display_name,
    profiles.pubg_ign,
    profiles.pubg_uid,
    team_join_requests.created_at
  from public.team_join_requests
  join public.profiles
    on profiles.id = team_join_requests.profile_id
  where team_join_requests.status = 'pending'
    and public.levelledup_is_active_team_captain(
      team_join_requests.team_id
    )
  order by team_join_requests.created_at;
$$;

alter function public.levelledup_get_pending_join_requests()
  owner to postgres;

revoke all on function public.levelledup_get_pending_join_requests()
  from public, anon, authenticated;
grant execute on function public.levelledup_get_pending_join_requests()
  to authenticated;

create function public.levelledup_reject_team_join_request(
  p_request_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  join_request public.team_join_requests;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to reject a join request.'
      using errcode = '42501';
  end if;

  select team_join_requests.*
  into join_request
  from public.team_join_requests
  where team_join_requests.id = p_request_id
  for update;

  if join_request.id is null or join_request.status <> 'pending' then
    raise exception 'Pending join request not found.'
      using errcode = 'P3005';
  end if;

  if not public.levelledup_is_active_team_captain(join_request.team_id) then
    raise exception 'Only the active team captain can reject this request.'
      using errcode = '42501';
  end if;

  update public.team_join_requests
  set
    status = 'rejected',
    reviewed_at = now(),
    reviewed_by = authenticated_user_id
  where id = join_request.id;

  return true;
end;
$$;

alter function public.levelledup_reject_team_join_request(uuid)
  owner to postgres;

revoke all on function public.levelledup_reject_team_join_request(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_reject_team_join_request(uuid)
  to authenticated;

create function public.levelledup_set_team_member_role(
  p_roster_member_id uuid,
  p_role text
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  roster_member public.team_roster_members;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to change a roster role.'
      using errcode = '42501';
  end if;

  if p_role not in ('member', 'substitute') then
    raise exception 'Role must be Player or Substitute.'
      using errcode = '22023';
  end if;

  select team_roster_members.*
  into roster_member
  from public.team_roster_members
  where team_roster_members.id = p_roster_member_id
  for update;

  if roster_member.id is null or roster_member.status <> 'active' then
    raise exception 'Active roster member not found.'
      using errcode = 'P3011';
  end if;

  if roster_member.role = 'captain' then
    raise exception 'The captain role cannot be changed here.'
      using errcode = 'P3012';
  end if;

  if not public.levelledup_is_active_team_captain(roster_member.team_id) then
    raise exception 'Only the active team captain can change member roles.'
      using errcode = '42501';
  end if;

  update public.team_roster_members
  set role = p_role
  where id = roster_member.id;

  return true;
end;
$$;

alter function public.levelledup_set_team_member_role(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_set_team_member_role(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_set_team_member_role(uuid, text)
  to authenticated;

create function public.levelledup_leave_team(p_team_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  roster_member public.team_roster_members;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to leave a team.'
      using errcode = '42501';
  end if;

  select team_roster_members.*
  into roster_member
  from public.team_roster_members
  where team_roster_members.team_id = p_team_id
    and team_roster_members.profile_id = authenticated_user_id
    and team_roster_members.status = 'active'
  for update;

  if roster_member.id is null then
    raise exception 'Active team membership not found.'
      using errcode = 'P3011';
  end if;

  if roster_member.role = 'captain' then
    raise exception 'Captains must transfer leadership or disband the team before leaving.'
      using errcode = 'P3010';
  end if;

  update public.team_roster_members
  set status = 'left'
  where id = roster_member.id;

  return true;
end;
$$;

alter function public.levelledup_leave_team(uuid)
  owner to postgres;

revoke all on function public.levelledup_leave_team(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_leave_team(uuid)
  to authenticated;

create function public.levelledup_remove_team_member(
  p_roster_member_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  roster_member public.team_roster_members;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to remove a roster member.'
      using errcode = '42501';
  end if;

  select team_roster_members.*
  into roster_member
  from public.team_roster_members
  where team_roster_members.id = p_roster_member_id
  for update;

  if roster_member.id is null or roster_member.status <> 'active' then
    raise exception 'Active roster member not found.'
      using errcode = 'P3011';
  end if;

  if roster_member.role = 'captain' then
    raise exception 'The captain cannot be removed from the roster.'
      using errcode = 'P3012';
  end if;

  if not public.levelledup_is_active_team_captain(roster_member.team_id) then
    raise exception 'Only the active team captain can remove roster members.'
      using errcode = '42501';
  end if;

  update public.team_roster_members
  set status = 'removed'
  where id = roster_member.id;

  return true;
end;
$$;

alter function public.levelledup_remove_team_member(uuid)
  owner to postgres;

revoke all on function public.levelledup_remove_team_member(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_remove_team_member(uuid)
  to authenticated;

commit;
