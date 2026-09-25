-- Scrims — lobby session-start block (2026-09-24)
--
-- Haider's rules (his words):
--  1. "we cannot create the lobby when the matches of that session has already started"
--  2. "as the first match start no new team can join the team or lobby, they will play the next day matches"
--  3. "we can edit the lobby and adjust few things" (rename/resize stay open)
--  4. "lobby can be dlted if its empty" — delete-anyway confirmed: an empty lobby
--     (no matches, no assigned teams) can be deleted at any time.
--  5. "Stages stay OPEN after tournament start" — creating lobbies in future
--     sessions of an already-started tournament stays allowed.
--
-- What changed vs 20260924010000:
--  - levelledup_admin_create_session_lobby: the old tournament.scheduled_start_at
--    hard block is replaced by a session-scoped block. It fires when any match
--    in THAT session has status 'live' or 'completed'.
--  - levelledup_admin_delete_tournament_lobby: the tournament-start block is
--    removed entirely. The empty-only protection (no matches, no assigned
--    teams) still lives in the trigger and keeps applying.
--  - levelledup_admin_generate_session_lobbies calls the create function per
--    lobby, so bulk generation inherits the session block automatically.
--
-- Edge cases:
--  - 'cancelled' matches do not count as started. A 'scheduled' match whose
--    time passed but which was never marked live does not block (status is
--    the source of truth).
--  - scheduled_start_at NULL behaves as before (no tournament-level block).

begin;

-- ---------------------------------------------------------------------------
-- 1. Session-first lobby creation: session-scoped start block
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_admin_create_session_lobby(
  p_session_id uuid,
  p_capacity integer default null
)
returns public.tournament_lobbies
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_session public.tournament_stage_sessions;
  selected_tournament public.tournaments;
  created_lobby public.tournament_lobbies;
  lobby_count integer;
  next_order integer;
  next_code text;
  selected_capacity integer;
begin
  perform public.levelledup_require_admin('admin');

  select sessions.*
  into selected_session
  from public.tournament_stage_sessions as sessions
  where sessions.id = p_session_id
  for update of sessions;

  if selected_session.id is null then
    raise exception 'Tournament session not found.' using errcode = 'P4414';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_session.tournament_id
  for update of tournaments;

  -- Session-scoped start block (Haider): once any match in THIS session has
  -- started (live/completed), no new lobby here — new teams play the next
  -- session. A started tournament alone never blocks future sessions.
  if exists (
    select 1
    from public.tournament_matches as matches
    join public.tournament_lobbies as lobbies
      on lobbies.id = matches.lobby_id
    where lobbies.session_id = selected_session.id
      and matches.status in ('live', 'completed')
  ) then
    raise exception 'Cannot create lobby: this session''s matches have already started. New teams will play the next session.'
      using errcode = 'P4406';
  end if;

  select count(*)::integer, coalesce(max(lobby_order), 0) + 1
  into lobby_count, next_order
  from public.tournament_lobbies
  where session_id = selected_session.id;

  if lobby_count >= selected_tournament.max_lobbies then
    raise exception 'The session has reached its configured lobby limit.'
      using errcode = 'P4005';
  end if;

  selected_capacity := coalesce(p_capacity, selected_tournament.default_lobby_capacity);
  if selected_capacity < 1 or selected_capacity > 100 then
    raise exception 'Lobby capacity must be between 1 and 100.' using errcode = 'P4412';
  end if;

  next_code := case
    when next_order <= 26 then chr(64 + next_order)
    else 'L' || next_order::text
  end;

  insert into public.tournament_lobbies (
    tournament_id, stage_id, session_id,
    lobby_code, display_label, lobby_order, capacity, status
  ) values (
    selected_tournament.id, selected_session.stage_id, selected_session.id,
    next_code,
    case
      when next_order <= 26 then 'Lobby ' || next_code
      else 'Lobby ' || next_order::text
    end,
    next_order, selected_capacity, 'open'
  )
  returning * into created_lobby;

  return created_lobby;
end;
$$;

alter function public.levelledup_admin_create_session_lobby(uuid, integer)
  owner to postgres;
revoke all on function public.levelledup_admin_create_session_lobby(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_create_session_lobby(uuid, integer)
  to authenticated;

comment on function public.levelledup_admin_create_session_lobby(uuid, integer) is
  'Admin-only lobby creation pinned to an exact tournament session. Blocked once any match in that session has started (live/completed); a started tournament alone never blocks future sessions.';

-- ---------------------------------------------------------------------------
-- 2. Delete an empty lobby: no start-of-competition block anymore
--    (Haider: "dlt the lobby anyway"). The trigger still refuses lobbies that
--    have matches or assigned teams, so history can never be corrupted.
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_admin_delete_tournament_lobby(
  p_lobby_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
begin
  perform public.levelledup_require_admin('admin');

  select tournaments.*
  into selected_tournament
  from public.tournament_lobbies as lobbies
  join public.tournaments as tournaments on tournaments.id = lobbies.tournament_id
  where lobbies.id = p_lobby_id
  for update of tournaments;

  if selected_tournament.id is null then
    raise exception 'Tournament lobby not found.' using errcode = 'P4414';
  end if;

  delete from public.tournament_lobbies where id = p_lobby_id;

  return true;
end;
$$;

alter function public.levelledup_admin_delete_tournament_lobby(uuid)
  owner to postgres;
revoke all on function public.levelledup_admin_delete_tournament_lobby(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_delete_tournament_lobby(uuid)
  to authenticated;

comment on function public.levelledup_admin_delete_tournament_lobby(uuid) is
  'Admin-only deletion of an empty lobby at any time. Blocked when matches or active assignments exist.';

commit;
