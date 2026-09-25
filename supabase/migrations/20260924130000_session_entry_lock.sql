-- ============================================================================
-- 20260924130000_session_entry_lock.sql
--
-- SESSION ENTRY LOCK (Haider's rules, 2026-09-24 / 2026-09-25).
--
-- Handoff rules implemented here:
--   * "A paid entry covers exactly one session only." Refined: one payment =
--     one session PLAYED; an unused mark may slide to a later session of the
--     SAME stage, never into another stage.
--   * "If a team fails and wants to play the next session, they pay for that
--     session (retry = pay per session)."
--   * "If they win/qualify, they get the first session of the next stage FREE."
--   * "If you choose nothing, you will play the next session. Choose only if
--     you want to play that exact session."
--   * Trying to enter a started session: "This session is already closed."
--   * Lobby creation never mixes entries from different sessions (already
--     enforced by levelledup_validate_assignment_session_entry).
--
-- What this migration does:
--   1. levelledup_session_has_started(uuid) — one shared predicate: a session
--      has started when any of its matches is 'live' or 'completed'. This is
--      the same predicate as the 20260924120000 lobby block. Match STATUS is
--      the source of truth: a merely scheduled (or past-scheduled-time) match
--      does not close entry.
--   2. Trigger on tournament_session_entries — no ACTIVE entry (any source:
--      paid, earned, credit, admin_grant, registration, free) may be created
--      for, moved into, or reactivated into a started session. Cancelling an
--      entry is always allowed.
--   3. Captain session choice (levelledup_select_registration_initial_session)
--      and the registration initial-session trigger now reject started
--      sessions with "This session is already closed."
--   4. Payment submission (levelledup_submit_manual_tournament_payment):
--      if the captain chose nothing, the payment is pinned to the NEXT open
--      Stage 1 session automatically (and stored on the registration); a
--      started session is rejected with "This session is already closed."
--   5. Registration review (levelledup_admin_review_tournament_registration)
--      gains an optional p_session_id override: admin override wins, otherwise
--      the captain's chosen session. The old 2-argument overload is dropped so
--      PostgREST never sees two ambiguous signatures.
--   6. levelledup_session_entry_consumed(uuid) — true when the entry's team
--      actually played at least one match in the entry's session (from
--      match_participations). Shared by the move RPC now and by the future
--      cancellation/refund file.
--   7. levelledup_admin_move_session_entry — admin-only move of an UNUSED
--      entry mark to a later session of the SAME stage (cross-stage moves are
--      refused for every role, including super-admin), when there is room.
--   8. levelledup_get_next_entry_option — read RPC for the web UI: returns
--      the next enterable stage/session (paid or free) or 'closed', so the UI
--      can show the next-stage card or "Entries are closed for this stage."
--
-- JUDGEMENT CALL (flagged to Haider): the old
-- "scheduled_start_at <= now()" block on session selection / payment /
-- approval is REPLACED by the match-status rule everywhere in this file. A
-- session whose scheduled time passed but whose matches never started still
-- accepts entry — consistent with the lobby rule ("as the first match start
-- no new team can join"). If Haider wants the clock back as well, it is a
-- one-line revert per function.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Shared "session has started" predicate.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_session_has_started(p_session_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
begin
  if p_session_id is null then
    return false;
  end if;

  return exists (
    select 1
    from public.tournament_matches as matches
    join public.tournament_lobbies as lobbies
      on lobbies.id = matches.lobby_id
    where lobbies.session_id = p_session_id
      and matches.status in ('live', 'completed')
  );
end;
$$;

comment on function public.levelledup_session_has_started(uuid) is
  'True when any match of the session is live/completed. Match status is the source of truth; scheduled-but-unstarted matches never count.';

-- ----------------------------------------------------------------------------
-- 2. Hard block: no ACTIVE session entry may target a started session.
--    Covers creation (all sources), session moves, and reactivation.
--    Cancelling an entry is always allowed.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_guard_session_entry_not_started()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.status = 'active'
    and public.levelledup_session_has_started(new.session_id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  return new;
end;
$$;

drop trigger if exists tournament_session_entries_no_started_session
  on public.tournament_session_entries;

create trigger tournament_session_entries_no_started_session
before insert or update of session_id, status
on public.tournament_session_entries
for each row
execute function public.levelledup_guard_session_entry_not_started();

comment on function public.levelledup_guard_session_entry_not_started() is
  'Trigger guard: an active session entry (any source) can never target a session whose matches already started.';

-- ----------------------------------------------------------------------------
-- 3. Captain session choice: reject started sessions.
--    (Same signature; the old scheduled-time block is replaced by the
--    match-status rule — see file header.)
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_select_registration_initial_session(
  p_registration_id uuid,
  p_session_id uuid
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to select an initial Session.'
      using errcode = '42501';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4402';
  end if;

  if not public.levelledup_is_team_manager(registration.team_id) then
    raise exception 'Only the current active team Captain can select the initial Session.'
      using errcode = '42501';
  end if;

  if registration.status <> 'pending' then
    raise exception 'Only a pending registration can select its initial Session.'
      using errcode = 'P4420';
  end if;

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = p_session_id
  for share;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = selected_session.stage_id
  for share;

  if selected_session.id is null
    or selected_session.tournament_id <> registration.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> registration.tournament_id
    or selected_stage.stage_number <> 1
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'The initial Session must belong to Stage 1 of the registration Tournament.'
      using errcode = '23503';
  end if;

  if selected_session.status not in ('planned', 'open') then
    raise exception 'Select a future Stage 1 Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  if public.levelledup_session_has_started(selected_session.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  if registration.initial_session_id is not distinct from selected_session.id then
    return registration;
  end if;

  update public.tournament_registrations
  set initial_session_id = selected_session.id
  where id = registration.id
  returning * into registration;

  return registration;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Registration initial-session trigger: same started-session rule as a
--    backstop for any direct write of initial_session_id.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_validate_registration_initial_session()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
begin
  if tg_op = 'INSERT' and new.initial_session_id is null then
    return new;
  end if;

  if tg_op = 'UPDATE'
    and new.initial_session_id is not distinct from old.initial_session_id then
    return new;
  end if;

  if new.initial_session_id is null then
    raise exception 'An initial Session selection cannot be cleared; select another permitted Stage 1 Session.'
      using errcode = '22023';
  end if;

  if new.status <> 'pending' then
    raise exception 'Only a pending registration can select its initial Session.'
      using errcode = 'P4420';
  end if;

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = new.initial_session_id;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = selected_session.stage_id;

  if selected_session.id is null
    or selected_session.tournament_id <> new.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> new.tournament_id
    or selected_stage.stage_number <> 1
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'The initial Session must belong to Stage 1 of the registration Tournament.'
      using errcode = '23503';
  end if;

  if selected_session.status not in ('planned', 'open') then
    raise exception 'Select a future Stage 1 Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  if public.levelledup_session_has_started(selected_session.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  if tg_op = 'UPDATE' and exists (
      select 1 from public.tournament_registration_payments as payment
      where payment.registration_id = new.id
    ) then
    raise exception 'The initial Session cannot change after a payment attempt exists.'
      using errcode = 'P4422';
  end if;

  if tg_op = 'UPDATE' and exists (
      select 1 from public.tournament_registration_paid_entries as paid_entry
      where paid_entry.registration_id = new.id
    ) then
    raise exception 'The initial Session cannot change after paid allocation history exists.'
      using errcode = 'P4422';
  end if;

  if tg_op = 'UPDATE' and exists (
      select 1 from public.tournament_session_entries as session_entry
      where session_entry.registration_id = new.id
    ) then
    raise exception 'The initial Session cannot change after participation history exists.'
      using errcode = 'P4422';
  end if;

  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Payment submission: default to the NEXT open Stage 1 session when the
--    captain chose nothing ("If you choose nothing, you will play the next
--    session"); reject started sessions. Same 2-argument signature.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_submit_manual_tournament_payment(
  p_registration_id uuid,
  p_reference_id text
)
returns public.tournament_registration_payments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_reference text := btrim(coalesce(p_reference_id, ''));
  registration public.tournament_registrations;
  tournament public.tournaments;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
  created_payment public.tournament_registration_payments;
  defaulted_session boolean := false;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to submit payment.'
      using errcode = '42501';
  end if;

  if char_length(normalized_reference) not between 3 and 120 then
    raise exception 'Enter a valid transaction or reference ID.'
      using errcode = 'P4501';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4502';
  end if;

  if not public.levelledup_is_active_team_captain(registration.team_id) then
    raise exception 'Only the active team Captain can submit payment.'
      using errcode = '42501';
  end if;

  if registration.status <> 'pending'
    or registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the pending tournament Squad before submitting payment.'
      using errcode = 'P4503';
  end if;

  select current_tournament.* into tournament
  from public.tournaments as current_tournament
  where current_tournament.id = registration.tournament_id
  for share;

  if registration.initial_session_id is null then
    -- The captain chose nothing: default to the next open Stage 1 session.
    select current_session.* into selected_session
    from public.tournament_stage_sessions as current_session
    join public.tournament_stages as current_stage
      on current_stage.id = current_session.stage_id
    where current_session.tournament_id = registration.tournament_id
      and current_stage.stage_number = 1
      and current_stage.status not in ('completed', 'cancelled')
      and current_session.status in ('planned', 'open')
      and not public.levelledup_session_has_started(current_session.id)
    order by current_session.session_number, current_session.id
    limit 1;

    if selected_session.id is null then
      raise exception 'No upcoming Stage 1 session is available for entry.'
        using errcode = 'P4420';
    end if;

    defaulted_session := true;
  else
    select current_session.* into selected_session
    from public.tournament_stage_sessions as current_session
    where current_session.id = registration.initial_session_id
    for share;
  end if;

  select current_stage.* into selected_stage
  from public.tournament_stages as current_stage
  where current_stage.id = selected_session.stage_id
  for share;

  if tournament.id is null or selected_session.id is null
    or selected_session.tournament_id <> registration.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> registration.tournament_id
    or selected_stage.stage_number <> 1
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'Select an exact Stage 1 Session before submitting payment.'
      using errcode = 'P4420';
  end if;

  if selected_session.status not in ('planned', 'open') then
    raise exception 'Payment requires a future selected Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  if public.levelledup_session_has_started(selected_session.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  if tournament.entry_fee_minor = 0 then
    raise exception 'This Tournament has no initial registration fee; payment is not required.'
      using errcode = 'P4504';
  end if;

  if tournament.entry_fee_minor > 2147483647 then
    raise exception 'The Tournament initial registration fee exceeds the existing payment amount range.'
      using errcode = '22003';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(registration.id::text || ':payment', 0)
  );

  if exists (
    select 1
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.status in ('pending', 'verified')
  ) then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
  end if;

  if defaulted_session then
    -- Persist the default so approval, review and history all agree on it.
    update public.tournament_registrations
    set initial_session_id = selected_session.id
    where id = registration.id;
  end if;

  insert into public.tournament_registration_payments (
    registration_id, tournament_id, team_id, session_id,
    payment_method, status, expected_amount_minor, currency,
    reference_id, submitted_by
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    selected_session.id, 'manual', 'pending',
    tournament.entry_fee_minor::integer, tournament.currency,
    normalized_reference, authenticated_user_id
  ) returning * into created_payment;

  return created_payment;
exception
  when unique_violation then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
end;
$$;

comment on function public.levelledup_submit_manual_tournament_payment(uuid, text) is
  'Captain-only initial manual payment submission. Uses the captain''s chosen Stage 1 session, defaulting to the next open Stage 1 session when nothing was chosen. Started sessions are rejected.';

-- ----------------------------------------------------------------------------
-- 6. Registration review: optional admin session override.
--    The old 2-argument overload is dropped so PostgREST sees exactly one
--    signature; existing 2-argument calls keep working via the default.
-- ----------------------------------------------------------------------------

drop function if exists public.levelledup_admin_review_tournament_registration(uuid, text);

create function public.levelledup_admin_review_tournament_registration(
  p_registration_id uuid,
  p_decision text,
  p_session_id uuid default null
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  decision text := lower(btrim(coalesce(p_decision, '')));
  registration public.tournament_registrations;
  selected_tournament public.tournaments;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
  verified_payment public.tournament_registration_payments;
  existing_entry public.tournament_session_entries;
  created_entry public.tournament_session_entries;
  confirmed_count integer;
  actor_role text;
  target_session_id uuid;
begin
  perform public.levelledup_require_admin('admin');

  if decision not in ('approve', 'reject') then
    raise exception 'Unsupported registration decision.' using errcode = 'P4401';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4402';
  end if;

  if decision = 'approve' and registration.status = 'confirmed' then
    select session_entry.* into existing_entry
    from public.tournament_session_entries as session_entry
    where session_entry.registration_id = registration.id
      and session_entry.status = 'active'
    order by session_entry.created_at, session_entry.id
    limit 1;

    if existing_entry.id is not null then
      return registration;
    end if;

    raise exception 'Confirmed registration is missing its Session Entry; manual investigation is required.'
      using errcode = 'P4423';
  end if;

  if registration.status <> 'pending' then
    raise exception 'Only a pending registration can be reviewed.' using errcode = 'P4403';
  end if;

  if decision = 'reject' then
    update public.tournament_registrations
    set status = 'rejected', reviewed_by = auth.uid()
    where id = registration.id
    returning * into registration;
    return registration;
  end if;

  select tournament.* into selected_tournament
  from public.tournaments as tournament
  where tournament.id = registration.tournament_id
  for update;

  if registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the tournament Squad before approval.' using errcode = 'P4409';
  end if;

  if selected_tournament.id is null
    or selected_tournament.status not in ('registration_open', 'registration_closed')
    or now() >= selected_tournament.scheduled_start_at then
    raise exception 'Registration cannot be approved after the tournament starts or leaves registration operations.'
      using errcode = 'P4404';
  end if;

  if selected_tournament.entry_fee_minor > 0 then
    select payment.* into verified_payment
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.tournament_id = registration.tournament_id
      and payment.team_id = registration.team_id
      and payment.status = 'verified'
      and payment.expected_amount_minor::bigint = selected_tournament.entry_fee_minor
      and payment.currency = selected_tournament.currency
    order by payment.submitted_at, payment.id
    limit 1
    for update;

    if verified_payment.id is null then
      raise exception 'Verify the Tournament initial registration payment before approving this registration.'
        using errcode = 'P4508';
    end if;
  end if;

  -- Target session: an explicit admin override wins; otherwise the captain's
  -- chosen initial session (defaulted to the next open session at payment
  -- time when the captain chose nothing).
  target_session_id := coalesce(p_session_id, registration.initial_session_id);

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = target_session_id
  for update;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = selected_session.stage_id
  for share;

  if selected_session.id is null
    or selected_session.tournament_id <> registration.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> registration.tournament_id
    or selected_stage.stage_number <> 1
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'Select a valid initial Stage 1 Session before approving this registration.'
      using errcode = 'P4420';
  end if;

  if selected_session.status not in ('planned', 'open') then
    raise exception 'The selected initial Session no longer permits a future entry.'
      using errcode = 'P4421';
  end if;

  if public.levelledup_session_has_started(selected_session.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  select count(*)::integer into confirmed_count
  from public.tournament_registrations as confirmed_registration
  where confirmed_registration.tournament_id = selected_tournament.id
    and confirmed_registration.status = 'confirmed';

  if confirmed_count >= selected_tournament.max_team_slots then
    raise exception 'The tournament has reached its overall team capacity.' using errcode = 'P4005';
  end if;

  update public.tournament_registrations
  set status = 'confirmed', reviewed_by = auth.uid()
  where id = registration.id
  returning * into registration;

  actor_role := public.levelledup_current_admin_role();

  insert into public.tournament_session_entries (
    tournament_id, stage_id, session_id, registration_id, team_id,
    source_type, source_occurred_at, source_provenance, reason,
    request_id, created_by, created_by_role
  ) values (
    registration.tournament_id, selected_stage.id, selected_session.id,
    registration.id, registration.team_id,
    case when selected_tournament.entry_fee_minor = 0 then 'free' else 'registration' end,
    case when selected_tournament.entry_fee_minor = 0
      then registration.confirmed_at else verified_payment.reviewed_at end,
    case when selected_tournament.entry_fee_minor = 0 then
      jsonb_build_object(
        'entitlement', 'initial_registration_confirmation',
        'registration_id', registration.id,
        'session_id', selected_session.id,
        'confirmed_by', auth.uid()
      )
    else
      jsonb_build_object(
        'entitlement', 'initial_registration_confirmation',
        'registration_id', registration.id,
        'session_id', selected_session.id,
        'payment_id', verified_payment.id,
        'payment_session_id', verified_payment.session_id,
        'admin_session_override', (p_session_id is not null and p_session_id is distinct from verified_payment.session_id),
        'confirmed_by', auth.uid()
      )
    end,
    case when selected_tournament.entry_fee_minor = 0
      then 'Initial free Session Entry created atomically with registration approval.'
      else 'Initial paid-registration Session Entry created atomically with registration approval.' end,
    gen_random_uuid(), auth.uid(), actor_role
  ) returning * into created_entry;

  return registration;
end;
$$;

comment on function public.levelledup_admin_review_tournament_registration(uuid, text, uuid) is
  'Admin-only atomic review. Optional p_session_id overrides the captain''s chosen session at approval time; started sessions are rejected.';

alter function public.levelledup_admin_review_tournament_registration(uuid, text, uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_review_tournament_registration(uuid, text, uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_review_tournament_registration(uuid, text, uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 7. Consumed helper: true when the entry's team actually played at least one
--    match in the entry's session. Consumed entries are never refunded and
--    never moved.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_session_entry_consumed(p_entry_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  entry public.tournament_session_entries;
begin
  select session_entry.* into entry
  from public.tournament_session_entries as session_entry
  where session_entry.id = p_entry_id;

  if entry.id is null then
    return false;
  end if;

  return exists (
    select 1
    from public.match_participations as participation
    join public.tournament_lobbies as lobby
      on lobby.id = participation.lobby_id
    where participation.tournament_registration_id = entry.registration_id
      and lobby.session_id = entry.session_id
  );
end;
$$;

comment on function public.levelledup_session_entry_consumed(uuid) is
  'True when the entry''s team played at least one match in the entry''s session (match_participations proof).';

-- ----------------------------------------------------------------------------
-- 8. Admin-only move of an UNUSED entry mark to a later session of the SAME
--    stage. Cross-stage moves are refused for every role, including the
--    super-admin — the rule is "it must never slide into another stage."
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_admin_move_session_entry(
  p_entry_id uuid,
  p_target_session_id uuid,
  p_reason text,
  p_request_id uuid
)
returns public.tournament_session_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  entry public.tournament_session_entries;
  target public.tournament_stage_sessions;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  total_capacity integer;
  assigned_count integer;
  moves jsonb;
begin
  perform public.levelledup_require_admin('admin');

  if p_entry_id is null
    or p_target_session_id is null
    or p_request_id is null
    or char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'Entry, target Session, request ID and a 10-1000 character reason are required.'
      using errcode = '22023';
  end if;

  select session_entry.* into entry
  from public.tournament_session_entries as session_entry
  where session_entry.id = p_entry_id
  for update;

  if entry.id is null then
    raise exception 'Session Entry not found.' using errcode = 'P4414';
  end if;

  if entry.status <> 'active' then
    raise exception 'Only an active Session Entry can be moved.' using errcode = '22023';
  end if;

  -- Idempotent retry: a repeated request_id returns the entry unchanged.
  if coalesce(entry.source_provenance -> 'session_moves', '[]'::jsonb)
       @> jsonb_build_array(jsonb_build_object('request_id', p_request_id::text)) then
    return entry;
  end if;

  if entry.session_id = p_target_session_id then
    return entry;
  end if;

  select session.* into target
  from public.tournament_stage_sessions as session
  where session.id = p_target_session_id
  for share;

  if target.id is null or target.tournament_id <> entry.tournament_id then
    raise exception 'Target Session must belong to the same Tournament.'
      using errcode = '23503';
  end if;

  if target.stage_id <> entry.stage_id then
    raise exception 'Session entries cannot move to another stage.'
      using errcode = '22023';
  end if;

  if public.levelledup_session_has_started(target.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  if public.levelledup_session_entry_consumed(entry.id) then
    raise exception 'This entry has already been used; it cannot be moved.'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.tournament_stage_assignments as assignment
    where assignment.registration_id = entry.registration_id
      and assignment.session_id = entry.session_id
      and assignment.status = 'assigned'
  ) then
    raise exception 'Unassign the team from its lobby before moving the entry.'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.tournament_session_entries as other_entry
    where other_entry.registration_id = entry.registration_id
      and other_entry.session_id = target.id
      and other_entry.status = 'active'
  ) then
    raise exception 'This team already has an active entry in the target session.'
      using errcode = '23505';
  end if;

  -- Room check, only when lobbies already exist in the target session.
  select coalesce(sum(lobby.capacity), 0)::integer into total_capacity
  from public.tournament_lobbies as lobby
  where lobby.session_id = target.id
    and lobby.status <> 'cancelled';

  if total_capacity > 0 then
    select count(*)::integer into assigned_count
    from public.tournament_stage_assignments as assignment
    where assignment.session_id = target.id
      and assignment.status = 'assigned';

    if assigned_count >= total_capacity then
      raise exception 'The target session is full.' using errcode = 'P4005';
    end if;
  end if;

  moves := coalesce(entry.source_provenance -> 'session_moves', '[]'::jsonb)
    || jsonb_build_object(
         'request_id', p_request_id::text,
         'from_session_id', entry.session_id::text,
         'to_session_id', target.id::text,
         'moved_by', auth.uid()::text,
         'moved_at', now()::text,
         'reason', normalized_reason
       );

  update public.tournament_session_entries
  set session_id = target.id,
      source_provenance = jsonb_set(
        coalesce(source_provenance, '{}'::jsonb),
        '{session_moves}',
        moves
      )
  where id = entry.id
  returning * into entry;

  return entry;
end;
$$;

comment on function public.levelledup_admin_move_session_entry(uuid, uuid, text, uuid) is
  'Admin-only move of an unused session entry to another session of the SAME stage. Cross-stage moves are refused for every role.';

alter function public.levelledup_admin_move_session_entry(uuid, uuid, text, uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_move_session_entry(uuid, uuid, text, uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_move_session_entry(uuid, uuid, text, uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 9. Read RPC for the web UI: where can this team enter next?
--    kind = 'next_stage_paid' | 'next_stage_free' | 'closed' | 'no_registration'
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

  -- The next stage is the earliest stage that still has an enterable session.
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
  'Read RPC for the entry UI: the next enterable stage/session (paid or free), or closed when nothing remains.';

alter function public.levelledup_get_next_entry_option(uuid, uuid)
  owner to postgres;

revoke all on function public.levelledup_get_next_entry_option(uuid, uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_get_next_entry_option(uuid, uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- Owners for the remaining new helpers.
-- ----------------------------------------------------------------------------

alter function public.levelledup_session_has_started(uuid) owner to postgres;
alter function public.levelledup_guard_session_entry_not_started() owner to postgres;
alter function public.levelledup_session_entry_consumed(uuid) owner to postgres;

commit;
