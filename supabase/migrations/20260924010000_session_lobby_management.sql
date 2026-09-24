-- Fix 2: session-first lobby management.
--
-- The legacy "Add Lobby" path pinned stage 1 and let the DB guess the session,
-- which dies with 'Choose the exact Tournament Session for this Lobby.' (22023)
-- as soon as a stage has 2+ sessions. These RPCs make the session explicit and
-- give the admin full edit control: create, bulk-generate, rename, resize and
-- delete empty lobbies at any point before competition starts.
--
-- Deleting a lobby is only allowed while it has no matches and no active
-- assignments, so result history can never be corrupted.

begin;

-- ---------------------------------------------------------------------------
-- 1. Session-first lobby creation (session-scoped Lobby A/B/C codes)
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

  if now() >= selected_tournament.scheduled_start_at then
    raise exception 'Tournament lobbies cannot be created after competition starts.'
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
  'Admin-only lobby creation pinned to an exact tournament session. Replaces the legacy stage-1 session-guessing path.';

-- ---------------------------------------------------------------------------
-- 2. Bulk generation: N lobbies of K teams for one session
--    (e.g. 24 teams, 8 per lobby -> 3 lobbies)
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_admin_generate_session_lobbies(
  p_session_id uuid,
  p_teams_per_lobby integer,
  p_lobby_count integer
)
returns setof public.tournament_lobbies
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  created_lobby public.tournament_lobbies;
  i integer;
begin
  perform public.levelledup_require_admin('admin');

  if p_teams_per_lobby is null or p_teams_per_lobby < 1 or p_teams_per_lobby > 100 then
    raise exception 'Teams per lobby must be between 1 and 100.' using errcode = 'P4412';
  end if;
  if p_lobby_count is null or p_lobby_count < 1 or p_lobby_count > 26 then
    raise exception 'Lobby count must be between 1 and 26.' using errcode = 'P4412';
  end if;

  for i in 1..p_lobby_count loop
    select * into created_lobby
    from public.levelledup_admin_create_session_lobby(p_session_id, p_teams_per_lobby);
    return next created_lobby;
  end loop;

  return;
end;
$$;

alter function public.levelledup_admin_generate_session_lobbies(uuid, integer, integer)
  owner to postgres;
revoke all on function public.levelledup_admin_generate_session_lobbies(uuid, integer, integer)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_generate_session_lobbies(uuid, integer, integer)
  to authenticated;

comment on function public.levelledup_admin_generate_session_lobbies(uuid, integer, integer) is
  'Admin-only bulk lobby creation for one session: p_lobby_count lobbies of p_teams_per_lobby teams each.';

-- ---------------------------------------------------------------------------
-- 3. Rename a lobby (label only; lobby_code identity is stable)
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_admin_rename_tournament_lobby(
  p_lobby_id uuid,
  p_label text
)
returns public.tournament_lobbies
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  updated_lobby public.tournament_lobbies;
  clean_label text := btrim(coalesce(p_label, ''));
begin
  perform public.levelledup_require_admin('admin');

  if char_length(clean_label) < 1 or char_length(clean_label) > 80 then
    raise exception 'Lobby name must be between 1 and 80 characters.' using errcode = 'P4412';
  end if;

  update public.tournament_lobbies
  set display_label = clean_label, updated_at = now()
  where id = p_lobby_id
  returning * into updated_lobby;

  if updated_lobby.id is null then
    raise exception 'Tournament lobby not found.' using errcode = 'P4414';
  end if;

  return updated_lobby;
end;
$$;

