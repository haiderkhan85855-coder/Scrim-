-- ============================================================================
-- 20260924160000_qualification.sql
--
-- What this file does (plain language):
--   The database learns to remember which teams QUALIFIED from a stage, so the
--   "where do I play next" card stops guessing.
--
--   1. Each stage gets a setting: "top N teams qualify" (set by the admin when
--      the stage is created). One number per stage, used for every session of
--      that stage. The final stage gets none.
--   2. A new list (tournament_stage_qualifiers) records every qualifier: team,
--      stage, session, lobby, rank, points, and whether it was automatic or
--      marked by an admin's hand. One team = one active qualification per
--      stage; qualifying twice never creates a second one.
--   3. "Mark qualifiers" (one button per session, pressed after all matches
--      are done and results are final): per lobby it ranks teams by total
--      points, SKIPS teams already qualified in this stage (their slot slides
--      down to the next team), and takes the top N. Everyone tied on points
--      with the last slot also qualifies. Teams that placed high again but
--      were already qualified get an "already qualified" message instead.
--   4. Every new qualifier instantly gets a FREE entry for the next stage's
--      first open session, and every player on the team gets a notification.
--   5. The admin can mark a qualifier by hand (machine-error fix) and unmark
--      one. Unmarking cancels the free entry if unused; if already played,
--      history stays.
--   6. The next-entry card gets smart: qualified -> next stage, free (plus a
--      paid replay option for the stage they came from); not qualified ->
--      paid retry; nothing left -> closed + top-up.
--
-- Rules covered / edge cases:
--   - Auto-mark REFUSES when: matches aren't all finished, results aren't all
--     finalized, or the stage's qualifier number was never set. Clear message
--     every time, nothing half-written.
--   - Cancelled matches and cancelled lobbies are ignored by the standings.
--   - Ties at the cutoff: ALL tied teams qualify (no tiebreak elimination).
--     Damage-based tiebreaks are future work, not this file.
--   - Already-qualified teams never consume a slot, in any session.
--   - Re-running the button is safe: recorded qualifiers are not duplicated,
--     missing free entries are backfilled, "already qualified" messages are
--     not re-sent.
--   - Manual marks need a 10-1000 character reason (audit trail).
--   - tournament_session_entries.qualification_event_id stays NULL: the real
--     qualification model is this table, linked via earned_from_session_entry_id
--     on the entry and earned_entry_id on the qualifier.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Stage setting: how many teams qualify ("top N").
-- ----------------------------------------------------------------------------

alter table public.tournament_stages
  add column if not exists qualifier_count integer;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint where conname = 'tournament_stages_qualifier_count_valid'
  ) then
    alter table public.tournament_stages
      add constraint tournament_stages_qualifier_count_valid
      check (qualifier_count is null or qualifier_count >= 1);
  end if;
end
$$;

comment on column public.tournament_stages.qualifier_count is
  'Set by the admin at stage creation: how many teams qualify onward from EACH lobby of EACH session of this stage. Everyone tied on points with the last slot also qualifies; teams already qualified in this stage are skipped and the slot slides down to the next team. NULL = nobody qualifies (normally the final stage).';

-- ----------------------------------------------------------------------------
-- 2. tournament_stage_qualifiers: the database's memory of who qualified.
-- ----------------------------------------------------------------------------

create table public.tournament_stage_qualifiers (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null,
  stage_id uuid not null,
  qualified_from_session_id uuid not null,
  lobby_id uuid not null,
  registration_id uuid not null,
  team_id uuid not null references public.teams (id) on delete restrict,
  rank integer,
  total_points integer not null default 0,
  total_kills integer not null default 0,
  method text not null,
  status text not null default 'active',
  qualified_by uuid references auth.users (id) on delete restrict,
  qualified_at timestamptz not null default now(),
  revoked_by uuid references auth.users (id) on delete restrict,
  revoked_at timestamptz,
  revoke_reason text,
  earned_entry_id uuid references public.tournament_session_entries (id) on delete restrict,
  source_provenance jsonb not null default '{}'::jsonb,
  request_id uuid not null unique,
  constraint tournament_stage_qualifiers_stage_fk
    foreign key (stage_id, tournament_id)
    references public.tournament_stages (id, tournament_id) on delete restrict,
  constraint tournament_stage_qualifiers_session_fk
    foreign key (qualified_from_session_id, stage_id, tournament_id)
    references public.tournament_stage_sessions (id, stage_id, tournament_id) on delete restrict,
  constraint tournament_stage_qualifiers_lobby_fk
    foreign key (lobby_id, qualified_from_session_id, stage_id, tournament_id)
    references public.tournament_lobbies (id, session_id, stage_id, tournament_id) on delete restrict,
  constraint tournament_stage_qualifiers_registration_fk
    foreign key (registration_id, tournament_id, team_id)
    references public.tournament_registrations (id, tournament_id, team_id) on delete restrict,
  constraint tournament_stage_qualifiers_method_valid
    check (method in ('auto', 'manual')),
  constraint tournament_stage_qualifiers_status_valid
    check (status in ('active', 'revoked')),
  constraint tournament_stage_qualifiers_rank_valid
    check (rank is null or rank >= 1),
  constraint tournament_stage_qualifiers_points_valid
    check (total_points >= 0 and total_kills >= 0),
  constraint tournament_stage_qualifiers_revoke_state_valid check (
    (status = 'active'
      and revoked_by is null and revoked_at is null and revoke_reason is null)
    or (status = 'revoked'
      and revoked_by is not null and revoked_at is not null
      and revoke_reason = btrim(revoke_reason)
      and char_length(revoke_reason) between 10 and 1000)
  ),
  constraint tournament_stage_qualifiers_provenance_object
    check (jsonb_typeof(source_provenance) = 'object')
);

