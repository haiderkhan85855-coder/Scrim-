begin;

create table public.team_roster_members (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams (id) on delete cascade,
  profile_id uuid references public.profiles (id) on delete restrict,
  pubg_uid text not null,
  pubg_ign text not null,
  display_name text not null,
  role text not null,
  status text not null default 'active',
  linked_at timestamptz,
  linked_by uuid references auth.users (id) on delete set null,
  created_by uuid references auth.users (id) on delete set null
    default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint team_roster_members_pubg_uid_format check (
    pubg_uid = btrim(pubg_uid)
    and char_length(pubg_uid) between 1 and 32
  ),
  constraint team_roster_members_pubg_ign_format check (
    pubg_ign = btrim(pubg_ign)
    and char_length(pubg_ign) between 1 and 32
  ),
  constraint team_roster_members_display_name_format check (
    display_name = btrim(display_name)
    and char_length(display_name) between 1 and 80
  ),
  constraint team_roster_members_role_valid check (
    role in ('captain', 'member', 'substitute')
  ),
  constraint team_roster_members_status_valid check (
    status in ('active', 'left', 'removed')
  ),
  constraint team_roster_members_captain_linked check (
    role <> 'captain' or profile_id is not null
  ),
  constraint team_roster_members_link_state_valid check (
    (
      profile_id is null
      and linked_at is null
      and linked_by is null
    )
    or (
      profile_id is not null
      and linked_at is not null
    )
  )
);

comment on table public.team_roster_members is
  'Persistent team roster, including unclaimed PUBG players and linked LevelledUp profiles.';

comment on column public.team_roster_members.profile_id is
  'Nullable until a LevelledUp user securely claims this PUBG roster identity.';

comment on column public.team_roster_members.linked_by is
  'Auth user responsible for the trusted link operation; nullable if that Auth user is later deleted.';

create unique index team_roster_members_active_pubg_uid_unique
  on public.team_roster_members (pubg_uid)
  where status = 'active';

create unique index team_roster_members_active_profile_unique
  on public.team_roster_members (profile_id)
  where status = 'active' and profile_id is not null;

create unique index team_roster_members_active_captain_unique
  on public.team_roster_members (team_id)
  where status = 'active' and role = 'captain';

create index team_roster_members_team_status_idx
  on public.team_roster_members (team_id, status);

create index team_roster_members_profile_history_idx
  on public.team_roster_members (profile_id, created_at desc)
  where profile_id is not null;

create function public.levelledup_set_roster_member_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke execute on function public.levelledup_set_roster_member_updated_at()
  from public, anon, authenticated;

create trigger team_roster_members_set_updated_at
before update on public.team_roster_members
for each row
execute function public.levelledup_set_roster_member_updated_at();

create function public.levelledup_validate_roster_profile_link()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  linked_profile_pubg_uid text;
begin
  if tg_op = 'UPDATE'
    and old.profile_id is not null
    and (
      new.profile_id is distinct from old.profile_id
      or new.linked_at is distinct from old.linked_at
      or new.linked_by is distinct from old.linked_by
    ) then
    raise exception 'A linked roster identity cannot be reassigned.'
      using errcode = '22023';
  end if;

  if new.profile_id is null then
    return new;
  end if;

  select nullif(btrim(profiles.pubg_uid), '')
  into linked_profile_pubg_uid
  from public.profiles
  where profiles.id = new.profile_id;

  if linked_profile_pubg_uid is null then
    raise exception 'The linked profile must have a PUBG UID.'
      using errcode = '23514';
  end if;

  if new.pubg_uid is distinct from linked_profile_pubg_uid then
    raise exception 'Roster PUBG UID must match the linked profile PUBG UID.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function public.levelledup_validate_roster_profile_link()
  from public, anon, authenticated;

create trigger team_roster_members_validate_profile_link
before insert or update of profile_id, pubg_uid, linked_at, linked_by
on public.team_roster_members
for each row
execute function public.levelledup_validate_roster_profile_link();

create function public.levelledup_guard_active_roster_pubg_uid()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.pubg_uid is distinct from old.pubg_uid
    and exists (
      select 1
      from public.team_roster_members
      where team_roster_members.profile_id = old.id
        and team_roster_members.status = 'active'
    ) then
    raise exception 'End the active team membership before changing PUBG UID.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function public.levelledup_guard_active_roster_pubg_uid()
  from public, anon, authenticated;

create trigger profiles_guard_active_roster_pubg_uid
before update of pubg_uid on public.profiles
for each row
execute function public.levelledup_guard_active_roster_pubg_uid();

create function public.levelledup_is_active_team_member(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.team_roster_members
    where team_roster_members.team_id = p_team_id
      and team_roster_members.profile_id = auth.uid()
      and team_roster_members.status = 'active'
  );
$$;

revoke all on function public.levelledup_is_active_team_member(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_is_active_team_member(uuid)
  to authenticated;

create function public.levelledup_is_active_team_captain(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.team_roster_members
    where team_roster_members.team_id = p_team_id
      and team_roster_members.profile_id = auth.uid()
      and team_roster_members.role = 'captain'
      and team_roster_members.status = 'active'
  );
$$;

revoke all on function public.levelledup_is_active_team_captain(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_is_active_team_captain(uuid)
  to authenticated;

alter table public.team_roster_members enable row level security;

revoke all on table public.team_roster_members from anon, authenticated;
grant select on table public.team_roster_members to authenticated;
grant insert (team_id, pubg_uid, pubg_ign, display_name, role)
  on table public.team_roster_members to authenticated;
grant update (pubg_uid, pubg_ign, display_name, role, status)
  on table public.team_roster_members to authenticated;

create policy "Active team members can read their roster"
  on public.team_roster_members
  for select
  to authenticated
  using (public.levelledup_is_active_team_member(team_id));

create policy "Captains can add unclaimed roster members"
  on public.team_roster_members
  for insert
  to authenticated
  with check (
    public.levelledup_is_active_team_captain(team_id)
    and profile_id is null
    and role in ('member', 'substitute')
    and status = 'active'
    and created_by = (select auth.uid())
  );

create policy "Captains can manage non-captain roster members"
  on public.team_roster_members
  for update
  to authenticated
  using (
    role <> 'captain'
    and public.levelledup_is_active_team_captain(team_id)
  )
  with check (
    role <> 'captain'
    and public.levelledup_is_active_team_captain(team_id)
  );

grant update (name, short_name, logo_url) on table public.teams
  to authenticated;

create policy "Active captains can update their team"
  on public.teams
  for update
  to authenticated
  using (public.levelledup_is_active_team_captain(id))
  with check (public.levelledup_is_active_team_captain(id));

create function public.levelledup_create_team(
  p_name text,
  p_short_name text default null,
  p_logo_url text default null
)
returns public.teams
language plpgsql
security definer
set search_path = ''
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_name text := nullif(btrim(p_name), '');
  normalized_short_name text := nullif(btrim(p_short_name), '');
  normalized_logo_url text := nullif(btrim(p_logo_url), '');
  captain_pubg_uid text;
  captain_pubg_ign text;
  captain_display_name text;
  created_team public.teams;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to create a team.'
      using errcode = '42501';
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

  if exists (
    select 1
    from public.team_roster_members
    where team_roster_members.status = 'active'
      and (
        team_roster_members.profile_id = authenticated_user_id
        or team_roster_members.pubg_uid = captain_pubg_uid
      )
  ) then
    raise exception 'This player already belongs to an active team.'
      using errcode = '23505';
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

revoke all on function public.levelledup_create_team(text, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_create_team(text, text, text)
  to authenticated;

commit;
