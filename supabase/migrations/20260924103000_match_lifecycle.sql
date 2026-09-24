-- Match lifecycle: pre-match lobby phase, start/complete/cancel/reopen, results gating.
--
-- Rule implemented (Haider-approved 2026-09-24):
--   * scheduled -> pre_match -> live -> completed, with cancel from
--     scheduled/pre_match/live. completed/cancelled are terminal except a
--     deliberate admin reopen (completed -> live) for corrections, which is
--     logged with a required reason.
--   * A match can only START from its pre-match lobby, and only when every
--     participating team is marked set OR the lobby timer has expired
--     (admin force-start with a reason is the escape hatch, also logged).
--   * A match can only be COMPLETED when it is live, every participating team
--     has a result (or DNP), and every result is finalized.
--   * Team results can only be entered/finalized while the match is live.
--     Corrections go through reopen -> live. Player data may still be entered
--     later (unchanged).
--   * Every transition is written to match_lifecycle_events: who, from, to,
--     when, why.

-- ---------------------------------------------------------------------------
-- 1. New columns on tournament_matches
-- ---------------------------------------------------------------------------
alter table public.tournament_matches
  add column if not exists started_at timestamptz,
  add column if not exists pre_match_opened_at timestamptz,
  add column if not exists pre_match_timer_seconds integer not null default 420,
  add column if not exists pre_match_closed_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_reason text;

comment on column public.tournament_matches.started_at is
  'When the match actually went live (admin started it). Null until the match goes live; preserved across reopen corrections.';
comment on column public.tournament_matches.pre_match_opened_at is
  'When the pre-match lobby (ready check + chat + timer) was opened by an admin.';
comment on column public.tournament_matches.pre_match_timer_seconds is
  'Pre-match lobby countdown in seconds. Default 420 (7 minutes).';
comment on column public.tournament_matches.pre_match_closed_at is
  'When the pre-match lobby closed (match started or was cancelled).';
comment on column public.tournament_matches.cancelled_at is
  'When the match was cancelled.';
comment on column public.tournament_matches.cancelled_reason is
  'Admin-supplied reason for cancelling the match. Required.';

-- ---------------------------------------------------------------------------
-- 2. Status vocabulary gains pre_match
-- ---------------------------------------------------------------------------
alter table public.tournament_matches
  drop constraint tournament_matches_status_valid;

alter table public.tournament_matches
  add constraint tournament_matches_status_valid check (
    status in ('scheduled', 'pre_match', 'live', 'completed', 'cancelled')
  );

-- ---------------------------------------------------------------------------
-- 3. Append-only lifecycle audit log
-- ---------------------------------------------------------------------------
create table if not exists public.match_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete restrict,
  match_id uuid not null references public.tournament_matches(id) on delete cascade,
  from_status text not null,
  to_status text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  actor_role text not null,
  reason text,
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists match_lifecycle_events_match_idx
  on public.match_lifecycle_events (match_id, created_at desc);

alter table public.match_lifecycle_events enable row level security;

revoke all on table public.match_lifecycle_events
  from public, anon, authenticated;

comment on table public.match_lifecycle_events is
  'Append-only audit of every match status transition: who moved it, from what to what, when, and why. Written only by the lifecycle RPCs.';

