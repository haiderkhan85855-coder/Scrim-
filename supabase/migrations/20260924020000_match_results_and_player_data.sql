-- Fix 3+4: match results attach to the right team, player data optional.
--
-- 1. WRONG-LOBBY GUARD (fix 3): a match result is rejected unless the team's
--    registration has an assignment row for the match's lobby. Assignment
--    history is preserved (released rows count), so a result stays valid even
--    if the team is later moved to another lobby.
-- 2. MATCH GENERATION: one admin call creates the lobby's matches from the
--    session's default_matches_per_lobby (or the lobby override).
-- 3. PLAYER RESULTS (fix 4): per-player rows attached to a team result.
--    Entering player data is optional and stays editable after finalization;
--    a result with no player rows counts as "players pending".
-- 4. ADMIN RPCs: upsert team results (draft), finalize results, complete a
--    match, upsert player rows, read matches + results for the admin UI.

-- ---------------------------------------------------------------------------
-- 1. Wrong-lobby guard on match_results
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_validate_match_result_lobby()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  match_lobby_id uuid;
begin
  select m.lobby_id
  into match_lobby_id
  from public.tournament_matches as m
  where m.id = new.tournament_match_id;

  if match_lobby_id is null then
    raise exception 'Tournament match not found.'
      using errcode = 'P4203';
  end if;

  -- The team must have played in this lobby. Released assignment rows are
  -- preserved history, so they count too: a result entered before a team
  -- was moved stays valid.
  if not exists (
    select 1
    from public.tournament_stage_assignments as a
    where a.registration_id = new.tournament_registration_id
      and a.lobby_id = match_lobby_id
  ) then
    raise exception 'Result rejected: this team is not assigned to the match lobby.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_validate_match_result_lobby()
  owner to postgres;

revoke all on function public.levelledup_validate_match_result_lobby()
  from public, anon, authenticated;

drop trigger if exists match_results_validate_lobby on public.match_results;
create trigger match_results_validate_lobby
before insert or update of tournament_match_id, tournament_registration_id
on public.match_results
for each row
execute function public.levelledup_validate_match_result_lobby();

comment on function public.levelledup_validate_match_result_lobby() is
  'Rejects a match result when the team registration was never assigned to the match lobby.';

