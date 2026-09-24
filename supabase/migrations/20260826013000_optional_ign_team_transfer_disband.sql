begin;

alter table public.team_roster_members
  drop constraint team_roster_members_pubg_ign_format;
alter table public.team_roster_members
  alter column pubg_ign drop not null;
alter table public.team_roster_members
  add constraint team_roster_members_pubg_ign_format check (
    pubg_ign is null
    or (
      pubg_ign = btrim(pubg_ign)
      and char_length(pubg_ign) between 1 and 32
    )
  );

alter table public.team_roster_members
  drop constraint team_roster_members_status_valid;
alter table public.team_roster_members
  add constraint team_roster_members_status_valid check (
    status in ('active', 'left', 'removed', 'disbanded')
  );

alter table public.teams
  add column status text not null default 'active',
  add column disbanded_at timestamptz,
  add column disbanded_by uuid references auth.users (id) on delete set null,
  add constraint teams_status_valid check (
    status in ('active', 'disbanded')
  ),
  add constraint teams_disband_state_valid check (
    (
      status = 'active'
      and disbanded_at is null
      and disbanded_by is null
    )
    or (
      status = 'disbanded'
      and disbanded_at is not null
    )
  );

create index teams_status_idx on public.teams (status);

comment on column public.teams.status is
  'Lifecycle state; disbanded teams remain permanently addressable for history.';

create or replace function public.levelledup_validate_join_request_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if not exists (
    select 1
    from public.teams
    where teams.id = new.team_id
      and teams.status = 'active'
  ) then
    raise exception 'The team is no longer active.'
      using errcode = 'P3020';
  end if;

  if not exists (
    select 1
    from public.profiles
    where profiles.id = new.profile_id
      and nullif(btrim(profiles.display_name), '') is not null
      and nullif(btrim(profiles.pubg_uid), '') is not null
  ) then
    raise exception 'Complete Display Name and PUBG UID before requesting team membership.'
      using errcode = 'P3006';
  end if;

  return new;
end;
$$;

alter function public.levelledup_validate_join_request_profile()
  owner to postgres;

revoke all on function public.levelledup_validate_join_request_profile()
  from public, anon, authenticated;

