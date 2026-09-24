begin;

drop index public.team_roster_members_active_profile_unique;
drop index public.team_roster_members_active_pubg_uid_unique;

create unique index team_roster_members_active_team_profile_unique
  on public.team_roster_members (team_id, profile_id)
  where status = 'active' and profile_id is not null;

create unique index team_roster_members_active_team_pubg_uid_unique
  on public.team_roster_members (team_id, pubg_uid)
  where status = 'active';

comment on index public.team_roster_members_active_team_profile_unique is
  'Prevents one profile from occupying multiple active roster slots within the same team.';

comment on index public.team_roster_members_active_team_pubg_uid_unique is
  'Prevents one PUBG UID from occupying multiple active roster slots within the same team.';

create or replace function public.levelledup_create_team(
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