comment on table public.tournament_stage_qualifiers is
  'Authoritative qualification record. Exactly one ACTIVE row per team per stage: qualifying again never creates a second one, and an already-qualified team never consumes another slot. Manual marks and revocations are fully audited.';

comment on column public.tournament_stage_qualifiers.rank is
  'Lobby standing at mark time (1 = best). NULL when marked manually without usable standings.';

comment on column public.tournament_stage_qualifiers.earned_entry_id is
  'The free next-stage session entry created for this qualifier (source earned).';

-- One active qualification per team per stage.
create unique index tournament_stage_qualifiers_one_active_per_team_stage_idx
  on public.tournament_stage_qualifiers (stage_id, team_id)
  where status = 'active';

create index tournament_stage_qualifiers_session_idx
  on public.tournament_stage_qualifiers (qualified_from_session_id, status);

alter table public.tournament_stage_qualifiers enable row level security;

revoke all on table public.tournament_stage_qualifiers from anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. Internal notification writer.
--    The ONLY sanctioned writer of qualification notices, besides the
--    entry-shift trigger from 140000 (which this file does not touch).
--    Called only by the qualifier jobs below; never granted to app roles.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup__notify_team(
  p_team_id uuid,
  p_tournament_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  notification_id uuid;
begin
  if p_team_id is null
    or p_tournament_id is null
    or p_type is null
    or p_title is null
    or p_message is null then
    raise exception 'Team, tournament, type, title and message are required.'
      using errcode = '22023';
  end if;

  insert into public.team_notifications
    (team_id, tournament_id, type, title, message, metadata)
  values (
    p_team_id,
    p_tournament_id,
    btrim(p_type),
    btrim(p_title),
    btrim(p_message),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into notification_id;

  -- Fan out to current active members only, same as the entry-shift trigger:
  -- unclaimed roster slots (profile_id null) and left/removed members get
  -- nothing, and later joiners never see older notices.
  insert into public.team_notification_recipients (notification_id, user_id)
  select notification_id, member.profile_id
  from public.team_roster_members as member
  where member.team_id = p_team_id
    and member.status = 'active'
    and member.profile_id is not null
  on conflict do nothing;

  return notification_id;
end;
$$;

comment on function public.levelledup__notify_team(uuid, uuid, text, text, text, jsonb) is
  'Internal: the single sanctioned writer of qualification notices (qualified / already_qualified / qualification_revoked). Only the qualifier jobs call it.';

-- ----------------------------------------------------------------------------
-- 4. Internal: create (or backfill) the free next-stage entry for a qualifier.
--    Returns jsonb {ok, entry_id?, session_id?, existing?, reason?}.
--    Never raises for "cannot right now" situations; it reports them so the
--    caller can surface them instead of crashing the whole marking run.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup__grant_earned_session_entry(
  p_qualifier_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  qualifier public.tournament_stage_qualifiers;
  current_stage_number integer;
  next_stage public.tournament_stages;
  target_session public.tournament_stage_sessions;
  source_entry public.tournament_session_entries;
  existing_entry_id uuid;
  new_entry_id uuid;
  actor_role text;
  stage_name text;
begin
  if p_qualifier_id is null then
    raise exception 'Qualifier is required.' using errcode = '22023';
  end if;

  select q.* into qualifier
  from public.tournament_stage_qualifiers as q
  where q.id = p_qualifier_id
  for update;

  if qualifier.id is null then
    raise exception 'Qualifier not found.' using errcode = 'P4414';
  end if;

  if qualifier.status <> 'active' then
    return jsonb_build_object('ok', false, 'reason', 'Qualifier is not active.');
  end if;

  -- Already holding a live earned entry? Nothing to do.
  if qualifier.earned_entry_id is not null then
    select e.id into existing_entry_id
    from public.tournament_session_entries as e
    where e.id = qualifier.earned_entry_id
      and e.status = 'active';
    if existing_entry_id is not null then
      return jsonb_build_object(
        'ok', true, 'entry_id', existing_entry_id, 'existing', true
      );
    end if;
  end if;

  select s.stage_number into current_stage_number
  from public.tournament_stages as s
  where s.id = qualifier.stage_id;

  select st.* into next_stage
  from public.tournament_stages as st
  where st.tournament_id = qualifier.tournament_id
    and st.stage_number = current_stage_number + 1
  limit 1;

  if next_stage.id is null then
    return jsonb_build_object(
      'ok', false, 'reason', 'The next stage does not exist yet.'
    );
  end if;

  if next_stage.status in ('completed', 'cancelled') then
    return jsonb_build_object(
      'ok', false, 'reason', 'The next stage is closed.'
    );
  end if;

  -- Earliest session of the next stage that still accepts entries.
  select sess.* into target_session
  from public.tournament_stage_sessions as sess
  where sess.stage_id = next_stage.id
    and sess.status in ('planned', 'open')
    and not public.levelledup_session_has_started(sess.id)
  order by sess.session_number, sess.id
  limit 1;

  if target_session.id is null then
    return jsonb_build_object(
      'ok', false, 'reason', 'The next stage has no open session left.'
    );
  end if;

  -- The entry they earned it from: the one they played in the qualifying
  -- session. (Any status: the link is provenance, the row must simply exist.)
  select e.* into source_entry
  from public.tournament_session_entries as e
  where e.registration_id = qualifier.registration_id
    and e.session_id = qualifier.qualified_from_session_id
  order by e.created_at desc, e.id desc
  limit 1;

  if source_entry.id is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'No session entry found for the qualifying session.'
    );
  end if;

  -- Idempotent: an active entry for this registration in the target session?
  select e.id into existing_entry_id
  from public.tournament_session_entries as e
  where e.registration_id = qualifier.registration_id
    and e.session_id = target_session.id
    and e.status = 'active'
  limit 1;

  if existing_entry_id is not null then
    update public.tournament_stage_qualifiers
    set earned_entry_id = existing_entry_id
    where id = qualifier.id;
    return jsonb_build_object(
      'ok', true, 'entry_id', existing_entry_id, 'existing', true
    );
  end if;

  actor_role := public.levelledup_current_admin_role();
  if actor_role is null then
    actor_role := 'admin';
  end if;

  select st.display_name into stage_name
  from public.tournament_stages as st
  where st.id = qualifier.stage_id;

  insert into public.tournament_session_entries (
    tournament_id, stage_id, session_id, registration_id, team_id,
    source_type, earned_from_session_entry_id,
    source_occurred_at, source_provenance, reason,
    request_id, created_by, created_by_role
  ) values (
    qualifier.tournament_id,
    next_stage.id,
    target_session.id,
    qualifier.registration_id,
    qualifier.team_id,
    'earned',
    source_entry.id,
    now(),
    jsonb_build_object(
      'qualifier_id', qualifier.id::text,
      'qualified_from_stage_id', qualifier.stage_id::text,
      'qualified_from_session_id', qualifier.qualified_from_session_id::text,
      'lobby_id', qualifier.lobby_id::text,
      'rank', qualifier.rank,
      'total_points', qualifier.total_points,
      'total_kills', qualifier.total_kills,
      'method', qualifier.method
    ),
    'Earned free entry: qualified from stage "' || coalesce(stage_name, '?') || '".',
    gen_random_uuid(),
    auth.uid(),
    actor_role
  )
  returning id into new_entry_id;

  update public.tournament_stage_qualifiers
  set earned_entry_id = new_entry_id
  where id = qualifier.id;

  return jsonb_build_object(
    'ok', true,
    'entry_id', new_entry_id,
    'session_id', target_session.id
  );
end;
$$;

comment on function public.levelledup__grant_earned_session_entry(uuid) is
  'Internal: creates (or backfills) the free next-stage session entry for a qualifier. Reports instead of raising when the entry cannot be created yet.';

-- ----------------------------------------------------------------------------
-- 5. "Mark qualifiers": the per-session button, pressed after all matches are
--    done and results are final. Per lobby: rank by total points, skip teams
--    already qualified in this stage (slot slides down), take the top N, and
--    include everyone tied on points with the last slot.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_mark_session_qualifiers(
  p_session_id uuid,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  sess public.tournament_stage_sessions;
  stg public.tournament_stages;
  slots integer;
  lobby public.tournament_lobbies;
  standing record;
  filled integer;
  cutoff_points integer;
  existing_qualifier_id uuid;
  new_qualifier_id uuid;
  grant_result jsonb;
  grant_ok boolean;
  notice_exists boolean;
  qualified_list jsonb := '[]'::jsonb;
  already_list jsonb := '[]'::jsonb;
  entry_skipped_list jsonb := '[]'::jsonb;
begin
  perform public.levelledup_require_admin('admin');

  if p_session_id is null or p_request_id is null then
    raise exception 'Session and request ID are required.'
      using errcode = '22023';
  end if;

  select s.* into sess
  from public.tournament_stage_sessions as s
  where s.id = p_session_id
  for update;

  if sess.id is null then
    raise exception 'Session not found.' using errcode = 'P4414';
  end if;

  select st.* into stg
  from public.tournament_stages as st
  where st.id = sess.stage_id;

  slots := stg.qualifier_count;

  if slots is null then
    raise exception 'Set how many teams qualify for this stage before marking qualifiers.'
      using errcode = '22023';
  end if;

  -- Every match of the session must be finished. Cancelled matches don't count.
  if exists (
    select 1
    from public.tournament_matches as m
    join public.tournament_lobbies as l on l.id = m.lobby_id
    where l.session_id = sess.id
      and m.status not in ('completed', 'cancelled')
  ) then
    raise exception 'Finish all matches of this session before marking qualifiers.'
      using errcode = 'P4408';
  end if;

  -- Every finished match needs entered AND finalized results.
  if exists (
    select 1
    from public.tournament_matches as m
    join public.tournament_lobbies as l on l.id = m.lobby_id
    where l.session_id = sess.id
      and m.status = 'completed'
      and (
        not exists (
          select 1 from public.match_results as r
          where r.tournament_match_id = m.id
        )
        or exists (
          select 1 from public.match_results as r
          where r.tournament_match_id = m.id
            and r.status = 'draft'
        )
      )
  ) then
    raise exception 'Enter and finalize all results for this session before marking qualifiers.'
      using errcode = 'P4408';
  end if;

  for lobby in
    select l.*
    from public.tournament_lobbies as l
    where l.session_id = sess.id
      and l.status <> 'cancelled'
    order by l.lobby_order, l.id
  loop
    filled := 0;
    cutoff_points := null;

    for standing in
      select
        agg.registration_id,
        agg.team_id,
        agg.pts,
        agg.kills,
        (row_number() over (
          order by agg.pts desc, agg.kills desc, agg.registration_id
        ))::int as rnk,
        exists (
          select 1
          from public.tournament_stage_qualifiers as q
          where q.stage_id = stg.id
            and q.team_id = agg.team_id
            and q.status = 'active'
        ) as already_qualified
      from (
        select
          r.tournament_registration_id as registration_id,
          reg.team_id as team_id,
          sum(r.total_points)::int as pts,
          sum(r.kills)::int as kills
        from public.match_results as r
        join public.tournament_matches as m on m.id = r.tournament_match_id
        join public.tournament_registrations as reg on reg.id = r.tournament_registration_id
        where m.lobby_id = lobby.id
          and r.status = 'final'
        group by r.tournament_registration_id, reg.team_id
      ) as agg
      order by agg.pts desc, agg.kills desc, agg.registration_id
    loop
      -- Already recorded from THIS session? (Idempotent re-run.)
      select q.id into existing_qualifier_id
      from public.tournament_stage_qualifiers as q
      where q.qualified_from_session_id = sess.id
        and q.registration_id = standing.registration_id
        and q.status = 'active'
      limit 1;

      if standing.already_qualified and existing_qualifier_id is null then
        -- Qualified earlier in this stage: the slot slides down to the next
        -- team, and this team is told they were already qualified.
        select exists (
          select 1
          from public.team_notifications as n
          where n.team_id = standing.team_id
            and n.tournament_id = sess.tournament_id
            and n.type = 'already_qualified'
            and n.metadata ->> 'session_id' = sess.id::text
        ) into notice_exists;

        if not notice_exists then
          perform public.levelledup__notify_team(
            standing.team_id,
            sess.tournament_id,
            'already_qualified',
            'Already qualified',
            'Your team finished in the qualifying places again in '
              || coalesce(sess.display_name, 'this session')
              || ', but you were already qualified from this stage. Your free '
              || 'entry for the next stage still stands - no new entry was created.',
            jsonb_build_object(
              'session_id', sess.id::text,
              'stage_id', stg.id::text,
              'lobby_id', lobby.id::text,
              'rank', standing.rnk,
              'total_points', standing.pts
            )
          );
        end if;

        already_list := already_list || jsonb_build_object(
          'team_id', standing.team_id,
          'rank', standing.rnk,
          'total_points', standing.pts,
          'lobby_id', lobby.id
        );
        continue;
      end if;

      -- Fill the N slots; everyone tied with the last slot joins in.
      if cutoff_points is null then
        filled := filled + 1;
        if filled >= slots then
          cutoff_points := standing.pts;
        end if;
      elsif standing.pts < cutoff_points then
        exit; -- below the tie band: this lobby is done
      end if;

      if existing_qualifier_id is null then
        insert into public.tournament_stage_qualifiers (
          tournament_id, stage_id, qualified_from_session_id, lobby_id,
          registration_id, team_id, rank, total_points, total_kills,
          method, qualified_by, source_provenance, request_id
        ) values (
          sess.tournament_id, stg.id, sess.id, lobby.id,
          standing.registration_id, standing.team_id, standing.rnk,
          standing.pts, standing.kills,
          'auto', auth.uid(),
          jsonb_build_object(
            'slots', slots,
            'lobby_code', lobby.lobby_code,
            'mark_request_id', p_request_id::text
          ),
          gen_random_uuid()
        )
        returning id into new_qualifier_id;

        grant_result := public.levelledup__grant_earned_session_entry(new_qualifier_id);
        grant_ok := coalesce((grant_result ->> 'ok')::boolean, false);

        perform public.levelledup__notify_team(
          standing.team_id,
          sess.tournament_id,
          'qualified',
          'Your team qualified!',
          'Your team finished #' || standing.rnk || ' in '
            || coalesce(lobby.display_label, lobby.lobby_code)
            || ' and qualified for the next stage. '
            || case
                 when grant_ok then 'Your free entry for the next stage is ready.'
                 else 'Note: ' || coalesce(
                   grant_result ->> 'reason',
                   'the free entry could not be created yet.'
                 )
               end,
          jsonb_build_object(
            'qualifier_id', new_qualifier_id::text,
            'session_id', sess.id::text,
            'stage_id', stg.id::text,
            'lobby_id', lobby.id::text,
            'rank', standing.rnk,
            'total_points', standing.pts,
            'total_kills', standing.kills,
            'entry_granted', grant_ok
          )
        );

        qualified_list := qualified_list || jsonb_build_object(
          'team_id', standing.team_id,
          'qualifier_id', new_qualifier_id,
          'rank', standing.rnk,
          'total_points', standing.pts,
          'total_kills', standing.kills,
          'lobby_id', lobby.id,
          'entry_granted', grant_ok,
          'entry_id', grant_result ->> 'entry_id'
        );

        if not grant_ok then
          entry_skipped_list := entry_skipped_list || jsonb_build_object(
            'team_id', standing.team_id,
            'qualifier_id', new_qualifier_id,
            'reason', grant_result ->> 'reason'
          );
        end if;
      else
        -- Re-run: qualifier already recorded; backfill the entry if missing.
        grant_result := public.levelledup__grant_earned_session_entry(existing_qualifier_id);
        grant_ok := coalesce((grant_result ->> 'ok')::boolean, false);

        qualified_list := qualified_list || jsonb_build_object(
          'team_id', standing.team_id,
          'qualifier_id', existing_qualifier_id,
          'rank', standing.rnk,
          'already_recorded', true,
          'entry_granted', grant_ok
        );
      end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'session_id', sess.id,
    'stage_id', stg.id,
    'slots', slots,
    'qualified', qualified_list,
    'already_qualified_notified', already_list,
    'entries_skipped', entry_skipped_list
  );
end;
$$;

comment on function public.levelledup_mark_session_qualifiers(uuid, uuid) is
  'Admin: after a session''s matches are done and results are final, records the top N of each lobby as qualifiers (ties included; already-qualified teams skipped with the slot sliding down), creates their free next-stage entries, and notifies every team.';

-- ----------------------------------------------------------------------------
-- 6. Manual mark: the admin's hand-fix when the machine got it wrong.
--    Reason (10-1000 chars) is mandatory: it is the audit trail.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_admin_mark_qualifier(
  p_session_id uuid,
  p_registration_id uuid,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  sess public.tournament_stage_sessions;
  stg public.tournament_stages;
  reg public.tournament_registrations;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  existing_id uuid;
  new_qualifier_id uuid;
  grant_result jsonb;
  grant_ok boolean;
  lobby_id uuid;
  pts integer := 0;
  kills integer := 0;
  rnk integer := null;
  team_name text;
begin
  perform public.levelledup_require_admin('admin');

  if p_session_id is null
    or p_registration_id is null
    or p_request_id is null
    or char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'Session, registration, request ID and a 10-1000 character reason are required.'
      using errcode = '22023';
  end if;

  -- Idempotent retry: the same request never marks twice.
  select q.id into existing_id
  from public.tournament_stage_qualifiers as q
  where q.request_id = p_request_id
  limit 1;

  if existing_id is not null then
    return jsonb_build_object('qualifier_id', existing_id, 'duplicate', true);
  end if;

  select s.* into sess
  from public.tournament_stage_sessions as s
  where s.id = p_session_id
  for share;

  if sess.id is null then
    raise exception 'Session not found.' using errcode = 'P4414';
  end if;

  select st.* into stg
  from public.tournament_stages as st
  where st.id = sess.stage_id;

  select r.* into reg
  from public.tournament_registrations as r
  where r.id = p_registration_id
  for share;

  if reg.id is null or reg.tournament_id <> sess.tournament_id then
    raise exception 'Registration not found in this tournament.'
      using errcode = 'P4414';
  end if;

  if reg.status <> 'confirmed' then
    raise exception 'Only a confirmed registration can be marked as qualified.'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.tournament_stage_qualifiers as q
    where q.stage_id = stg.id
      and q.team_id = reg.team_id
      and q.status = 'active'
  ) then
    raise exception 'This team is already qualified for this stage.'
      using errcode = '22023';
  end if;

  -- Best-effort standings context: their lobby, points, kills, rank.
  select agg.lobby_id, agg.pts, agg.kills
  into lobby_id, pts, kills
  from (
    select
      m.lobby_id as lobby_id,
      sum(r.total_points)::int as pts,
      sum(r.kills)::int as kills,
      count(*) as matches
    from public.match_results as r
    join public.tournament_matches as m on m.id = r.tournament_match_id
    where r.tournament_registration_id = reg.id
      and r.status = 'final'
      and m.lobby_id in (
        select l.id from public.tournament_lobbies as l
        where l.session_id = sess.id and l.status <> 'cancelled'
      )
    group by m.lobby_id
    order by matches desc, pts desc
    limit 1
  ) as agg;

  if lobby_id is null then
    select l.id into lobby_id
    from public.tournament_lobbies as l
    where l.session_id = sess.id and l.status <> 'cancelled'
    order by l.lobby_order, l.id
    limit 1;
  end if;

  if lobby_id is null then
    raise exception 'This session has no lobbies.' using errcode = '22023';
  end if;

  -- No result rows -> the SELECT INTO above yields NULLs; keep honest zeroes.
  pts := coalesce(pts, 0);
  kills := coalesce(kills, 0);

  select count(*)::int + 1 into rnk
  from (
    select
      r.tournament_registration_id as registration_id,
      sum(r.total_points)::int as pts,
      sum(r.kills)::int as kills
    from public.match_results as r
    join public.tournament_matches as m on m.id = r.tournament_match_id
    where m.lobby_id = lobby_id
      and r.status = 'final'
    group by r.tournament_registration_id
  ) as standings
  where standings.pts > pts
     or (standings.pts = pts and standings.kills > kills)
     or (standings.pts = pts and standings.kills = kills
         and standings.registration_id < reg.id);

  insert into public.tournament_stage_qualifiers (
    tournament_id, stage_id, qualified_from_session_id, lobby_id,
    registration_id, team_id, rank, total_points, total_kills,
    method, qualified_by, source_provenance, request_id
  ) values (
    sess.tournament_id, stg.id, sess.id, lobby_id,
    reg.id, reg.team_id, rnk, pts, kills,
    'manual', auth.uid(),
    jsonb_build_object('manual_reason', normalized_reason),
    p_request_id
  )
  returning id into new_qualifier_id;

  grant_result := public.levelledup__grant_earned_session_entry(new_qualifier_id);
  grant_ok := coalesce((grant_result ->> 'ok')::boolean, false);

  select t.name into team_name from public.teams as t where t.id = reg.team_id;

  perform public.levelledup__notify_team(
    reg.team_id,
    sess.tournament_id,
    'qualified',
    'Your team qualified!',
    'An admin marked ' || coalesce(team_name, 'your team')
      || ' as qualified from ' || coalesce(sess.display_name, 'this session')
      || '. '
      || case
           when grant_ok then 'Your free entry for the next stage is ready.'
           else 'Note: ' || coalesce(
             grant_result ->> 'reason',
             'the free entry could not be created yet.'
           )
         end,
    jsonb_build_object(
      'qualifier_id', new_qualifier_id::text,
      'session_id', sess.id::text,
      'stage_id', stg.id::text,
      'method', 'manual',
      'reason', normalized_reason,
      'entry_granted', grant_ok
    )
  );

  return jsonb_build_object(
    'qualifier_id', new_qualifier_id,
    'entry_granted', grant_ok,
    'entry_id', grant_result ->> 'entry_id',
    'entry_skip_reason', grant_result ->> 'reason'
  );
end;
$$;

comment on function public.levelledup_admin_mark_qualifier(uuid, uuid, text, uuid) is
  'Admin: manually marks a team as qualified (the hand-fix when the machine got it wrong). Reason is mandatory. Creates the free next-stage entry and notifies the team.';

-- ----------------------------------------------------------------------------
-- 7. Manual unmark: revoke a qualification. The unused free entry is
--    cancelled; an already-played entry stays as history.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_admin_unmark_qualifier(
  p_qualifier_id uuid,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  qualifier public.tournament_stage_qualifiers;
  entry public.tournament_session_entries;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  entry_cancelled boolean := false;
  entry_left_reason text := null;
  team_name text;
begin
  perform public.levelledup_require_admin('admin');

  if p_qualifier_id is null
    or p_request_id is null
    or char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'Qualifier, request ID and a 10-1000 character reason are required.'
      using errcode = '22023';
  end if;

  select q.* into qualifier
  from public.tournament_stage_qualifiers as q
  where q.id = p_qualifier_id
  for update;

  if qualifier.id is null then
    raise exception 'Qualifier not found.' using errcode = 'P4414';
  end if;

  if qualifier.status = 'revoked' then
    return jsonb_build_object(
      'qualifier_id', qualifier.id, 'already_revoked', true
    );
  end if;

  update public.tournament_stage_qualifiers
  set status = 'revoked',
      revoked_by = auth.uid(),
      revoked_at = now(),
      revoke_reason = normalized_reason
  where id = qualifier.id;

  if qualifier.earned_entry_id is not null then
    select e.* into entry
    from public.tournament_session_entries as e
    where e.id = qualifier.earned_entry_id
    for update;

    if entry.id is not null and entry.status = 'active' then
      if public.levelledup_session_entry_consumed(entry.id) then
        -- Already played: history stays, the team keeps what they earned.
        entry_left_reason :=
          'The earned entry was already used, so it stays as history.';
      else
        update public.tournament_session_entries
        set status = 'cancelled',
            cancelled_by = auth.uid(),
            cancelled_at = now(),
            cancellation_reason = normalized_reason,
            cancellation_request_id = p_request_id
        where id = entry.id;
        entry_cancelled := true;
      end if;
    end if;
  end if;

  select t.name into team_name from public.teams as t where t.id = qualifier.team_id;

  perform public.levelledup__notify_team(
    qualifier.team_id,
    qualifier.tournament_id,
    'qualification_revoked',
    'Qualification corrected',
    'An admin corrected the qualification of ' || coalesce(team_name, 'your team')
      || ': it no longer counts. '
      || case
           when entry_cancelled then 'The unused free entry was cancelled.'
           when entry_left_reason is not null then entry_left_reason
           else 'There was no free entry to cancel.'
         end,
    jsonb_build_object(
      'qualifier_id', qualifier.id::text,
      'reason', normalized_reason,
      'entry_cancelled', entry_cancelled
    )
  );

  return jsonb_build_object(
    'qualifier_id', qualifier.id,
    'revoked', true,
    'entry_cancelled', entry_cancelled,
    'entry_left_reason', entry_left_reason
  );
end;
$$;

comment on function public.levelledup_admin_unmark_qualifier(uuid, text, uuid) is
  'Admin: revokes a qualification. Cancels the free entry when still unused; an already-played entry stays as history. The team is notified.';

-- ----------------------------------------------------------------------------
-- 8. Read helper for the admin UI: who qualified from a stage.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_get_stage_qualifiers(
  p_stage_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  result jsonb;
begin
  perform public.levelledup_require_admin('admin');

  if p_stage_id is null then
    raise exception 'Stage is required.' using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'qualifier_id', q.id,
        'team_id', q.team_id,
        'team_name', t.name,
        'session_id', q.qualified_from_session_id,
        'session_name', sess.display_name,
        'lobby_id', q.lobby_id,
        'lobby_code', l.lobby_code,
        'rank', q.rank,
        'total_points', q.total_points,
        'total_kills', q.total_kills,
        'method', q.method,
        'status', q.status,
        'qualified_at', q.qualified_at,
        'revoke_reason', q.revoke_reason,
        'earned_entry_id', q.earned_entry_id
      )
      order by q.qualified_at, t.name
    ),
    '[]'::jsonb
  ) into result
  from public.tournament_stage_qualifiers as q
  join public.teams as t on t.id = q.team_id
  join public.tournament_stage_sessions as sess on sess.id = q.qualified_from_session_id
  join public.tournament_lobbies as l on l.id = q.lobby_id
  where q.stage_id = p_stage_id;

  return result;
end;
$$;

comment on function public.levelledup_get_stage_qualifiers(uuid) is
  'Admin read helper: every qualifier of a stage with team, session, lobby, rank and entry links.';

-- ----------------------------------------------------------------------------
-- 9. The next-entry card gets smart about qualification.
--    Qualified  -> next stage, first open session, FREE (+ a paid replay
--                  option for the stage they qualified from).
--    Not qualified -> paid retry of the earliest open stage (unchanged).
--    Nothing enterable -> closed (the UI shows the top-up button).
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_get_next_entry_option(
  p_tournament_id uuid,
  p_team_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  target_stage public.tournament_stages;
  target_session public.tournament_stage_sessions;
  best_qual public.tournament_stage_qualifiers;
  best_stage_number integer;
  best_stage_name text;
  next_stage public.tournament_stages;
  free_session public.tournament_stage_sessions;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  select tournament_registration.* into registration
  from public.tournament_registrations as tournament_registration
  where tournament_registration.tournament_id = p_tournament_id
    and tournament_registration.team_id = p_team_id
  order by tournament_registration.created_at desc, tournament_registration.id desc
  limit 1;

  if registration.id is null then
    return jsonb_build_object('kind', 'no_registration');
  end if;

  -- The highest stage this team actively qualified from, if any.
  select q.* into best_qual
  from public.tournament_stage_qualifiers as q
  join public.tournament_stages as st on st.id = q.stage_id
  where q.tournament_id = p_tournament_id
    and q.team_id = p_team_id
    and q.status = 'active'
  order by st.stage_number desc, q.qualified_at desc, q.id desc
  limit 1;

  if best_qual.id is not null then
    select st.stage_number, st.display_name
    into best_stage_number, best_stage_name
    from public.tournament_stages as st
    where st.id = best_qual.stage_id;

    -- The earned road: the immediate next stage, when it is still alive.
    select st.* into next_stage
    from public.tournament_stages as st
    where st.tournament_id = p_tournament_id
      and st.stage_number = best_stage_number + 1
      and st.status not in ('completed', 'cancelled')
    limit 1;

    if next_stage.id is not null then
      select sess.* into free_session
      from public.tournament_stage_sessions as sess
      where sess.stage_id = next_stage.id
        and sess.status in ('planned', 'open')
        and not public.levelledup_session_has_started(sess.id)
      order by sess.session_number, sess.id
      limit 1;

      if free_session.id is not null then
        return jsonb_build_object(
          'kind', 'qualified_next_stage_free',
          'stage_id', next_stage.id,
          'stage_name', next_stage.display_name,
          'session_id', free_session.id,
          'session_name', free_session.display_name,
          'fee_minor', 0,
          'currency', free_session.fee_currency,
          'qualifier_id', best_qual.id,
          'qualified_from_stage_id', best_qual.stage_id,
          'qualified_from_stage_name', best_stage_name,
          'qualifier_rank', best_qual.rank
        );
      end if;
    end if;

    -- No free road left: a qualified team may still replay the stage it
    -- qualified from, but it pays like everyone else.
    select sess.* into target_session
    from public.tournament_stage_sessions as sess
    where sess.stage_id = best_qual.stage_id
      and sess.status in ('planned', 'open')
      and not public.levelledup_session_has_started(sess.id)
    order by sess.session_number, sess.id
    limit 1;

    if target_session.id is not null then
      return jsonb_build_object(
        'kind', 'qualified_stage_replay_paid',
        'stage_id', best_qual.stage_id,
        'stage_name', best_stage_name,
        'session_id', target_session.id,
        'session_name', target_session.display_name,
        'fee_minor', target_session.entry_fee_minor,
        'currency', target_session.fee_currency,
        'qualifier_id', best_qual.id
      );
    end if;

    return jsonb_build_object('kind', 'closed');
  end if;

  -- Not qualified: the earliest stage that still has an enterable session.
  select stage.* into target_stage
  from public.tournament_stages as stage
  where stage.tournament_id = p_tournament_id
    and stage.status not in ('completed', 'cancelled')
    and exists (
      select 1
      from public.tournament_stage_sessions as session
      where session.stage_id = stage.id
        and session.status in ('planned', 'open')
        and not public.levelledup_session_has_started(session.id)
    )
  order by stage.stage_number
  limit 1;

  if target_stage.id is null then
    return jsonb_build_object('kind', 'closed');
  end if;

  select session.* into target_session
  from public.tournament_stage_sessions as session
  where session.stage_id = target_stage.id
    and session.status in ('planned', 'open')
    and not public.levelledup_session_has_started(session.id)
  order by session.session_number, session.id
  limit 1;

  return jsonb_build_object(
    'kind', case
      when target_session.entry_fee_minor > 0 then 'next_stage_paid'
      else 'next_stage_free'
    end,
    'stage_id', target_stage.id,
    'stage_name', target_stage.display_name,
    'session_id', target_session.id,
    'session_name', target_session.display_name,
    'fee_minor', target_session.entry_fee_minor,
    'currency', target_session.fee_currency
  );
end;
$$;

comment on function public.levelledup_get_next_entry_option(uuid, uuid) is
  'Read RPC for the entry UI. Qualified teams: next stage free (qualified_next_stage_free), or a paid replay of their stage (qualified_stage_replay_paid). Everyone else: the earliest enterable stage, paid or free. Closed when nothing remains.';

-- ----------------------------------------------------------------------------
-- 10. Owners and grants.
-- ----------------------------------------------------------------------------

alter function public.levelledup__notify_team(uuid, uuid, text, text, text, jsonb)
  owner to postgres;
alter function public.levelledup__grant_earned_session_entry(uuid)
  owner to postgres;
alter function public.levelledup_mark_session_qualifiers(uuid, uuid)
  owner to postgres;
alter function public.levelledup_admin_mark_qualifier(uuid, uuid, text, uuid)
  owner to postgres;
alter function public.levelledup_admin_unmark_qualifier(uuid, text, uuid)
  owner to postgres;
alter function public.levelledup_get_stage_qualifiers(uuid)
  owner to postgres;
alter function public.levelledup_get_next_entry_option(uuid, uuid)
  owner to postgres;

-- Internal helpers: no direct calls from any role.
revoke all on function public.levelledup__notify_team(uuid, uuid, text, text, text, jsonb)
  from public, anon, authenticated;
revoke all on function public.levelledup__grant_earned_session_entry(uuid)
  from public, anon, authenticated;

-- Admin jobs: callable by signed-in users, gated inside by require_admin.
revoke all on function public.levelledup_mark_session_qualifiers(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_mark_session_qualifiers(uuid, uuid)
  to authenticated;

revoke all on function public.levelledup_admin_mark_qualifier(uuid, uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_mark_qualifier(uuid, uuid, text, uuid)
  to authenticated;

revoke all on function public.levelledup_admin_unmark_qualifier(uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_unmark_qualifier(uuid, text, uuid)
  to authenticated;

revoke all on function public.levelledup_get_stage_qualifiers(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_get_stage_qualifiers(uuid)
  to authenticated;

-- The card stays readable by signed-in users (unchanged from before).
revoke all on function public.levelledup_get_next_entry_option(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_get_next_entry_option(uuid, uuid)
  to authenticated;

commit;