-- ---------------------------------------------------------------------------
-- 4. Participating teams helper: active lobby assignments for a match.
--    Same definition as the participation-proof snapshot: status 'assigned'
--    with no release timestamp. Released historical rows are excluded.
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_match_active_team_ids(p_match_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select a.registration_id
  from public.tournament_matches as m
  join public.tournament_stage_assignments as a
    on a.lobby_id = m.lobby_id
  where m.id = p_match_id
    and a.status = 'assigned'
    and a.released_at is null
$$;

alter function public.levelledup_match_active_team_ids(uuid)
  owner to postgres;

revoke all on function public.levelledup_match_active_team_ids(uuid)
  from public, anon, authenticated;

comment on function public.levelledup_match_active_team_ids(uuid) is
  'Registration ids of teams currently assigned to the match lobby (active only, released rows excluded). Internal helper for the lifecycle RPCs.';

-- ---------------------------------------------------------------------------
-- 5. Transition guard: full replacement with the pre_match phase and reopen.
--    (Body copied from 20260826053000; only the transition rules changed.)
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_validate_tournament_match()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
  configured_match_count bigint;
begin
  if tg_op = 'UPDATE'
    and new.tournament_id is distinct from old.tournament_id then
    raise exception 'A match cannot be moved to another tournament.'
      using errcode = '22023';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = new.tournament_id
  for share;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4101';
  end if;

  if selected_tournament.status = 'completed' then
    raise exception 'Matches cannot be changed after tournament completion.'
      using errcode = 'P4102';
  end if;

  if tg_op = 'INSERT'
    and selected_tournament.status = 'cancelled' then
    raise exception 'Matches cannot be added to a cancelled tournament.'
      using errcode = 'P4102';
  end if;

  configured_match_count :=
    selected_tournament.matches_per_day::bigint
    * selected_tournament.number_of_days::bigint;

  if new.match_number::bigint > configured_match_count then
    raise exception 'Match number exceeds the tournament configured match count.'
      using errcode = 'P4103';
  end if;

  if new.scheduled_start_at < selected_tournament.scheduled_start_at
    or (
      selected_tournament.scheduled_end_at is not null
      and new.scheduled_start_at > selected_tournament.scheduled_end_at
    ) then
    raise exception 'Match schedule falls outside the tournament schedule.'
      using errcode = 'P4104';
  end if;

  if tg_op = 'INSERT'
    or new.map_code is distinct from old.map_code then
    if not exists (
      select 1
      from public.pubg_maps
      where pubg_maps.code = new.map_code
        and pubg_maps.is_active
    ) then
      raise exception 'Select an active canonical PUBG map.'
        using errcode = 'P4105';
    end if;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'scheduled' then
      raise exception 'A new match must begin as scheduled.'
        using errcode = 'P4106';
    end if;
  elsif old.status = 'cancelled' then
    raise exception 'Cancelled matches are historically immutable.'
      using errcode = 'P4102';
  elsif old.status = 'completed' and new.status <> 'live' then
    raise exception 'A completed match can only be reopened to live for corrections.'
      using errcode = 'P4102';
  elsif new.status is distinct from old.status
    and not (
      (old.status = 'scheduled' and new.status in ('pre_match', 'cancelled'))
      or (old.status = 'pre_match' and new.status in ('live', 'cancelled'))
      or (old.status = 'live' and new.status in ('completed', 'cancelled'))
      or (old.status = 'completed' and new.status = 'live')
    ) then
    raise exception 'Invalid match status transition.'
      using errcode = 'P4106';
  end if;

  if tg_op = 'UPDATE'
    and old.status in ('pre_match', 'live')
    and (
      new.match_number is distinct from old.match_number
      or new.map_code is distinct from old.map_code
      or new.scheduled_start_at is distinct from old.scheduled_start_at
    ) then
    raise exception 'Pre-match and live match identity and schedule cannot be changed.'
      using errcode = '22023';
  end if;

  if new.status in ('pre_match', 'live')
    and selected_tournament.status <> 'live' then
    raise exception 'A match can enter pre-match or go live only while its tournament is live.'
      using errcode = 'P4107';
  end if;

  if new.status = 'completed'
    and selected_tournament.status <> 'live' then
    raise exception 'A match can be completed only while its tournament is live.'
      using errcode = 'P4107';
  end if;

  if selected_tournament.status = 'cancelled'
    and new.status <> 'cancelled' then
    raise exception 'Matches in a cancelled tournament must be cancelled.'
      using errcode = 'P4107';
  end if;

  if new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  else
    new.completed_at := null;
  end if;

  if new.status in ('live', 'completed') then
    if tg_op = 'UPDATE' then
      new.started_at := coalesce(old.started_at, now());
    else
      new.started_at := now();
    end if;
  else
    new.started_at := null;
  end if;

  if tg_op = 'UPDATE'
    and old.status = 'scheduled'
    and new.status = 'pre_match' then
    new.pre_match_opened_at := coalesce(new.pre_match_opened_at, now());
    new.pre_match_closed_at := null;
  elsif tg_op = 'UPDATE'
    and old.status = 'pre_match'
    and new.status in ('live', 'cancelled') then
    new.pre_match_closed_at := coalesce(new.pre_match_closed_at, now());
  end if;

  if new.status = 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
    if new.cancelled_reason is null
      or btrim(new.cancelled_reason) = '' then
      raise exception 'Cancelling a match requires a reason.'
        using errcode = '22023';
    end if;
  else
    new.cancelled_at := null;
    new.cancelled_reason := null;
  end if;

  return new;
end;
$$;

alter function public.levelledup_validate_tournament_match()
  owner to postgres;

revoke all on function public.levelledup_validate_tournament_match()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Lifecycle RPCs (admin only)
-- ---------------------------------------------------------------------------

-- 6a. Open the pre-match lobby: scheduled -> pre_match.
create or replace function public.levelledup_admin_open_pre_match(
  p_match_id uuid
)
returns public.tournament_matches
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  saved_match public.tournament_matches;
  team_count integer;
begin
  perform public.levelledup_require_admin('admin');

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into saved_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id
  for update;

  if saved_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  if saved_match.status <> 'scheduled' then
    raise exception 'Only a scheduled match can open its pre-match lobby.'
      using errcode = '22023';
  end if;

  select count(*)
  into team_count
  from public.levelledup_match_active_team_ids(p_match_id);

  if team_count < 1 then
    raise exception 'Assign at least one team to the lobby before opening the pre-match lobby.'
      using errcode = '22023';
  end if;

  update public.tournament_matches
  set status = 'pre_match',
      pre_match_opened_at = now(),
      pre_match_closed_at = null,
      updated_at = now()
  where id = p_match_id
  returning * into saved_match;

  insert into public.match_lifecycle_events (
    tournament_id, match_id, from_status, to_status,
    actor_user_id, actor_role, reason
  ) values (
    saved_match.tournament_id, saved_match.id, 'scheduled', 'pre_match',
    actor_user_id, 'admin', null
  );

  return saved_match;
end;
$$;

alter function public.levelledup_admin_open_pre_match(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_open_pre_match(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_open_pre_match(uuid)
  to authenticated;

comment on function public.levelledup_admin_open_pre_match(uuid) is
  'Admin opens the pre-match lobby (ready check + chat + timer): scheduled -> pre_match. Requires at least one assigned team.';

-- 6b. Start the match: pre_match -> live.
--     Allowed when every participating team is marked set, or the lobby
--     timer has expired. p_force with a reason is the admin escape hatch.
create or replace function public.levelledup_admin_start_match(
  p_match_id uuid,
  p_force boolean default false,
  p_reason text default null
)
returns public.tournament_matches
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  saved_match public.tournament_matches;
  team_ids uuid[];
  team_total integer;
  set_count integer;
  timer_expires_at timestamptz;
  normalized_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  event_reason text;
begin
  perform public.levelledup_require_admin('admin');

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into saved_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id
  for update;

  if saved_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  if saved_match.status <> 'pre_match' then
    raise exception 'A match can only start from its pre-match lobby.'
      using errcode = '22023';
  end if;

  select array_agg(t.team_id)
  into team_ids
  from public.levelledup_match_active_team_ids(p_match_id) as t(team_id);

  team_total := coalesce(array_length(team_ids, 1), 0);

  if team_total < 1 then
    raise exception 'There are no participating teams in this lobby, so the match cannot start.'
      using errcode = '22023';
  end if;

  select count(*)
  into set_count
  from public.match_ready_checks as rc
  where rc.tournament_match_id = p_match_id
    and rc.tournament_registration_id = any(team_ids);

  timer_expires_at :=
    saved_match.pre_match_opened_at
    + (saved_match.pre_match_timer_seconds * interval '1 second');

  if coalesce(p_force, false) then
    if normalized_reason is null then
      raise exception 'Force-starting a match requires a reason.'
        using errcode = '22023';
    end if;
    event_reason := 'Force-started by admin: ' || normalized_reason;
  else
    if set_count < team_total and clock_timestamp() < timer_expires_at then
      raise exception 'Cannot start yet: % of % teams are set and the lobby timer is still running.', set_count, team_total
        using errcode = '22023';
    end if;
    if set_count >= team_total then
      event_reason := 'All ' || team_total || ' teams marked set.';
    else
      event_reason := 'Lobby timer expired with ' || set_count || ' of ' || team_total || ' teams set.';
    end if;
  end if;

  update public.tournament_matches
  set status = 'live',
      started_at = now(),
      pre_match_closed_at = now(),
      updated_at = now()
  where id = p_match_id
  returning * into saved_match;

  insert into public.match_lifecycle_events (
    tournament_id, match_id, from_status, to_status,
    actor_user_id, actor_role, reason
  ) values (
    saved_match.tournament_id, saved_match.id, 'pre_match', 'live',
    actor_user_id, 'admin', event_reason
  );

  return saved_match;
end;
$$;

alter function public.levelledup_admin_start_match(uuid, boolean, text)
  owner to postgres;

revoke all on function public.levelledup_admin_start_match(uuid, boolean, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_start_match(uuid, boolean, text)
  to authenticated;

comment on function public.levelledup_admin_start_match(uuid, boolean, text) is
  'Admin starts the match: pre_match -> live. Requires all teams set or the lobby timer expired; p_force with a reason is the logged escape hatch.';

-- 6c. Complete the match: live -> completed.
--     Replaces the old version, which could never succeed (no path to live)
--     and checked nothing. Now requires every participating team to have a
--     result (or DNP) and every result to be finalized.
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
  actor_user_id uuid := auth.uid();
  saved_match public.tournament_matches;
  team_ids uuid[];
  team_total integer;
  missing_count integer;
  draft_count integer;
begin
  perform public.levelledup_require_admin('admin');

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into saved_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id
  for update;

  if saved_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  if saved_match.status <> 'live' then
    raise exception 'Only a live match can be completed.'
      using errcode = '22023';
  end if;

  -- Participating teams: the frozen snapshot when results exist, otherwise
  -- the current active lobby assignments (same definition as the proof).
  if exists (
    select 1
    from public.match_participations as mp
    where mp.tournament_match_id = p_match_id
  ) then
    select array_agg(mp.tournament_registration_id)
    into team_ids
    from public.match_participations as mp
    where mp.tournament_match_id = p_match_id;
  else
    select array_agg(t.team_id)
    into team_ids
    from public.levelledup_match_active_team_ids(p_match_id) as t(team_id);
  end if;

  team_total := coalesce(array_length(team_ids, 1), 0);

  if team_total < 1 then
    raise exception 'No participating teams are recorded for this match.'
      using errcode = '22023';
  end if;

  select count(*)
  into missing_count
  from unnest(team_ids) as t(reg_id)
  where not exists (
    select 1
    from public.match_results as r
    where r.tournament_match_id = p_match_id
      and r.tournament_registration_id = t.reg_id
  );

  if missing_count > 0 then
    raise exception 'Cannot complete: % of % teams still have no result (or DNP) recorded.', missing_count, team_total
      using errcode = '22023';
  end if;

  select count(*)
  into draft_count
  from public.match_results as r
  where r.tournament_match_id = p_match_id
    and r.status <> 'final';

  if draft_count > 0 then
    raise exception 'Cannot complete: % result(s) are still drafts. Finalize every result first.', draft_count
      using errcode = '22023';
  end if;

  update public.tournament_matches
  set status = 'completed',
      completed_at = now(),
      updated_at = now()
  where id = p_match_id
  returning * into saved_match;

  insert into public.match_lifecycle_events (
    tournament_id, match_id, from_status, to_status,
    actor_user_id, actor_role, reason
  ) values (
    saved_match.tournament_id, saved_match.id, 'live', 'completed',
    actor_user_id, 'admin',
    team_total || ' teams, all results finalized.'
  );

  return saved_match;
end;
$$;

alter function public.levelledup_admin_complete_match(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_complete_match(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_complete_match(uuid)
  to authenticated;

comment on function public.levelledup_admin_complete_match(uuid) is
  'Admin completes a live match. Requires a result (or DNP) for every participating team and every result finalized.';

-- 6d. Cancel the match: scheduled/pre_match/live -> cancelled. Reason required.
create or replace function public.levelledup_admin_cancel_match(
  p_match_id uuid,
  p_reason text
)
returns public.tournament_matches
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  saved_match public.tournament_matches;
  from_status text;
  normalized_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.levelledup_require_admin('admin');

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  if normalized_reason is null then
    raise exception 'Cancelling a match requires a reason.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into saved_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id
  for update;

  if saved_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  if saved_match.status in ('completed', 'cancelled') then
    raise exception 'Completed and cancelled matches cannot be cancelled.'
      using errcode = '22023';
  end if;

  from_status := saved_match.status;

  update public.tournament_matches
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_reason = normalized_reason,
      pre_match_closed_at = case
        when saved_match.status = 'pre_match' then now()
        else pre_match_closed_at
      end,
      updated_at = now()
  where id = p_match_id
  returning * into saved_match;

  insert into public.match_lifecycle_events (
    tournament_id, match_id, from_status, to_status,
    actor_user_id, actor_role, reason
  ) values (
    saved_match.tournament_id, saved_match.id, from_status, 'cancelled',
    actor_user_id, 'admin', normalized_reason
  );

  return saved_match;
end;
$$;

alter function public.levelledup_admin_cancel_match(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_admin_cancel_match(uuid, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_cancel_match(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_cancel_match(uuid, text) is
  'Admin cancels a scheduled, pre-match, or live match. Reason required and logged. Entered results stay as history but cancelled matches are excluded from standings.';

-- 6e. Reopen a completed match for corrections: completed -> live.
--     Deliberate admin correction path; reason required and logged.
create or replace function public.levelledup_admin_reopen_match(
  p_match_id uuid,
  p_reason text
)
returns public.tournament_matches
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  saved_match public.tournament_matches;
  normalized_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.levelledup_require_admin('admin');

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  if normalized_reason is null then
    raise exception 'Reopening a completed match requires a reason.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into saved_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id
  for update;

  if saved_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  if saved_match.status <> 'completed' then
    raise exception 'Only a completed match can be reopened for corrections.'
      using errcode = '22023';
  end if;

  update public.tournament_matches
  set status = 'live',
      completed_at = null,
      updated_at = now()
  where id = p_match_id
  returning * into saved_match;

  insert into public.match_lifecycle_events (
    tournament_id, match_id, from_status, to_status,
    actor_user_id, actor_role, reason
  ) values (
    saved_match.tournament_id, saved_match.id, 'completed', 'live',
    actor_user_id, 'admin', normalized_reason
  );

  return saved_match;
end;
$$;

alter function public.levelledup_admin_reopen_match(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_admin_reopen_match(uuid, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_reopen_match(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_reopen_match(uuid, text) is
  'Admin reopens a completed match back to live for corrections. Reason required and logged; the match must be completed again afterwards.';

-- ---------------------------------------------------------------------------
-- 7. Results gating: team results can only be entered/finalized while the
--    match is live. Corrections go through reopen -> live. Player data entry
--    is intentionally left ungated (it may be entered with results or later).
-- ---------------------------------------------------------------------------

-- 7a. Single upsert (the admin bulk upsert delegates to this, so one gate
--     covers both). Body preserved from 20260924070000; only the match-status
--     check is added.
create or replace function public.levelledup_upsert_match_result(
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
  selected_match_status text;
  saved_result public.match_results;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to enter match results.'
      using errcode = '42501';
  end if;

  select tournament_matches.tournament_id, tournament_matches.status
  into selected_tournament_id, selected_match_status
  from public.tournament_matches
  where tournament_matches.id = p_tournament_match_id;

  if selected_tournament_id is null then
    raise exception 'Tournament match not found.' using errcode = 'P4203';
  end if;

  if selected_match_status <> 'live' then
    raise exception 'Match results can only be entered while the match is live.'
      using errcode = '22023';
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
  'Upserts one team result draft. p_did_not_play records Did Not Play with NULL numerics, never zero. Only allowed while the match is live.';

-- 7b. Finalize: only while the match is live.
create or replace function public.levelledup_finalize_match_result(
  p_match_result_id uuid
)
returns public.match_results
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_result public.match_results;
  selected_match_status text;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to finalize match results.'
      using errcode = '42501';
  end if;

  select match_results.*
  into selected_result
  from public.match_results
  where match_results.id = p_match_result_id
  for update;

  if selected_result.id is null then
    raise exception 'Draft match result not found.'
      using errcode = 'P4211';
  end if;

  if selected_result.status <> 'draft' then
    raise exception 'Only a draft match result can be finalized.'
      using errcode = 'P4211';
  end if;

  select tournament_matches.status
  into selected_match_status
  from public.tournament_matches
  where tournament_matches.id = selected_result.tournament_match_id;

  if selected_match_status <> 'live' then
    raise exception 'Match results can only be finalized while the match is live.'
      using errcode = '22023';
  end if;

  update public.match_results
  set
    status = 'final',
    finalized_by = authenticated_user_id,
    finalized_at = now()
  where id = selected_result.id
  returning * into selected_result;

  return selected_result;
end;
$$;

alter function public.levelledup_finalize_match_result(uuid)
  owner to postgres;

revoke all on function public.levelledup_finalize_match_result(uuid)
  from public, anon, authenticated;

comment on function public.levelledup_finalize_match_result(uuid) is
  'Trusted finalization point. Only allowed while the match is live; corrections go through reopen -> live.';
