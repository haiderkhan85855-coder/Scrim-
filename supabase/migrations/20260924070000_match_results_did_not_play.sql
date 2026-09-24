-- Fix 9: "Did Not Play" for no-show teams.
--
-- Haider's approved rule: record "Did Not Play", never zero; display greyed
-- out at the bottom; exclude that match from per-match averages; integrate
-- with the new result model.
--
-- A did_not_play row carries NULL placement/kills/points (never zero), so
-- SQL avg() over points naturally excludes no-show matches from per-match
-- averages. did_not_play results never expect player data.

-- 1. Column + nullability.
alter table public.match_results
  add column did_not_play boolean not null default false;

alter table public.match_results alter column placement drop not null;
alter table public.match_results alter column kills drop not null;
alter table public.match_results alter column placement_points drop not null;
alter table public.match_results alter column kill_points drop not null;
alter table public.match_results alter column total_points drop not null;

-- 2. Replace the old checks with a DNP-aware invariant.
alter table public.match_results
  drop constraint if exists match_results_placement_positive;
alter table public.match_results
  drop constraint if exists match_results_kills_nonnegative;
alter table public.match_results
  drop constraint if exists match_results_points_nonnegative;
alter table public.match_results
  drop constraint if exists match_results_points_sum_valid;

alter table public.match_results
  add constraint match_results_dnp_state_valid check (
    (
      did_not_play
      and placement is null
      and kills is null
      and placement_points is null
      and kill_points is null
      and total_points is null
    )
    or (
      not did_not_play
      and placement is not null
      and kills is not null
      and placement_points is not null
      and kill_points is not null
      and total_points is not null
      and placement >= 1
      and kills >= 0
      and placement_points >= 0
      and kill_points >= 0
      and total_points >= 0
      and total_points = placement_points + kill_points
    )
  );

comment on column public.match_results.did_not_play is
  'True when the team did not play the match. Recorded as Did Not Play, never zero: placement/kills/points stay NULL so per-match averages exclude the match.';

-- 3. Points trigger: skip calculation for Did Not Play rows.
create or replace function public.levelledup_calculate_match_result()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  match_tournament_id uuid;
  selected_match public.tournament_matches;
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
  calculated_placement_points numeric;
  points_per_kill numeric;
  calculated_kill_points numeric;
  calculated_total_points numeric;