alter function public.levelledup_admin_rename_tournament_lobby(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_admin_rename_tournament_lobby(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_rename_tournament_lobby(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Resize a lobby (never below the highest occupied slot)
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_admin_resize_tournament_lobby(
  p_lobby_id uuid,
  p_capacity integer
)
returns public.tournament_lobbies
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  updated_lobby public.tournament_lobbies;
  highest_slot integer;
begin
  perform public.levelledup_require_admin('admin');

  if p_capacity is null or p_capacity < 1 or p_capacity > 100 then
    raise exception 'Lobby capacity must be between 1 and 100.' using errcode = 'P4412';
  end if;

  select coalesce(max(slot_number), 0)::integer
  into highest_slot
  from public.tournament_stage_assignments
  where lobby_id = p_lobby_id and status = 'assigned';

  if p_capacity < highest_slot then
    raise exception 'Lobby cannot shrink below slot %: teams are assigned there.', highest_slot
      using errcode = 'P4412';
  end if;

  update public.tournament_lobbies
  set capacity = p_capacity, updated_at = now()
  where id = p_lobby_id
  returning * into updated_lobby;

  if updated_lobby.id is null then
    raise exception 'Tournament lobby not found.' using errcode = 'P4414';
  end if;

  return updated_lobby;
end;
$$;

alter function public.levelledup_admin_resize_tournament_lobby(uuid, integer)
  owner to postgres;
revoke all on function public.levelledup_admin_resize_tournament_lobby(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_resize_tournament_lobby(uuid, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Delete an empty lobby (no matches, no active assignments).
--    Lobbies with history can never be deleted.
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_validate_lobby_session_scope()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
declare selected_session public.tournament_stage_sessions; session_count integer;
begin
  if tg_op='UPDATE' and (new.id is distinct from old.id
    or new.tournament_id is distinct from old.tournament_id
    or new.stage_id is distinct from old.stage_id
    or new.session_id is distinct from old.session_id) then
    raise exception 'Lobby identity and owning Tournament, Stage and Session cannot change.' using errcode='22023';
  end if;
  if tg_op='DELETE' then
    if exists(select 1 from public.tournament_matches m where m.lobby_id=old.id) then
      raise exception 'Tournament Lobby history cannot be deleted: matches exist.' using errcode='22023';
    end if;
    if exists(select 1 from public.tournament_stage_assignments a
              where a.lobby_id=old.id and a.status='assigned') then
      raise exception 'Tournament Lobby cannot be deleted while teams are assigned.' using errcode='22023';
    end if;
    return old;
  end if;
  if new.session_id is null then
    select count(*)::integer,min(s.id) into session_count,new.session_id
    from public.tournament_stage_sessions s
    where s.stage_id=new.stage_id and s.tournament_id=new.tournament_id;
    if session_count<>1 then
      raise exception 'Choose the exact Tournament Session for this Lobby.' using errcode='22023';
    end if;
  end if;
  select s.* into selected_session from public.tournament_stage_sessions s
  where s.id=new.session_id and s.stage_id=new.stage_id and s.tournament_id=new.tournament_id for share;
  if selected_session.id is null then
    raise exception 'Lobby Session must belong to the same Stage and Tournament.' using errcode='23503';
  end if;
  if tg_op='UPDATE' and new.matches_per_lobby_override is distinct from old.matches_per_lobby_override
    and exists(select 1 from public.tournament_matches m where m.lobby_id=new.id
      and (coalesce(new.matches_per_lobby_override,selected_session.default_matches_per_lobby) is null
        or m.match_number>coalesce(new.matches_per_lobby_override,selected_session.default_matches_per_lobby))) then
    raise exception 'Lobby Match override conflicts with existing Match history.' using errcode='P4103';
  end if;
  return new;
end;
$$;

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

  if now() >= selected_tournament.scheduled_start_at then
    raise exception 'Tournament lobbies cannot be deleted after competition starts.'
      using errcode = 'P4406';
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
  'Admin-only deletion of an empty lobby. Blocked when matches or active assignments exist.';

-- ---------------------------------------------------------------------------
-- 6. Lobby listing: all stages, with session identity (was: stage 1 only)
-- ---------------------------------------------------------------------------
drop function public.levelledup_admin_get_tournament_lobbies(text);

create or replace function public.levelledup_admin_get_tournament_lobbies(
  p_tournament_code text
)
returns table (
  stage_id uuid,
  stage_number integer,
  session_id uuid,
  session_number integer,
  session_display_name text,
  lobby_id uuid,
  lobby_label text,
  lobby_code text,
  lobby_order integer,
  lobby_capacity integer,
  lobby_status text
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
    stages.id,
    stages.stage_number,
    sessions.id,
    sessions.session_number,
    sessions.display_name,
    lobbies.id,
    lobbies.display_label,
    lobbies.lobby_code,
    lobbies.lobby_order,
    lobbies.capacity,
    lobbies.status
  from public.tournaments as tournaments
  join public.tournament_stages as stages
    on stages.tournament_id = tournaments.id
  join public.tournament_stage_sessions as sessions
    on sessions.stage_id = stages.id
  join public.tournament_lobbies as lobbies
    on lobbies.session_id = sessions.id
  where tournaments.tournament_id = upper(btrim(p_tournament_code))
  order by stages.stage_number, sessions.session_number, lobbies.lobby_order;
end;
$$;

alter function public.levelledup_admin_get_tournament_lobbies(text)
  owner to postgres;
revoke all on function public.levelledup_admin_get_tournament_lobbies(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_get_tournament_lobbies(text)
  to authenticated;

comment on function public.levelledup_admin_get_tournament_lobbies(text) is
  'Admin-only lobby identities across all stages and sessions, with session scope for the lobby editor.';

commit;