-- ---------------------------------------------------------------------------
-- 2. Generate a lobby's matches from the session/lobby match configuration
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_admin_generate_lobby_matches(
  p_lobby_id uuid,
  p_map_rotation text[] default null
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_lobby record;
  selected_session record;
  selected_tournament record;
  match_count integer;
  configured_match_count bigint;
  map_rotation text[];
  map_index integer;
  created_count integer := 0;
  inserted_id uuid;
begin
  perform public.levelledup_require_admin('admin');

  if p_lobby_id is null then
    raise exception 'A lobby is required to generate matches.'
      using errcode = '22023';
  end if;

  select l.*
  into selected_lobby
  from public.tournament_lobbies as l
  where l.id = p_lobby_id;

  if selected_lobby.id is null then
    raise exception 'Tournament lobby not found.'
      using errcode = 'P4201';
  end if;

  if selected_lobby.session_id is null then
    raise exception 'This lobby has no session; matches cannot be generated.'
      using errcode = '22023';
  end if;

  select s.*
  into selected_session
  from public.tournament_stage_sessions as s
  where s.id = selected_lobby.session_id;

  select t.*
  into selected_tournament
  from public.tournaments as t
  where t.id = selected_lobby.tournament_id;

  match_count :=
    coalesce(selected_lobby.matches_per_lobby_override, selected_session.default_matches_per_lobby);

  if match_count is null or match_count < 1 then
    raise exception 'Set the number of matches for this lobby (or the session default) before generating matches.'
      using errcode = '22023';
  end if;

  configured_match_count :=
    selected_tournament.matches_per_day::bigint * selected_tournament.number_of_days::bigint;

  if match_count::bigint > configured_match_count then
    raise exception 'This lobby needs % matches but the tournament is configured for % (matches/day x days). Raise the tournament match configuration first.', match_count, configured_match_count
      using errcode = 'P4103';
  end if;

  if p_map_rotation is not null then
    if array_length(p_map_rotation, 1) is null then
      raise exception 'Map rotation must list at least one map.'
        using errcode = '22023';
    end if;
    if exists (
      select 1
      from unnest(p_map_rotation) as requested(code)
      where not exists (
        select 1 from public.pubg_maps as pm where pm.code = requested.code and pm.is_active
      )
    ) then
      raise exception 'Map rotation contains an unknown or inactive map.'
        using errcode = '22023';
    end if;
    map_rotation := p_map_rotation;
  else
    map_rotation := array['erangel'];
  end if;

  for map_index in 1 .. match_count loop
    insert into public.tournament_matches (
      tournament_id,
      stage_id,
      lobby_id,
      match_number,
      map_code,
      scheduled_start_at,
      status
    )
    values (
      selected_lobby.tournament_id,
      selected_lobby.stage_id,
      selected_lobby.id,
      map_index,
      map_rotation[((map_index - 1) % array_length(map_rotation, 1)) + 1],
      coalesce(selected_session.scheduled_start_at, selected_tournament.scheduled_start_at),
      'scheduled'
    )
    on conflict (lobby_id, match_number) do nothing
    returning id into inserted_id;

    if inserted_id is not null then
      created_count := created_count + 1;
    end if;
    inserted_id := null;
  end loop;

  return created_count;
end;
$$;

alter function public.levelledup_admin_generate_lobby_matches(uuid, text[])
  owner to postgres;

revoke all on function public.levelledup_admin_generate_lobby_matches(uuid, text[])
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_generate_lobby_matches(uuid, text[])
  to authenticated;

comment on function public.levelledup_admin_generate_lobby_matches(uuid, text[]) is
  'Admin-only: creates a lobby''s matches from the session default (or lobby override) match count. Idempotent per (lobby, match_number).';

-- ---------------------------------------------------------------------------
-- 3. Per-player result rows (fix 4)
-- ---------------------------------------------------------------------------

create table if not exists public.match_player_results (
  id uuid primary key default gen_random_uuid(),
  match_result_id uuid not null
    references public.match_results (id) on delete cascade,
  tournament_id uuid not null,
  profile_id uuid
    references public.profiles (id) on delete set null,
  player_name text not null,
  pubg_uid text,
  kills integer not null default 0,
  damage_dealt integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint match_player_results_name_valid check (
    player_name = btrim(player_name)
    and char_length(player_name) between 1 and 80
  ),
  constraint match_player_results_kills_nonnegative check (kills >= 0),
  constraint match_player_results_damage_nonnegative check (damage_dealt >= 0)
);

comment on table public.match_player_results is
  'Per-player rows for one team match result. Optional: a result with no player rows is "players pending".';

create unique index if not exists match_player_results_profile_unique_idx
  on public.match_player_results (match_result_id, profile_id)
  where profile_id is not null;

create unique index if not exists match_player_results_uid_unique_idx
  on public.match_player_results (match_result_id, pubg_uid)
  where pubg_uid is not null;

create index if not exists match_player_results_result_idx
  on public.match_player_results (match_result_id);

alter table public.match_player_results enable row level security;

create or replace function public.levelledup_set_match_player_result_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

alter function public.levelledup_set_match_player_result_updated_at()
  owner to postgres;

revoke all on function public.levelledup_set_match_player_result_updated_at()
  from public, anon, authenticated;

drop trigger if exists match_player_results_set_updated_at on public.match_player_results;
create trigger match_player_results_set_updated_at
before update on public.match_player_results
for each row
execute function public.levelledup_set_match_player_result_updated_at();

-- ---------------------------------------------------------------------------
-- 4. Admin RPCs: results, players, completion
-- ---------------------------------------------------------------------------

-- Batch upsert of draft team results for one match.
-- p_results: [{registration_id, placement, kills}, ...]
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
    exception when others then
      raise exception 'Each result needs a valid registration_id, placement and kills.'
        using errcode = '22023';
    end;

    if placement is null or placement < 1 then
      raise exception 'Placement must be at least 1.'
        using errcode = '22023';
    end if;

    if kills is null or kills < 0 then
      raise exception 'Kills cannot be negative.'
        using errcode = '22023';
    end if;

    perform public.levelledup_upsert_match_result(
      p_match_id,
      registration_id,
      placement,
      kills
    );
    saved_count := saved_count + 1;
  end loop;

  return saved_count;
end;
$$;

alter function public.levelledup_admin_upsert_match_results(uuid, jsonb)
  owner to postgres;

revoke all on function public.levelledup_admin_upsert_match_results(uuid, jsonb)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_upsert_match_results(uuid, jsonb)
  to authenticated;

-- Replace the player rows for one team result. Empty array clears them.
-- p_players: [{profile_id?, player_name, pubg_uid?, kills, damage_dealt?}, ...]
create or replace function public.levelledup_admin_upsert_match_player_results(
  p_match_result_id uuid,
  p_players jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_result record;
  entry jsonb;
  saved_count integer := 0;
  profile_id uuid;
  player_name text;
  pubg_uid text;
  kills integer;
  damage_dealt integer;
begin
  perform public.levelledup_require_admin('admin');

  if p_match_result_id is null then
    raise exception 'A match result is required to enter player data.'
      using errcode = '22023';
  end if;

  select r.*
  into selected_result
  from public.match_results as r
  where r.id = p_match_result_id;

  if selected_result.id is null then
    raise exception 'Match result not found.'
      using errcode = 'P4211';
  end if;

  if p_players is null or jsonb_typeof(p_players) <> 'array' then
    raise exception 'Players must be a JSON array.'
      using errcode = '22023';
  end if;

  delete from public.match_player_results
  where match_player_results.match_result_id = p_match_result_id;

  for entry in select * from jsonb_array_elements(p_players) loop
    player_name := btrim(entry ->> 'player_name');
    pubg_uid := nullif(btrim(entry ->> 'pubg_uid'), '');

    if player_name is null or char_length(player_name) = 0 then
      raise exception 'Each player needs a name.'
        using errcode = '22023';
    end if;

    begin
      profile_id := nullif(entry ->> 'profile_id', '')::uuid;
    exception when others then
      raise exception 'profile_id must be a valid UUID when supplied.'
        using errcode = '22023';
    end;

    begin
      kills := coalesce((entry ->> 'kills')::integer, 0);
      damage_dealt := coalesce((entry ->> 'damage_dealt')::integer, 0);
    exception when others then
      raise exception 'Kills and damage must be whole numbers.'
        using errcode = '22023';
    end;

    if kills < 0 or damage_dealt < 0 then
      raise exception 'Kills and damage cannot be negative.'
        using errcode = '22023';
    end if;

    insert into public.match_player_results (
      match_result_id,
      tournament_id,
      profile_id,
      player_name,
      pubg_uid,
      kills,
      damage_dealt
    )
    values (
      p_match_result_id,
      selected_result.tournament_id,
      profile_id,
      player_name,
      pubg_uid,
      kills,
      damage_dealt
    );

    saved_count := saved_count + 1;
  end loop;

  return saved_count;
end;
$$;

alter function public.levelledup_admin_upsert_match_player_results(uuid, jsonb)
  owner to postgres;

revoke all on function public.levelledup_admin_upsert_match_player_results(uuid, jsonb)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_upsert_match_player_results(uuid, jsonb)
  to authenticated;

-- Admin finalize wrapper (adds the admin check to the existing finalizer).
create or replace function public.levelledup_admin_finalize_match_result(
  p_match_result_id uuid
)
returns public.match_results
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  saved_result public.match_results;
begin
  perform public.levelledup_require_admin('admin');
  select * into saved_result
  from public.levelledup_finalize_match_result(p_match_result_id);
  return saved_result;
end;
$$;

alter function public.levelledup_admin_finalize_match_result(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_finalize_match_result(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_finalize_match_result(uuid)
  to authenticated;

-- Mark a match completed. The existing guard refuses while draft results remain.
create or replace function public.levelledup_admin_complete_match(
  p_match_id uuid
)
returns public.tournament_matches
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  saved_match public.tournament_matches;
begin
  perform public.levelledup_require_admin('admin');

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  update public.tournament_matches
  set status = 'completed',
      completed_at = now()
  where id = p_match_id
    and status <> 'completed'
  returning * into saved_match;

  if saved_match.id is null then
    raise exception 'Match not found or already completed.'
      using errcode = 'P4203';
  end if;

  return saved_match;
end;
$$;

alter function public.levelledup_admin_complete_match(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_complete_match(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_complete_match(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Admin read RPCs for the result-entry UI
-- ---------------------------------------------------------------------------

-- All matches of a tournament (for the admin result-entry board).
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
      where not exists (
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

-- Matches of one lobby with result/player coverage counts.
create or replace function public.levelledup_admin_get_lobby_matches(
  p_lobby_id uuid
)
returns table (
  id uuid,
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
    m.match_number,
    m.map_code,
    pm.display_name,
    m.scheduled_start_at,
    m.status,
    m.completed_at,
    count(distinct r.id) as result_count,
    count(distinct r.id) filter (where r.status = 'final') as finalized_count,
    count(distinct r.id) filter (
      where not exists (
        select 1
        from public.match_player_results as pr
        where pr.match_result_id = r.id
      )
    ) as players_pending_count
  from public.tournament_matches as m
  join public.pubg_maps as pm on pm.code = m.map_code
  left join public.match_results as r on r.tournament_match_id = m.id
  where m.lobby_id = p_lobby_id
  group by m.id, m.match_number, m.map_code, pm.display_name,
           m.scheduled_start_at, m.status, m.completed_at
  order by m.match_number;
end;
$$;

alter function public.levelledup_admin_get_lobby_matches(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_get_lobby_matches(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_get_lobby_matches(uuid)
  to authenticated;

-- Team results of one match with their player rows as JSON.
-- Re-run guard: a later migration (070000, Did Not Play) installs a NEWER
-- shape of this function with an extra did_not_play column. Install this base
-- version only when no version exists yet: never downgrade the newer shape,
-- and never fail a re-run with "cannot change return type".
do $$
begin
  if to_regprocedure('public.levelledup_admin_get_match_results(uuid)') is null then
    execute $func$
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
      status text,
      players jsonb
    )
    language plpgsql
    security definer
    set search_path = ''
    set row_security = off
    as $body$
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
      order by r.placement;
    end;
    $body$;
    $func$;
  end if;
end
$$;

alter function public.levelledup_admin_get_match_results(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_get_match_results(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_get_match_results(uuid)
  to authenticated;

-- Tournament-wide pending player-data count for the pending tasks bar.
create or replace function public.levelledup_admin_get_pending_player_results(
  p_tournament_id uuid
)
returns table (
  pending_count bigint
)
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  return query
  select count(*) as pending_count
  from public.match_results as r
  where r.tournament_id = p_tournament_id
    and not exists (
      select 1
      from public.match_player_results as pr
      where pr.match_result_id = r.id
    );
end;
$$;

alter function public.levelledup_admin_get_pending_player_results(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_get_pending_player_results(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_get_pending_player_results(uuid)
  to authenticated;