begin
  if tg_op = 'UPDATE' then
    if old.status = 'final' then
      raise exception 'Finalized match results are immutable.'
        using errcode = 'P4201';
    end if;

    if new.tournament_id is distinct from old.tournament_id
      or new.tournament_match_id is distinct from old.tournament_match_id
      or new.tournament_registration_id is distinct from old.tournament_registration_id
      or new.entered_by is distinct from old.entered_by
      or new.created_at is distinct from old.created_at then
      raise exception 'Match result identity and entry provenance cannot be changed.'
        using errcode = '22023';
    end if;

    if new.status not in ('draft', 'final') then
      raise exception 'Invalid match result status transition.'
        using errcode = 'P4202';
    end if;
  elsif new.status <> 'draft' then
    raise exception 'A new match result must begin as a draft.'
      using errcode = 'P4202';
  end if;

  if new.did_not_play then
    -- Did Not Play: never zero. Keep every numeric field NULL so the row
    -- sorts last and per-match averages exclude it.
    new.placement := null;
    new.kills := null;
    new.placement_points := null;
    new.kill_points := null;
    new.total_points := null;
  else
    if new.placement is null or new.placement < 1 then
      raise exception 'Placement must be a positive integer.'
        using errcode = '22023';
    end if;

    if new.kills is null or new.kills < 0 then
      raise exception 'Kills cannot be negative.'
        using errcode = '22023';
    end if;
  end if;

  -- Read the parent identity first, then lock the tournament before its
  -- children. This matches the lock order used by tournament lifecycle work.
  select tournament_matches.tournament_id
  into match_tournament_id
  from public.tournament_matches
  where tournament_matches.id = new.tournament_match_id;

  if match_tournament_id is null then
    raise exception 'Tournament match not found.'
      using errcode = 'P4203';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = match_tournament_id
  for share;

  select tournament_matches.*
  into selected_match
  from public.tournament_matches
  where tournament_matches.id = new.tournament_match_id
  for share;

  select tournament_registrations.*
  into selected_registration
  from public.tournament_registrations
  where tournament_registrations.id = new.tournament_registration_id
  for share;

  if selected_match.id is null
    or selected_tournament.id is null
    or selected_match.tournament_id <> selected_tournament.id then
    raise exception 'Tournament match not found.'
      using errcode = 'P4203';
  end if;

  if selected_registration.id is null
    or selected_registration.tournament_id <> selected_tournament.id
    or new.tournament_id <> selected_tournament.id then
    raise exception 'The match and registration must belong to the same tournament.'
      using errcode = 'P4204';
  end if;

  if selected_registration.status <> 'confirmed' then
    raise exception 'Only a confirmed tournament registration can receive a result.'
      using errcode = 'P4205';
  end if;

  if selected_tournament.status <> 'live' then
    raise exception 'Results can be changed only while the tournament is live.'
      using errcode = 'P4206';
  end if;

  if selected_match.status not in ('live', 'completed') then
    if selected_match.status = 'cancelled' then
      raise exception 'Cancelled matches cannot receive results.'
        using errcode = 'P4206';
    end if;

    raise exception 'Results can be entered only after a match is live.'
      using errcode = 'P4206';
  end if;

  if new.status = 'final'
    and (
      new.finalized_by is null
      or new.finalized_at is null
    ) then
    raise exception 'Finalized results require finalization provenance.'
      using errcode = 'P4207';
  elsif new.status = 'draft' then
    new.finalized_by := null;
    new.finalized_at := null;
  end if;

  if new.did_not_play then
    return new;
  end if;

  calculated_placement_points := coalesce(
    (
      selected_tournament.scoring_config
        -> 'placement_points'
        ->> new.placement::text
    )::numeric,
    0
  );

  points_per_kill := (
    selected_tournament.scoring_config
      ->> 'kill_points_per_kill'
  )::numeric;

  calculated_kill_points := new.kills::numeric * points_per_kill;
  calculated_total_points :=
    calculated_placement_points + calculated_kill_points;

  if calculated_placement_points < 0
    or calculated_placement_points <> trunc(calculated_placement_points)
    or points_per_kill < 0
    or points_per_kill <> trunc(points_per_kill)
    or calculated_kill_points > 2147483647
    or calculated_total_points > 2147483647 then
    raise exception 'Tournament scoring configuration must produce nonnegative integer points.'
      using errcode = 'P4208';
  end if;

  new.placement_points := calculated_placement_points::integer;
  new.kill_points := calculated_kill_points::integer;
  new.total_points := calculated_total_points::integer;

  return new;
end;
$$;

-- 4. Inner upsert: accept a did_not_play flag.
drop function if exists public.levelledup_upsert_match_result(uuid, uuid, integer, integer);

create function public.levelledup_upsert_match_result(
  p_tournament_match_id uuid,
  p_tournament_registration_id uuid,
  p_placement integer,
  p_kills integer,
  p_did_not_play boolean default false
)
returns public.match_results
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_tournament_id uuid;
  saved_result public.match_results;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to enter match results.'
      using errcode = '42501';
  end if;

  select tournament_matches.tournament_id
  into selected_tournament_id
  from public.tournament_matches
  where tournament_matches.id = p_tournament_match_id;

  if selected_tournament_id is null then
    raise exception 'Tournament match not found.' using errcode = 'P4203';
  end if;

  insert into public.match_results (
    tournament_id,
    tournament_match_id,
    tournament_registration_id,
    placement,
    kills,
    placement_points,
    kill_points,
    total_points,
    did_not_play,
    status,
    entered_by
  )
  values (
    selected_tournament_id,
    p_tournament_match_id,
    p_tournament_registration_id,
    case when p_did_not_play then null else p_placement end,
    case when p_did_not_play then null else p_kills end,
    0,
    0,
    0,
    coalesce(p_did_not_play, false),
    'draft',
    authenticated_user_id
  )
  on conflict (tournament_match_id, tournament_registration_id)
  do update set
    placement = excluded.placement,
    kills = excluded.kills,
    did_not_play = excluded.did_not_play
  returning * into saved_result;

  return saved_result;
end;
$$;

alter function public.levelledup_upsert_match_result(uuid, uuid, integer, integer, boolean)
  owner to postgres;

revoke all on function public.levelledup_upsert_match_result(uuid, uuid, integer, integer, boolean)
  from public, anon, authenticated;

comment on function public.levelledup_upsert_match_result(uuid, uuid, integer, integer, boolean) is
  'Upserts one team result draft. p_did_not_play records Did Not Play with NULL numerics, never zero.';

