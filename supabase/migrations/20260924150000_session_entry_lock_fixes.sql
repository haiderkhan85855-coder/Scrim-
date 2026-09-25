-- 20260924150000_session_entry_lock_fixes.sql
--
-- Corrective pass over 20260924130000 (Haider's "single dot issue" rule:
-- report and fix, never silently ignore).
--
-- 1. Admin moves are later-session-only: an entry mark may slide forward to a
--    later session of the SAME stage, never backwards. The old code checked
--    same-stage but never compared session numbers.
-- 2. Late registration approval: stages stay OPEN after tournament start, so
--    the review no longer refuses approval once scheduled_start_at passes. A
--    live tournament now accepts approvals; only completed/cancelled/draft
--    tournaments refuse them. The session entry lock still governs placement.
-- 3. The approval session override now runs the same room check the move RPC
--    has: when lobbies already exist in the target session and every slot is
--    assigned, approval into that session is refused (P4005).
-- 4. Consumed = the moment the team's match goes live (lead decision,
--    approved in the roadmap): an assigned team with a live/completed match in
--    the entry's session is consumed even if no result is recorded yet.
--
-- Handoff basis: "admin may move the mark to a later session of the SAME
-- stage if room" (NEW-RULES-CHANGELOG.md); "stages stay OPEN after tournament
-- start: teams can still apply/register late" (handoff); roadmap 2026-09-25.

begin;

-- ----------------------------------------------------------------------------
-- 1. Move RPC: later-session-only.
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
  source_session public.tournament_stage_sessions;
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

  -- Later-session-only: the mark may slide forward within the stage, never
  -- backwards. (The equal-session case already returned early above.)
  select session.* into source_session
  from public.tournament_stage_sessions as session
  where session.id = entry.session_id;

  if source_session.id is null then
    raise exception 'Source Session not found.' using errcode = 'P4414';
  end if;

  if target.session_number <= source_session.session_number then
    raise exception 'Session entries can only move to a later session of the same stage.'
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
  'Admin-only move of an unused session entry to a LATER session of the SAME stage (150000: backwards moves refused). Cross-stage moves are refused for every role.';

alter function public.levelledup_admin_move_session_entry(uuid, uuid, text, uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_move_session_entry(uuid, uuid, text, uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_move_session_entry(uuid, uuid, text, uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 2+3. Review: late approval allowed; room check on session override.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_admin_review_tournament_registration(
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
  total_capacity integer;
  assigned_count integer;
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

  -- Stages stay OPEN after tournament start: late registration is allowed
  -- while the tournament is live. Only completed/cancelled/draft tournaments
  -- refuse new approvals.
  if selected_tournament.id is null
    or selected_tournament.status not in ('registration_open', 'registration_closed', 'live') then
    raise exception 'Registration cannot be approved after the tournament is completed or cancelled.'
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

  -- Room check on the override target, only when lobbies already exist there
  -- (mirrors levelledup_admin_move_session_entry).
  select coalesce(sum(lobby.capacity), 0)::integer into total_capacity
  from public.tournament_lobbies as lobby
  where lobby.session_id = selected_session.id
    and lobby.status <> 'cancelled';

  if total_capacity > 0 then
    select count(*)::integer into assigned_count
    from public.tournament_stage_assignments as assignment
    where assignment.session_id = selected_session.id
      and assignment.status = 'assigned';

    if assigned_count >= total_capacity then
      raise exception 'The selected session is full.' using errcode = 'P4005';
    end if;
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
  'Admin-only atomic review. Optional p_session_id overrides the captain''s chosen session at approval time; started sessions are rejected. 150000: late approval allowed while the tournament is live; override target gets the room check.';

alter function public.levelledup_admin_review_tournament_registration(uuid, text, uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_review_tournament_registration(uuid, text, uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_review_tournament_registration(uuid, text, uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 4. Consumed helper: match-live, not first-result.
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

  -- Consumed the moment the team's match goes live: the team holds an active
  -- lobby assignment in the entry's session and at least one match of that
  -- lobby is live or completed. Match status is the source of truth, mirroring
  -- levelledup_session_has_started. A team sitting in a live match with no
  -- result recorded yet is consumed -- it can never be moved or credited.
  return exists (
    select 1
    from public.tournament_stage_assignments as assignment
    join public.tournament_matches as matches
      on matches.lobby_id = assignment.lobby_id
    where assignment.registration_id = entry.registration_id
      and assignment.session_id = entry.session_id
      and assignment.status = 'assigned'
      and matches.status in ('live', 'completed')
  );
end;
$$;

comment on function public.levelledup_session_entry_consumed(uuid) is
  'True when the entry''s team has a live/completed match in the entry''s session (150000: match-live, not first-result).';

alter function public.levelledup_session_entry_consumed(uuid)
  owner to postgres;

revoke all on function public.levelledup_session_entry_consumed(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_session_entry_consumed(uuid)
  to authenticated;

commit;