create or replace function public.levelledup_lookup_team_id(p_team_id text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_team_id text := upper(btrim(coalesce(p_team_id, '')));
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to look up a team.'
      using errcode = '42501';
  end if;

  if normalized_team_id !~ '^LU-[A-HJ-NP-Z2-9]{6}$' then
    return false;
  end if;

  return exists (
    select 1
    from public.teams
    where teams.team_id = normalized_team_id
      and teams.status = 'active'
  );
end;
$$;

alter function public.levelledup_lookup_team_id(text) owner to postgres;

revoke all on function public.levelledup_lookup_team_id(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_lookup_team_id(text)
  to authenticated;

create or replace function public.levelledup_create_team(
  p_name text,
  p_short_name text default null,
  p_logo_url text default null
)
returns public.teams
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_name text := nullif(btrim(p_name), '');
  normalized_short_name text := nullif(btrim(p_short_name), '');
  normalized_logo_url text := nullif(btrim(p_logo_url), '');
  captain_pubg_uid text;
  captain_pubg_ign text;
  captain_display_name text;
  active_team_count integer;
  created_team public.teams;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to create a team.'
      using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(authenticated_user_id::text, 0)
  );

  select count(distinct team_roster_members.team_id)::integer
  into active_team_count
  from public.team_roster_members
  where team_roster_members.profile_id = authenticated_user_id
    and team_roster_members.status = 'active';

  if active_team_count >= 3 then
    raise exception 'Maximum of 3 teams reached.'
      using errcode = 'P3001';
  end if;

  select
    nullif(btrim(profiles.pubg_uid), ''),
    nullif(btrim(profiles.pubg_ign), ''),
    nullif(btrim(profiles.display_name), '')
  into
    captain_pubg_uid,
    captain_pubg_ign,
    captain_display_name
  from public.profiles
  where profiles.id = authenticated_user_id;

  if captain_pubg_uid is null or captain_display_name is null then
    raise exception 'Complete Display Name and PUBG UID before creating a team.'
      using errcode = '22023';
  end if;

  if normalized_name is null or char_length(normalized_name) not between 2 and 80 then
    raise exception 'Team name must be between 2 and 80 characters.'
      using errcode = '22023';
  end if;

  if normalized_short_name is not null
    and char_length(normalized_short_name) not between 2 and 12 then
    raise exception 'Team short name must be between 2 and 12 characters.'
      using errcode = '22023';
  end if;

  if normalized_logo_url is not null
    and (
      char_length(normalized_logo_url) > 2048
      or normalized_logo_url !~* '^https?://[^[:space:]]+$'
    ) then
    raise exception 'Team logo URL must be a valid HTTP or HTTPS URL.'
      using errcode = '22023';
  end if;

  for generation_attempt in 1..10 loop
    begin
      insert into public.teams (name, short_name, logo_url, created_by)
      values (
        normalized_name,
        normalized_short_name,
        normalized_logo_url,
        authenticated_user_id
      )
      returning * into created_team;

      exit;
    exception
      when unique_violation then
        created_team := null;
    end;
  end loop;

  if created_team.id is null then
    raise exception 'Could not allocate a unique LevelledUp Team ID.'
      using errcode = '55000';
  end if;

  insert into public.team_roster_members (
    team_id,
    profile_id,
    pubg_uid,
    pubg_ign,
    display_name,
    role,
    status,
    linked_at,
    linked_by,
    created_by
  )
  values (
    created_team.id,
    authenticated_user_id,
    captain_pubg_uid,
    captain_pubg_ign,
    captain_display_name,
    'captain',
    'active',
    now(),
    authenticated_user_id,
    authenticated_user_id
  );

  return created_team;
end;
$$;

alter function public.levelledup_create_team(text, text, text)
  owner to postgres;

revoke all on function public.levelledup_create_team(text, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_create_team(text, text, text)
  to authenticated;

create or replace function public.levelledup_approve_team_join_request(
  p_request_id uuid,
  p_role text default 'member'
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  request_team_id uuid;
  join_request public.team_join_requests;
  applicant_pubg_uid text;
  applicant_pubg_ign text;
  applicant_display_name text;
  active_team_count integer;
  unclaimed_roster_id uuid;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to approve a join request.'
      using errcode = '42501';
  end if;

  if p_role not in ('member', 'substitute') then
    raise exception 'Approved role must be Player or Substitute.'
      using errcode = '22023';
  end if;

  select team_join_requests.team_id
  into request_team_id
  from public.team_join_requests
  where team_join_requests.id = p_request_id;

  if request_team_id is null then
    raise exception 'Pending join request not found.'
      using errcode = 'P3005';
  end if;

  perform 1
  from public.teams
  where teams.id = request_team_id
    and teams.status = 'active'
  for update;

  if not found then
    raise exception 'The team is no longer active.'
      using errcode = 'P3020';
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
    raise exception 'Only the active team captain can approve this request.'
      using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(join_request.profile_id::text, 0)
  );

  select count(distinct team_roster_members.team_id)::integer
  into active_team_count
  from public.team_roster_members
  where team_roster_members.profile_id = join_request.profile_id
    and team_roster_members.status = 'active';

  if active_team_count >= 3 then
    raise exception 'Maximum of 3 teams reached.'
      using errcode = 'P3001';
  end if;

  if exists (
    select 1
    from public.team_roster_members
    where team_roster_members.team_id = join_request.team_id
      and team_roster_members.profile_id = join_request.profile_id
      and team_roster_members.status = 'active'
  ) then
    raise exception 'This player already belongs to the team.'
      using errcode = 'P3002';
  end if;

  select
    nullif(btrim(profiles.pubg_uid), ''),
    nullif(btrim(profiles.pubg_ign), ''),
    nullif(btrim(profiles.display_name), '')
  into
    applicant_pubg_uid,
    applicant_pubg_ign,
    applicant_display_name
  from public.profiles
  where profiles.id = join_request.profile_id;

  if applicant_pubg_uid is null or applicant_display_name is null then
    raise exception 'The player must complete Display Name and PUBG UID before joining.'
      using errcode = 'P3006';
  end if;

  select team_roster_members.id
  into unclaimed_roster_id
  from public.team_roster_members
  where team_roster_members.team_id = join_request.team_id
    and team_roster_members.pubg_uid = applicant_pubg_uid
    and team_roster_members.profile_id is null
    and team_roster_members.status = 'active'
  for update;

  if unclaimed_roster_id is not null then
    update public.team_roster_members
    set
      profile_id = join_request.profile_id,
      pubg_ign = applicant_pubg_ign,
      display_name = applicant_display_name,
      linked_at = now(),
      linked_by = authenticated_user_id
    where id = unclaimed_roster_id;
  else
    begin
      insert into public.team_roster_members (
        team_id,
        profile_id,
        pubg_uid,
        pubg_ign,
        display_name,
        role,
        status,
        linked_at,
        linked_by,
        created_by
      )
      values (
        join_request.team_id,
        join_request.profile_id,
        applicant_pubg_uid,
        applicant_pubg_ign,
        applicant_display_name,
        p_role,
        'active',
        now(),
        authenticated_user_id,
        authenticated_user_id
      );
    exception
      when unique_violation then
        raise exception 'This player already occupies an active roster slot in the team.'
          using errcode = 'P3002';
    end;
  end if;

  update public.team_join_requests
  set
    status = 'approved',
    reviewed_at = now(),
    reviewed_by = authenticated_user_id
  where id = join_request.id;

  return true;
end;
$$;

alter function public.levelledup_approve_team_join_request(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_approve_team_join_request(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_approve_team_join_request(uuid, text)
  to authenticated;

create function public.levelledup_transfer_team_captaincy(
  p_team_id uuid,
  p_target_roster_member_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  current_captain_id uuid;
  target_member public.team_roster_members;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to transfer captaincy.'
      using errcode = '42501';
  end if;

  perform 1
  from public.teams
  where teams.id = p_team_id
    and teams.status = 'active'
  for update;

  if not found then
    raise exception 'The team is no longer active.'
      using errcode = 'P3020';
  end if;

  select team_roster_members.id
  into current_captain_id
  from public.team_roster_members
  where team_roster_members.team_id = p_team_id
    and team_roster_members.profile_id = authenticated_user_id
    and team_roster_members.role = 'captain'
    and team_roster_members.status = 'active'
  for update;

  if current_captain_id is null then
    raise exception 'Only the active captain can transfer leadership.'
      using errcode = '42501';
  end if;

  select team_roster_members.*
  into target_member
  from public.team_roster_members
  where team_roster_members.id = p_target_roster_member_id
    and team_roster_members.team_id = p_team_id
    and team_roster_members.profile_id is not null
    and team_roster_members.role in ('member', 'substitute')
    and team_roster_members.status = 'active'
  for update;

  if target_member.id is null then
    raise exception 'Select an active claimed Player or Substitute.'
      using errcode = 'P3021';
  end if;

  update public.team_roster_members
  set role = 'member'
  where id = current_captain_id;

  update public.team_roster_members
  set role = 'captain'
  where id = target_member.id;

  return true;
end;
$$;

alter function public.levelledup_transfer_team_captaincy(uuid, uuid)
  owner to postgres;

revoke all on function public.levelledup_transfer_team_captaincy(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_transfer_team_captaincy(uuid, uuid)
  to authenticated;

create function public.levelledup_disband_team(
  p_team_id uuid,
  p_confirmation_team_id text
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_team public.teams;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to disband a team.'
      using errcode = '42501';
  end if;

  select teams.*
  into selected_team
  from public.teams
  where teams.id = p_team_id
  for update;

  if selected_team.id is null or selected_team.status <> 'active' then
    raise exception 'The team is no longer active.'
      using errcode = 'P3020';
  end if;

  if not public.levelledup_is_active_team_captain(selected_team.id) then
    raise exception 'Only the active captain can disband this team.'
      using errcode = '42501';
  end if;

  if upper(btrim(coalesce(p_confirmation_team_id, ''))) <> selected_team.team_id then
    raise exception 'Team ID confirmation does not match.'
      using errcode = 'P3022';
  end if;

  update public.teams
  set
    status = 'disbanded',
    disbanded_at = now(),
    disbanded_by = authenticated_user_id
  where id = selected_team.id;

  update public.team_roster_members
  set status = 'disbanded'
  where team_id = selected_team.id
    and status = 'active';

  update public.team_join_requests
  set
    status = 'rejected',
    reviewed_at = now(),
    reviewed_by = authenticated_user_id
  where team_id = selected_team.id
    and status = 'pending';

  return true;
end;
$$;

alter function public.levelledup_disband_team(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_disband_team(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_disband_team(uuid, text)
  to authenticated;

commit;