-- 5. Admin bulk upsert: read did_not_play from each entry.
create or replace function public.levelledup_admin_upsert_match_results(
  p_match_id uuid,
  p_results jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  entry jsonb;
  saved_count integer := 0;
  registration_id uuid;
  placement integer;
  kills integer;
  did_not_play boolean;
begin
  perform public.levelledup_require_admin('admin');

  if p_match_id is null then
    raise exception 'A match is required to enter results.'
      using errcode = '22023';
  end if;

  if p_results is null or jsonb_typeof(p_results) <> 'array' then
    raise exception 'Results must be a JSON array.'
      using errcode = '22023';
  end if;

  for entry in select * from jsonb_array_elements(p_results) loop
    begin
      registration_id := (entry ->> 'registration_id')::uuid;
      placement := (entry ->> 'placement')::integer;
      kills := (entry ->> 'kills')::integer;
      did_not_play := coalesce((entry ->> 'did_not_play')::boolean, false);
    exception when others then
      raise exception 'Each result needs a valid registration_id, placement and kills, or did_not_play.'
        using errcode = '22023';
    end;

    if did_not_play then
      placement := null;
      kills := null;
    else
      if placement is null or placement < 1 then
        raise exception 'Placement must be at least 1.'
          using errcode = '22023';
      end if;

      if kills is null or kills < 0 then
        raise exception 'Kills cannot be negative.'
          using errcode = '22023';
      end if;
    end if;

    perform public.levelledup_upsert_match_result(
      p_match_id,
      registration_id,
      placement,
      kills,
      did_not_play
    );
    saved_count := saved_count + 1;
  end loop;

  return saved_count;
end;
$$;

-- 6. Admin read: expose did_not_play, sort DNP rows last.
drop function if exists public.levelledup_admin_get_match_results(uuid);

create function public.levelledup_admin_get_match_results(
  p_match_id uuid
)
returns table (
  result_id uuid,
  registration_id uuid,
  team_name text,
  team_code text,
  placement integer,
  kills integer,
  placement_points integer,
  kill_points integer,
  total_points integer,
  did_not_play boolean,
  status text,
  players jsonb
)
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  return query
  select
    r.id,
    r.tournament_registration_id,
    t.name,
    t.team_id,
    r.placement,
    r.kills,
    r.placement_points,
    r.kill_points,
    r.total_points,
    r.did_not_play,
    r.status,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', pr.id,
            'profile_id', pr.profile_id,
            'player_name', pr.player_name,
            'pubg_uid', pr.pubg_uid,
            'kills', pr.kills,
            'damage_dealt', pr.damage_dealt
          )
          order by pr.kills desc, pr.player_name
        )
        from public.match_player_results as pr
        where pr.match_result_id = r.id
      ),
      '[]'::jsonb
    ) as players
  from public.match_results as r
  join public.tournament_registrations as reg
    on reg.id = r.tournament_registration_id
  join public.teams as t
    on t.id = reg.team_id
  where r.tournament_match_id = p_match_id
  order by r.did_not_play, r.placement nulls last, t.name;
end;
$$;

alter function public.levelledup_admin_get_match_results(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_get_match_results(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_get_match_results(uuid)
  to authenticated;

-- 7. Did Not Play results never expect player data: exclude them from the
-- pending-player-data count.
create or replace function public.levelledup_admin_get_tournament_matches(
  p_tournament_id uuid
)
returns table (
  id uuid,
  lobby_id uuid,
  match_number integer,
  map_code text,
  map_display_name text,
  scheduled_start_at timestamptz,
  status text,
  completed_at timestamptz,
  result_count bigint,
  finalized_count bigint,
  players_pending_count bigint
)
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  return query
  select
    m.id,
    m.lobby_id,
    m.match_number,
    m.map_code,
    pm.display_name,
    m.scheduled_start_at,
    m.status,
    m.completed_at,
    count(distinct r.id) as result_count,
    count(distinct r.id) filter (where r.status = 'final') as finalized_count,
    count(distinct r.id) filter (
      where not r.did_not_play
        and not exists (
          select 1
          from public.match_player_results as pr
          where pr.match_result_id = r.id
        )
    ) as players_pending_count
  from public.tournament_matches as m
  join public.pubg_maps as pm on pm.code = m.map_code
  left join public.match_results as r on r.tournament_match_id = m.id
  where m.tournament_id = p_tournament_id
  group by m.id, m.lobby_id, m.match_number, m.map_code, pm.display_name,
           m.scheduled_start_at, m.status, m.completed_at
  order by m.lobby_id, m.match_number;
end;
$$;

alter function public.levelledup_admin_get_tournament_matches(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_get_tournament_matches(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_get_tournament_matches(uuid)
  to authenticated;
