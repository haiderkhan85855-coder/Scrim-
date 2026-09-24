begin;

do $$
begin
  if exists (
    select 1
    from public.team_roster_members
    where team_roster_members.profile_id is not null
      and team_roster_members.status = 'active'
    group by team_roster_members.profile_id
    having count(distinct team_roster_members.team_id) > 3
  ) then
    raise exception 'Existing roster data exceeds the maximum of 3 active teams per profile.';
  end if;
end;
$$;

create function public.levelledup_enforce_active_team_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  active_team_count integer;
begin
  if new.profile_id is null or new.status <> 'active' then
    return new;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.profile_id::text, 0)
  );

  select count(distinct team_roster_members.team_id)::integer
  into active_team_count
  from public.team_roster_members
  where team_roster_members.profile_id = new.profile_id
    and team_roster_members.status = 'active'
    and team_roster_members.id <> new.id;

  if active_team_count >= 3 then
    raise exception 'Maximum of 3 teams reached.'
      using errcode = 'P3001';
  end if;

  return new;
end;
$$;

alter function public.levelledup_enforce_active_team_limit()
  owner to postgres;

revoke all on function public.levelledup_enforce_active_team_limit()
  from public, anon, authenticated;

create trigger team_roster_members_enforce_active_team_limit
before insert or update of team_id, profile_id, status
on public.team_roster_members
for each row
execute function public.levelledup_enforce_active_team_limit();

create table public.team_join_requests (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending',
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint team_join_requests_status_valid check (
    status in ('pending', 'approved', 'rejected')
  ),
  constraint team_join_requests_review_state_valid check (
    (
      status = 'pending'
      and reviewed_at is null
      and reviewed_by is null
    )
    or (
      status <> 'pending'
      and reviewed_at is not null
    )
  )
);

comment on table public.team_join_requests is
  'Pending and reviewed requests to join persistent LevelledUp teams.';

create unique index team_join_requests_pending_team_profile_unique
  on public.team_join_requests (team_id, profile_id)
  where status = 'pending';

create index team_join_requests_team_status_created_idx
  on public.team_join_requests (team_id, status, created_at);

create index team_join_requests_profile_created_idx
  on public.team_join_requests (profile_id, created_at desc);

create function public.levelledup_set_join_request_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke execute on function public.levelledup_set_join_request_updated_at()
  from public, anon, authenticated;

create trigger team_join_requests_set_updated_at
before update on public.team_join_requests
for each row
execute function public.levelledup_set_join_request_updated_at();

alter table public.team_join_requests enable row level security;

revoke all on table public.team_join_requests from anon, authenticated;
grant select on table public.team_join_requests to authenticated;

create policy "Active captains can read their team join requests"
  on public.team_join_requests
  for select
  to authenticated
  using (public.levelledup_is_active_team_captain(team_id));

create function public.levelledup_request_team_join(p_team_id text)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_team_id text := upper(btrim(coalesce(p_team_id, '')));
  requested_team_id uuid;
  active_team_count integer;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to request team membership.'
      using errcode = '42501';
  end if;

  if normalized_team_id !~ '^LU-[A-HJ-NP-Z2-9]{6}$' then
    raise exception 'Team not found.'
      using errcode = 'P3004';
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

  select teams.id
  into requested_team_id
  from public.teams
  where teams.team_id = normalized_team_id;

  if requested_team_id is null then
    raise exception 'Team not found.'
      using errcode = 'P3004';
  end if;

  if exists (
    select 1
    from public.team_roster_members
    where team_roster_members.team_id = requested_team_id
      and team_roster_members.profile_id = authenticated_user_id
      and team_roster_members.status = 'active'
  ) then
    raise exception 'You already belong to this team.'
      using errcode = 'P3002';
  end if;

  if exists (
    select 1
    from public.team_join_requests
    where team_join_requests.team_id = requested_team_id
      and team_join_requests.profile_id = authenticated_user_id
      and team_join_requests.status = 'pending'
  ) then
    raise exception 'A join request is already pending for this team.'
      using errcode = 'P3003';
  end if;

  begin
    insert into public.team_join_requests (team_id, profile_id)
    values (requested_team_id, authenticated_user_id);
  exception
    when unique_violation then
      raise exception 'A join request is already pending for this team.'
        using errcode = 'P3003';
  end;

  return true;
end;
$$;

alter function public.levelledup_request_team_join(text)
  owner to postgres;

revoke all on function public.levelledup_request_team_join(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_request_team_join(text)
  to authenticated;

create function public.levelledup_approve_team_join_request(
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

  if applicant_pubg_uid is null
    or applicant_pubg_ign is null
    or applicant_display_name is null then
    raise exception 'The player must complete their profile before joining a team.'
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

  if captain_pubg_uid is null
    or captain_pubg_ign is null
    or captain_display_name is null then
    raise exception 'Complete your display name, PUBG IGN, and PUBG UID before creating a team.'
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
      insert into public.teams (
        name,
        short_name,
        logo_url,
        created_by
      )
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

commit;
