-- Fix 10: team rename history.
--
-- Haider's approved rule: preserve every old name; search by current or
-- former name; current display may show "Eagle Warriors (formerly eSports
-- Champions)"; historical tournaments show the name used at that tournament;
-- never overwrite or delete name history.

-- 1. Immutable name history. One open row (ended_at null) per team.
create table public.team_name_history (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams (id) on delete cascade,
  name text not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  changed_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint team_name_history_name_format check (
    name = btrim(name)
    and char_length(name) between 2 and 80
  ),
  constraint team_name_history_period_valid check (
    ended_at is null or ended_at > started_at
  )
);

comment on table public.team_name_history is
  'Append-only history of team display names. Never updated or deleted; a rename closes the open row and inserts a new one.';

create unique index team_name_history_open_unique
  on public.team_name_history (team_id)
  where ended_at is null;

create index team_name_history_name_search_idx
  on public.team_name_history (lower(name));

create index team_name_history_team_period_idx
  on public.team_name_history (team_id, started_at, ended_at);

alter table public.team_name_history enable row level security;

revoke all on table public.team_name_history from anon, authenticated;
grant select on table public.team_name_history to authenticated;

create policy "Authenticated users can read team name history"
  on public.team_name_history
  for select
  to authenticated
  using (true);

-- 2. Backfill: every current name becomes the first history row.
insert into public.team_name_history (team_id, name, started_at, ended_at, changed_by)
select id, name, created_at, null, created_by
from public.teams;

-- 3. Captain-only rename. Closes the open row, updates teams.name, opens a new row.
create function public.levelledup_rename_team(
  p_team_id uuid,
  p_new_name text
)
returns text
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  clean_name text := btrim(p_new_name);
  current_name text;
  now_ts timestamptz := now();
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to rename a team.'
      using errcode = '42501';
  end if;

  if p_team_id is null then
    raise exception 'A team is required to rename.'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('team-rename:' || p_team_id::text));

  select teams.name
  into current_name
  from public.teams
  where teams.id = p_team_id
  for update;

  if current_name is null then
    raise exception 'Team not found.'
      using errcode = 'P3004';
  end if;

  if not exists (
    select 1
    from public.team_roster_members
    where team_roster_members.team_id = p_team_id
      and team_roster_members.profile_id = authenticated_user_id
      and team_roster_members.status = 'active'
      and team_roster_members.role = 'captain'
  ) then
    raise exception 'Only the team Captain can rename the team.'
      using errcode = '42501';
  end if;

  if clean_name = '' or char_length(clean_name) < 2 or char_length(clean_name) > 80 then
    raise exception 'Team name must be between 2 and 80 characters.'
      using errcode = '22023';
  end if;

  if clean_name = current_name then
    raise exception 'That name is already the team''s current name.'
      using errcode = '22023';
  end if;

  update public.team_name_history
  set ended_at = now_ts
  where team_name_history.team_id = p_team_id
    and team_name_history.ended_at is null;

  update public.teams
  set name = clean_name,
      updated_at = now_ts
  where teams.id = p_team_id;

  insert into public.team_name_history (team_id, name, started_at, ended_at, changed_by)
  values (p_team_id, clean_name, now_ts, null, authenticated_user_id);

  return clean_name;
end;
$$;

alter function public.levelledup_rename_team(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_rename_team(uuid, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_rename_team(uuid, text)
  to authenticated;

comment on function public.levelledup_rename_team(uuid, text) is
  'Captain-only team rename. Preserves the old name in team_name_history; history is never overwritten or deleted.';

-- 4. Display helper: current name plus the most recent former name.
create function public.levelledup_get_team_name_display(p_team_id uuid)
returns table (
  name text,
  former_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    t.name,
    (
      select h.name
      from public.team_name_history as h
      where h.team_id = t.id
        and h.ended_at is not null
      order by h.ended_at desc
      limit 1
    )
  from public.teams as t
  where t.id = p_team_id;
$$;

alter function public.levelledup_get_team_name_display(uuid)
  owner to postgres;

revoke all on function public.levelledup_get_team_name_display(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_get_team_name_display(uuid)
  to authenticated;

-- 5. Historical name: the name covering a point in time (e.g. registration).
create function public.levelledup_team_name_at(
  p_team_id uuid,
  p_at timestamptz
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select h.name
  from public.team_name_history as h
  where h.team_id = p_team_id
    and h.started_at <= p_at
    and (h.ended_at is null or h.ended_at > p_at)
  order by h.started_at desc
  limit 1;
$$;

alter function public.levelledup_team_name_at(uuid, timestamptz)
  owner to postgres;

revoke all on function public.levelledup_team_name_at(uuid, timestamptz)
  from public, anon, authenticated;

grant execute on function public.levelledup_team_name_at(uuid, timestamptz)
  to authenticated;

comment on function public.levelledup_team_name_at(uuid, timestamptz) is
  'Returns the team name in effect at a given time, so historical tournaments show the name used at that tournament.';

-- 6. Team search across current and former names.
create function public.levelledup_search_teams(p_query text)
returns table (
  team_id uuid,
  team_code text,
  name text,
  former_name text,
  matched_name text
)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  pattern text := '%' || replace(replace(btrim(coalesce(p_query, '')), '%', '\%'), '_', '\_') || '%';
begin
  if char_length(btrim(coalesce(p_query, ''))) < 2 then
    raise exception 'Search needs at least 2 characters.'
      using errcode = '22023';
  end if;

  return query
  with matched as (
    select distinct h.team_id
    from public.team_name_history as h
    where h.name ilike pattern escape '\'
  )
  select
    t.id,
    t.team_id,
    t.name,
    (
      select h2.name
      from public.team_name_history as h2
      where h2.team_id = t.id
        and h2.ended_at is not null
      order by h2.ended_at desc
      limit 1
    ),
    (
      select h3.name
      from public.team_name_history as h3
      where h3.team_id = t.id
        and h3.name ilike pattern escape '\'
      order by h3.ended_at nulls first, h3.started_at desc
      limit 1
    )
  from public.teams as t
  join matched on matched.team_id = t.id
  order by t.name
  limit 25;
end;
$$;

alter function public.levelledup_search_teams(text)
  owner to postgres;

revoke all on function public.levelledup_search_teams(text)
  from public, anon, authenticated;

grant execute on function public.levelledup_search_teams(text)
  to authenticated;

comment on function public.levelledup_search_teams(text) is
  'Searches teams by current or former name. matched_name shows which name matched.';

-- 7. Admin bulk read: name each registration carried when it was made.
create function public.levelledup_admin_get_registration_team_names(
  p_tournament_id uuid
)
returns table (
  registration_id uuid,
  name_at_registration text,
  current_name text
)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  return query
  select
    reg.id,
    public.levelledup_team_name_at(reg.team_id, reg.registered_at),
    t.name
  from public.tournament_registrations as reg
  join public.teams as t on t.id = reg.team_id
  where reg.tournament_id = p_tournament_id;
end;
$$;

alter function public.levelledup_admin_get_registration_team_names(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_get_registration_team_names(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_get_registration_team_names(uuid)
  to authenticated;

comment on function public.levelledup_admin_get_registration_team_names(uuid) is
  'Per-registration team names as of registration time, so historical tournaments show the name used at that tournament.';
