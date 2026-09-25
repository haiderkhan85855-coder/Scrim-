begin;

-- ============================================================================
-- 20260924195000: earned entry claim + manual placement queue.
--
-- Haider's decisions (2026-09-25), in his words:
--   "no no one gets the push to next stage i will decide that, i will decide
--    who will play in which session in which lobby"
--   "when each team buys a sessions or earn it they get in order like
--    number 1 paid, 2 paid, 3 paid, 4 earned, 5 paid, and moves on
--    so i know whos first and my rule first come first serves"
--   "u have to mark the paid and free teams"
--   "i will close the manual entries on my own" ("Too many entries here —
--    you can turn the entry off.")
--   "when they try to pay for it ... they already have a free limit ...
--    you already have a free session. You can play it. You earned it."
--   Leftover free entry: "they can play it ... for fun ... scores will be
--    counted ... standing won't affect"; "no refund ... cannot move" to the
--    next stage.
--   16 teams per lobby (PUBG official standard, noted); sessions sized by
--    Haider via max_teams. Lowering the cap never kicks placed teams.
--   DROPPED: auto-bump of free entries, over-capacity auto logic.
--
-- Handoff rules this file serves:
--   "A team that succeeds in a previous Session/Stage earns exactly one
--    payment-free attempt in the next Stage."
--   "Earned Entry: one free next-Stage attempt earned by qualification; does
--    not alter Session price."
--   "A team that is already qualified but chooses to play another attempt
--    must pay for that additional attempt."
--
-- OVERRIDE (Haider 2026-09-25, "I place everyone myself (queue)"):
--   This REPLACES the approved 190000 rule "Captain must choose a specific
--   future planned/open session; no unattached pre-buying." Buying now means
--   a STAGE attempt + a queue number (paid). The captain may name a preferred
--   session, but it is only a preference — Haider places every entry by hand.
--   Nothing auto-places, ever.
--
-- What this file does:
--   1. Entries can sit WITHOUT a session (the queue). Paid or earned, every
--      buy/earn gets a first-come-first-served number per stage, marked
--      PAID or FREE.
--   2. Fixes the 160000 bug: the earned grant could link the earned right to
--      an existing PAID entry; revoking qualification would then cancel the
--      paid entry. The grant now always mints its own entry and never links
--      to any existing one.
--   3. Paid-first guard: buying while holding an unused free entry returns a
--      warning ("You already have a FREE session — you earned it...") with
--      [use free] / [pay anyway]. Paying anyway stays allowed (extra attempts
--      are legal for qualified teams).
--   4. Haider's controls: per-session max_teams, per-stage entries_open
--      switch, place / unplace / finalize-session RPCs (teams are notified
--      ONLY at finalize), a queue view, and an over-capacity pressure view
--      behind his "Too many entries here — you can turn the entry off."
--   5. Lapse: an unused free entry expires when its stage ends — no refund,
--      no credit, cannot move. If a team qualifies onward while holding an
--      older free entry, they are warned; they may still play it for fun
--      (scores count, standing cannot change — already enforced by 160000,
--      which skips qualified teams when marking).
--   6. Stage close with unplaced PAID entries: the money was taken, so the
--      entries stay live, each team is told to contact the admin, and Haider
--      gets a staff alert. Exact refund/credit math is 200000's job.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Section 1: queue-ready entries — session_id becomes nullable.
-- NULL session_id = bought/earned but not yet placed; lives in the per-stage
-- queue until Haider places it. Grandfathered rows keep their sessions.
-- ---------------------------------------------------------------------------

alter table public.tournament_session_entries
  alter column session_id drop not null;

comment on column public.tournament_session_entries.session_id is
  'Placed session. NULL means the entry is in the admin placement queue (bought or earned, not yet placed). Haider places every entry by hand; nothing auto-places.';

-- ---------------------------------------------------------------------------
-- Section 2: placement finalization flag.
-- Picker flow: tap teams (+) to stage them into a session, confirm, then
-- Finalize — teams are notified only at finalize. Staged (false) picks are
-- the admin''s draft and are invisible to teams.
-- ---------------------------------------------------------------------------

alter table public.tournament_session_entries
  add column if not exists placement_finalized boolean not null default false;

comment on column public.tournament_session_entries.placement_finalized is
  'True once the admin finalized the session placement and the team was notified. Staged (false) placements are the admin''s draft picks.';

-- Grandfather: entries already sitting in a session were placed under the old
-- model and their teams were already told.
update public.tournament_session_entries
set placement_finalized = true
where session_id is not null
  and placement_finalized = false;

-- ---------------------------------------------------------------------------
-- Section 3: ''expired'' status for lapsed free entries.
-- A free (earned) entry belongs to its stage only. If the stage ends before
-- it is played, it lapses with zero value: no refund, no credit, no carry.
-- Paid entries NEVER expire — only free ones.
-- ---------------------------------------------------------------------------

alter table public.tournament_session_entries
  add column if not exists expired_at timestamptz,
  add column if not exists expired_reason text;

alter table public.tournament_session_entries
  drop constraint tournament_session_entries_status_valid;

alter table public.tournament_session_entries
  add constraint tournament_session_entries_status_valid
  check (status in ('active', 'cancelled', 'expired'));

alter table public.tournament_session_entries
  drop constraint tournament_session_entries_cancellation_state;

alter table public.tournament_session_entries
  add constraint tournament_session_entries_cancellation_state check (
    (status = 'active'
      and cancelled_by is null and cancelled_at is null
      and cancellation_reason is null and cancellation_request_id is null
      and expired_at is null and expired_reason is null)
    or (status = 'cancelled'
      and cancelled_at is not null
      and cancellation_reason = btrim(cancellation_reason)
      and char_length(cancellation_reason) between 10 and 1000
      and cancellation_request_id is not null
      and expired_at is null and expired_reason is null)
    or (status = 'expired'
      and expired_at is not null
      and expired_reason = btrim(expired_reason)
      and char_length(expired_reason) between 10 and 1000
      and cancelled_by is null and cancelled_at is null
      and cancellation_reason is null and cancellation_request_id is null)
  );

comment on column public.tournament_session_entries.expired_at is
  'When an unused free (earned) entry lapsed at stage end. Paid value is never expired — only free entries lapse.';

-- ---------------------------------------------------------------------------
-- Section 4: per-session max_teams — Haider''s lobby-capacity control.
-- NULL = no cap (as today). Lowering it never removes already-placed teams;
-- the place RPC simply refuses new placements once full.
-- ---------------------------------------------------------------------------

alter table public.tournament_stage_sessions
  add column if not exists max_teams integer;

alter table public.tournament_stage_sessions
  drop constraint if exists tournament_stage_sessions_max_teams_valid;

alter table public.tournament_stage_sessions
  add constraint tournament_stage_sessions_max_teams_valid
  check (max_teams is null or max_teams > 0);

comment on column public.tournament_stage_sessions.max_teams is
  'Haider''s per-session team cap (e.g. 16 teams per lobby x lobby count). NULL means no cap. Lowering it never kicks out teams already placed.';

-- ---------------------------------------------------------------------------
-- Section 5: per-stage entries_open switch — Haider closes entries himself.
-- When false, no NEW paid attempts can be bought for the stage. Earned
-- entries are still granted (they are owed, not bought).
-- ---------------------------------------------------------------------------

alter table public.tournament_stages
  add column if not exists entries_open boolean not null default true;

comment on column public.tournament_stages.entries_open is
  'Haider''s manual entry switch per stage. False blocks new paid attempts; earned entries are still granted. He flips it himself when the queue is full.';

create or replace function public.levelledup_admin_set_stage_entries_open(
  p_stage_id uuid,
  p_open boolean
)
returns public.tournament_stages
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_stage public.tournament_stages;
begin
  perform public.levelledup_require_admin('admin');

  if p_stage_id is null or p_open is null then
    raise exception 'Stage and the new switch value are required.'
      using errcode = '22023';
  end if;

  update public.tournament_stages as stage
  set entries_open = p_open,
      updated_at = now()
  where stage.id = p_stage_id
  returning stage.* into selected_stage;

  if selected_stage.id is null then
    raise exception 'Stage not found.' using errcode = 'P4420';
  end if;

  return selected_stage;
end;
$$;

comment on function public.levelledup_admin_set_stage_entries_open(uuid, boolean) is
  'Admin: flip a stage''s manual entry switch. Closing it blocks new paid attempts; earned entries still land.';

alter function public.levelledup_admin_set_stage_entries_open(uuid, boolean)
  owner to postgres;
revoke all on function public.levelledup_admin_set_stage_entries_open(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_set_stage_entries_open(uuid, boolean)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Section 6: the payment now records its STAGE; session_id becomes the
-- captain''s (optional) preferred session — informational only, never binding.
-- Backfills 190000 rows (they always carried a session).
-- ---------------------------------------------------------------------------

alter table public.tournament_registration_payments
  add column if not exists stage_id uuid;

alter table public.tournament_registration_payments
  drop constraint if exists tournament_registration_payments_stage_fk;

alter table public.tournament_registration_payments
  add constraint tournament_registration_payments_stage_fk
    foreign key (stage_id, tournament_id)
    references public.tournament_stages (id, tournament_id)
    on delete restrict;

comment on column public.tournament_registration_payments.stage_id is
  'Stage the session-attempt payment buys into. The admin places the entry into a session by hand; the payment''s session_id (when set) is only the captain''s preferred session.';

comment on column public.tournament_registration_payments.session_id is
  'Captain''s preferred session for a session-attempt payment (optional). Informational only — Haider places the entry. NULL on preserved legacy payments means historically unknown and is never guessed.';

update public.tournament_registration_payments as payment
set stage_id = session.stage_id
from public.tournament_stage_sessions as session
where payment.stage_id is null
  and payment.payment_purpose = 'session_attempt'
  and payment.session_id = session.id;

-- ---------------------------------------------------------------------------
-- Section 7: earned grant, rewritten for the queue model.
--   * No session targeting at all — the entry is created UNPLACED and waits
--     in the stage queue for Haider. (The old "no open session" failure mode
--     is gone: the grant always succeeds once the next stage exists.)
--   * BUGFIX (160000): the old "link to an existing entry in the target
--     session" branch could point the earned right at a PAID entry, so a
--     later revocation cancelled the paid entry and lied to the team about
--     an "unused free entry". That branch is deleted. The earned entry is
--     ALWAYS its own fresh row and never points at another entry.
--   * The team is told their queue number (#N, first come first served).
--   * Leftover hook: if the team still holds unused free entries from
--     earlier stages, they are warned — play it in that stage or lose it,
--     no refund, cannot move. (Play-for-fun stays legal: 160000 already
--     skips qualified teams when marking, so standing cannot change.)
-- ---------------------------------------------------------------------------

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
  next_stage_name text;
  source_entry public.tournament_session_entries;
  existing_entry_id uuid;
  new_entry_id uuid;
  queue_no integer;
  actor_role text;
  stage_name text;
  leftover record;
  leftover_no integer;
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

  -- No session targeting: Haider (2026-09-25) places every entry by hand.
  -- The entry is created unplaced and queued; there is no "no open session"
  -- failure anymore.

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

  -- NOTE: the old "adopt an existing active entry in the target session"
  -- branch was intentionally deleted here (2026-09-25). It could link the
  -- earned right to a PAID entry, and revoking the qualification would then
  -- cancel the paid entry. The earned entry is always its own fresh row.

  actor_role := public.levelledup_current_admin_role();
  if actor_role is null then
    actor_role := 'admin';
  end if;

  select st.display_name into stage_name
  from public.tournament_stages as st
  where st.id = qualifier.stage_id;

  select st.display_name into next_stage_name
  from public.tournament_stages as st
  where st.id = next_stage.id;

  insert into public.tournament_session_entries (
    tournament_id, stage_id, session_id, registration_id, team_id,
    source_type, earned_from_session_entry_id,
    source_occurred_at, source_provenance, reason,
    request_id, created_by, created_by_role
  ) values (
    qualifier.tournament_id,
    next_stage.id,
    null,
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
      'method', qualifier.method,
      'placement', 'admin_queue'
    ),
    'Earned free entry: qualified from stage "' || coalesce(stage_name, '?')
      || '". Waiting for admin placement.',
    gen_random_uuid(),
    auth.uid(),
    actor_role
  )
  returning id into new_entry_id;

  update public.tournament_stage_qualifiers
  set earned_entry_id = new_entry_id
  where id = qualifier.id;

  -- Queue number: first come, first served (creation order within the stage).
  select q.rn into queue_no
  from (
    select e.id,
           row_number() over (order by e.created_at, e.id)::integer as rn
    from public.tournament_session_entries as e
    where e.stage_id = next_stage.id
      and e.status = 'active'
  ) as q
  where q.id = new_entry_id;

  perform public.levelledup__notify_team(
    qualifier.team_id,
    qualifier.tournament_id,
    'earned_entry_queued',
    'Free entry earned',
    'You earned a FREE entry for "' || coalesce(next_stage_name, 'the next stage')
      || '"! You are #' || coalesce(queue_no::text, '?')
      || ' in the queue. The admin will place you in a session.',
    jsonb_build_object(
      'session_entry_id', new_entry_id::text,
      'stage_id', next_stage.id::text,
      'queue_number', queue_no
    )
  );

  -- Leftover free entries from earlier stages: warn, no refund, no carry.
  -- (Only ones with no finalized placement — a scheduled one needs no nag.)
  for leftover in
    select e.id as entry_id,
           e.stage_id as leftover_stage_id,
           st.display_name as leftover_stage_name
    from public.tournament_session_entries as e
    join public.tournament_stages as st on st.id = e.stage_id
    where e.registration_id = qualifier.registration_id
      and e.tournament_id = qualifier.tournament_id
      and e.source_type = 'earned'
      and e.status = 'active'
      and e.id <> new_entry_id
      and st.stage_number < next_stage.stage_number
      and not e.placement_finalized
      and not public.levelledup_session_entry_consumed(e.id)
  loop
    select q.rn into leftover_no
    from (
      select e2.id,
             row_number() over (order by e2.created_at, e2.id)::integer as rn
      from public.tournament_session_entries as e2
      where e2.stage_id = leftover.leftover_stage_id
        and e2.status = 'active'
    ) as q
    where q.id = leftover.entry_id;

    perform public.levelledup__notify_team(
      qualifier.team_id,
      qualifier.tournament_id,
      'earned_entry_leftover',
      'You still have a free entry',
      'You still have a FREE "' || coalesce(leftover.leftover_stage_name, 'stage')
        || '" entry (#' || coalesce(leftover_no::text, '?')
        || ' in its queue) that is not scheduled yet. Play it in a later session of that stage or lose it — no refund, and it cannot move to "'
        || coalesce(next_stage_name, 'the next stage') || '".',
      jsonb_build_object(
        'session_entry_id', leftover.entry_id::text,
        'stage_id', leftover.leftover_stage_id::text
      )
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'entry_id', new_entry_id,
    'queue_number', queue_no,
    'placed', false
  );
end;
$$;

comment on function public.levelledup__grant_earned_session_entry(uuid) is
  'Internal: creates the free next-stage session entry for a qualifier as an UNPLACED queue entry (Haider places it by hand). Always mints its own row — never links to an existing (paid) entry. Reports instead of raising when the entry cannot be created yet.';

alter function public.levelledup__grant_earned_session_entry(uuid)
  owner to postgres;

-- ---------------------------------------------------------------------------
-- Section 8: purchase, rewritten for the queue model.
-- New 5-arg RPC: (registration, STAGE, optional preferred session, reference,
-- screenshot) returns jsonb. The captain buys a stage attempt; the entry
-- lands in the queue unplaced. The preferred session is informational only.
--
-- Paid-first guard (Haider 2026-09-25): if the team already holds an unused
-- free entry in the stage, the result carries has_unused_earned_entry +
-- earned_entry_warning so the app can offer [use my free entry] /
-- [pay anyway]. Paying anyway stays allowed — extra attempts are legal.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_submit_session_attempt_payment(
  p_registration_id uuid,
  p_stage_id uuid,
  p_preferred_session_id uuid,
  p_reference_id text,
  p_screenshot_url text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_reference text := btrim(coalesce(p_reference_id, ''));
  normalized_screenshot text := btrim(coalesce(p_screenshot_url, ''));
  registration public.tournament_registrations;
  target_stage public.tournament_stages;
  preferred_session public.tournament_stage_sessions;
  pricing_session public.tournament_stage_sessions;
  prev_stage public.tournament_stages;
  already_in_stage boolean := false;
  chain_ok boolean := false;
  expected_amount integer;
  price_kind text;
  created_payment public.tournament_registration_payments;
  earned_entry_id uuid;
  earned_queue_no integer;
  warning_text text := null;
  violated_constraint text;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to submit payment.'
      using errcode = '42501';
  end if;

  if char_length(normalized_reference) not between 3 and 120 then
    raise exception 'Enter a valid transaction or reference ID.'
      using errcode = 'P4501';
  end if;

  -- Screenshot is mandatory: no screenshot, no payment submission.
  if normalized_screenshot = '' then
    raise exception 'A payment screenshot is required to submit a payment.'
      using errcode = 'P4509';
  end if;

  if normalized_screenshot !~* '^https?://' then
    raise exception 'The payment screenshot link must be a valid http(s) link.'
      using errcode = 'P4509';
  end if;

  if char_length(normalized_screenshot) > 2000 then
    raise exception 'The payment screenshot link is too long.'
      using errcode = 'P4509';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Registration not found.' using errcode = 'P4420';
  end if;

  if not public.levelledup_is_active_team_captain(registration.team_id) then
    raise exception 'Only the active team Captain can submit payment.'
      using errcode = '42501';
  end if;

  if registration.status <> 'confirmed' then
    raise exception 'Only a confirmed registration can buy a session attempt.'
      using errcode = 'P4503';
  end if;

  select stage.* into target_stage
  from public.tournament_stages as stage
  where stage.id = p_stage_id
    and stage.tournament_id = registration.tournament_id
  for share;

  if target_stage.id is null then
    raise exception 'Stage not found.' using errcode = 'P4420';
  end if;

  if target_stage.status in ('completed', 'cancelled') then
    raise exception 'This stage is closed for new entries.'
      using errcode = 'P4420';
  end if;

  -- Haider's manual entry switch.
  if not target_stage.entries_open then
    raise exception 'Entries are closed for this stage.'
      using errcode = 'P4420';
  end if;

  -- Preferred session: optional, informational only. Haider places everyone,
  -- so there is no entry lock, no fullness check and no per-session duplicate
  -- check here anymore.
  if p_preferred_session_id is not null then
    select session.* into preferred_session
    from public.tournament_stage_sessions as session
    where session.id = p_preferred_session_id
    for share;

    if preferred_session.id is null
      or preferred_session.tournament_id <> registration.tournament_id
      or preferred_session.stage_id <> target_stage.id then
      raise exception 'Preferred session not found.' using errcode = 'P4420';
    end if;

    pricing_session := preferred_session;
  else
    -- Price off the earliest priced session that has not started yet.
    select sess.* into pricing_session
    from public.tournament_stage_sessions as sess
    where sess.stage_id = target_stage.id
      and sess.status in ('planned', 'open')
      and not public.levelledup_session_has_started(sess.id)
    order by sess.session_number, sess.id
    limit 1;
  end if;

  if pricing_session.id is null then
    raise exception 'This stage has no priced session yet.'
      using errcode = 'P4422';
  end if;

  -- A free session needs no payment (free claim is a separate follow-up).
  if pricing_session.entry_fee_minor = 0 then
    raise exception 'This session is free; payment is not required.'
      using errcode = 'P4504';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(registration.id::text || ':session_payment', 0)
  );

  -- One unresolved session-attempt payment per team at a time.
  if exists (
    select 1
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.payment_purpose = 'session_attempt'
      and payment.status = 'pending'
  ) then
    raise exception 'Resolve your pending session payment first.'
      using errcode = 'P4505';
  end if;

  -- Price: normal vs direct entry.
  -- The chain/skip gate applies only when ENTERING a stage. Retrying inside
  -- a stage the team already entered always costs the normal fee.
  select exists (
    select 1
    from public.tournament_session_entries as entry
    where entry.registration_id = registration.id
      and entry.stage_id = target_stage.id
      and entry.status = 'active'
  ) into already_in_stage;

  if already_in_stage or target_stage.stage_number = 1 then
    expected_amount := pricing_session.entry_fee_minor;
    price_kind := 'normal';
  else
    -- The participation chain: played at least one match in the previous
    -- stage (assigned to a lobby whose match went live or completed).
    select stage.* into prev_stage
    from public.tournament_stages as stage
    where stage.tournament_id = target_stage.tournament_id
      and stage.stage_number = target_stage.stage_number - 1
    limit 1;

    if prev_stage.id is not null then
      select exists (
        select 1
        from public.tournament_stage_assignments as assignment
        join public.tournament_matches as match
          on match.lobby_id = assignment.lobby_id
         and match.stage_id = assignment.stage_id
        where assignment.registration_id = registration.id
          and assignment.stage_id = prev_stage.id
          and assignment.status = 'assigned'
          and match.status in ('live', 'completed')
      ) into chain_ok;
    end if;

    if chain_ok then
      expected_amount := pricing_session.entry_fee_minor;
      price_kind := 'normal';
    elsif target_stage.direct_entry_fee_minor is not null then
      expected_amount := target_stage.direct_entry_fee_minor;
      price_kind := 'direct_entry';
    else
      raise exception 'Direct entry is not available for this stage yet. Play the previous stage first.'
        using errcode = 'P4422';
    end if;
  end if;

  insert into public.tournament_registration_payments (
    registration_id, tournament_id, team_id, stage_id, session_id,
    payment_method, payment_purpose, status,
    expected_amount_minor, currency,
    reference_id, submitted_by,
    screenshot_url, screenshot_uploaded_at, screenshot_exempt
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    target_stage.id, preferred_session.id,
    'manual', 'session_attempt', 'pending',
    expected_amount, pricing_session.fee_currency,
    normalized_reference, authenticated_user_id,
    normalized_screenshot, now(), false
  ) returning * into created_payment;

  -- Paid-first guard: an unused free entry already in the queue?
  select entry.id into earned_entry_id
  from public.tournament_session_entries as entry
  where entry.registration_id = registration.id
    and entry.stage_id = target_stage.id
    and entry.source_type = 'earned'
    and entry.status = 'active'
    and not public.levelledup_session_entry_consumed(entry.id)
  order by entry.created_at, entry.id
  limit 1;

  if earned_entry_id is not null then
    select q.rn into earned_queue_no
    from (
      select e.id,
             row_number() over (order by e.created_at, e.id)::integer as rn
      from public.tournament_session_entries as e
      where e.stage_id = target_stage.id
        and e.status = 'active'
    ) as q
    where q.id = earned_entry_id;

    warning_text :=
      'You already have a FREE session — you earned it (#'
      || coalesce(earned_queue_no::text, '?')
      || ' in the queue). The admin will place you. You can still buy an extra attempt if you want.';
  end if;

  return jsonb_build_object(
    'ok', true,
    'payment_id', created_payment.id,
    'stage_id', target_stage.id,
    'preferred_session_id', preferred_session.id,
    'expected_amount_minor', created_payment.expected_amount_minor,
    'currency', created_payment.currency,
    'price_kind', price_kind,
    'has_unused_earned_entry', earned_entry_id is not null,
    'earned_entry_warning', warning_text
  );
exception
  when unique_violation then
    get stacked diagnostics violated_constraint = constraint_name;
    if violated_constraint = 'tournament_registration_payments_manual_reference_unique_idx' then
      raise exception 'This payment reference has already been used. Each bank transaction can back only one payment.'
        using errcode = 'P4510';
    end if;
    raise exception 'Resolve your pending session payment first.'
      using errcode = 'P4505';
end;
$$;

comment on function public.levelledup_submit_session_attempt_payment(uuid, uuid, uuid, text, text) is
  'Captain: buy a session attempt for a STAGE. The entry lands in the admin placement queue (unplaced); the preferred session is informational only. Returns jsonb with the payment plus a free-entry warning when the team already holds an unused earned entry.';

alter function public.levelledup_submit_session_attempt_payment(uuid, uuid, uuid, text, text)
  owner to postgres;
revoke all on function public.levelledup_submit_session_attempt_payment(uuid, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_submit_session_attempt_payment(uuid, uuid, uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- One unresolved session-attempt payment per team, at the database level too.
-- (The old (registration_id, session_id) shape no longer fits: entries are
-- bought per stage now, and the session is only a preference.)
-- ---------------------------------------------------------------------------

drop index if exists public.tournament_registration_payments_one_open_session_attempt_idx;

create unique index if not exists tournament_registration_payments_one_open_session_attempt_idx
  on public.tournament_registration_payments (registration_id)
  where status = 'pending' and payment_purpose = 'session_attempt';

-- ---------------------------------------------------------------------------
-- Backward-compatible wrapper: the old 4-arg call (session required) now
-- treats the session as the captain''s preferred session and returns the
-- payment row as before. New callers should use the 5-arg RPC.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_submit_session_attempt_payment(
  p_registration_id uuid,
  p_session_id uuid,
  p_reference_id text,
  p_screenshot_url text
)
returns public.tournament_registration_payments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_session public.tournament_stage_sessions;
  result jsonb;
  payment_row public.tournament_registration_payments;
begin
  if p_session_id is null then
    raise exception 'Session not found.' using errcode = 'P4420';
  end if;

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = p_session_id;

  if selected_session.id is null then
    raise exception 'Session not found.' using errcode = 'P4420';
  end if;

  result := public.levelledup_submit_session_attempt_payment(
    p_registration_id,
    selected_session.stage_id,
    p_session_id,
    p_reference_id,
    p_screenshot_url
  );

  select payment.* into payment_row
  from public.tournament_registration_payments as payment
  where payment.id = (result ->> 'payment_id')::uuid;

  return payment_row;
end;
$$;

comment on function public.levelledup_submit_session_attempt_payment(uuid, uuid, text, text) is
  'Backward-compatible wrapper: the session is now the captain''s preferred session (Haider places the entry). Returns the payment row. Prefer the 5-arg RPC.';

alter function public.levelledup_submit_session_attempt_payment(uuid, uuid, text, text)
  owner to postgres;
revoke all on function public.levelledup_submit_session_attempt_payment(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_submit_session_attempt_payment(uuid, uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Section 9: auto-mint on verify, rewritten for the queue model.
-- A verified session-attempt payment now mints an UNPLACED paid entry +
-- session entry (Haider places them). The payment''s session_id stays as the
-- captain''s recorded preference only. entries_open is deliberately NOT
-- re-checked here: the money was already taken, so a paid entry always lands.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_mint_session_entry_on_payment_verified()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_stage public.tournament_stages;
  preferred_session public.tournament_stage_sessions;
  registration public.tournament_registrations;
  prev_stage public.tournament_stages;
  already_in_stage boolean := false;
  chain_ok boolean := false;
  price_kind text := 'normal';
  actor_role text;
  stage_label text;
  reason_text text;
  paid_entry_id uuid;
  new_entry_id uuid;
  queue_no integer;
begin
  if new.payment_purpose is distinct from 'session_attempt'
     or new.status is distinct from 'verified'
     or old.status is not distinct from 'verified' then
    return new;
  end if;

  -- Idempotency: never mint twice for the same payment.
  if exists (
    select 1
    from public.tournament_registration_paid_entries as paid_entry
    where paid_entry.source_payment_id = new.id
  ) then
    return new;
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = new.registration_id
  for share;

  -- The stage: prefer the recorded stage_id; fall back to the preferred
  -- session for payments submitted before 195000.
  if new.stage_id is not null then
    select stage.* into target_stage
    from public.tournament_stages as stage
    where stage.id = new.stage_id
    for share;
  elsif new.session_id is not null then
    select session.* into preferred_session
    from public.tournament_stage_sessions as session
    where session.id = new.session_id;

    if preferred_session.id is not null then
      select stage.* into target_stage
      from public.tournament_stages as stage
      where stage.id = preferred_session.stage_id
      for share;
    end if;
  end if;

  if target_stage.id is null or registration.id is null then
    raise exception 'Verified session payment references a missing stage.'
      using errcode = '23503';
  end if;

  -- The world may have changed while the payment sat pending.
  if target_stage.status in ('completed', 'cancelled') then
    raise exception 'The stage is closed for new entries.'
      using errcode = 'P4420';
  end if;

  -- Re-derive the price kind for the audit trail.
  select exists (
    select 1
    from public.tournament_session_entries as entry
    where entry.registration_id = new.registration_id
      and entry.stage_id = target_stage.id
      and entry.status = 'active'
  ) into already_in_stage;

  if not already_in_stage and target_stage.stage_number > 1 then
    select stage.* into prev_stage
    from public.tournament_stages as stage
    where stage.tournament_id = target_stage.tournament_id
      and stage.stage_number = target_stage.stage_number - 1
    limit 1;

    if prev_stage.id is not null then
      select exists (
        select 1
        from public.tournament_stage_assignments as assignment
        join public.tournament_matches as match
          on match.lobby_id = assignment.lobby_id
         and match.stage_id = assignment.stage_id
        where assignment.registration_id = new.registration_id
          and assignment.stage_id = prev_stage.id
          and assignment.status = 'assigned'
          and match.status in ('live', 'completed')
      ) into chain_ok;
    end if;

    if not chain_ok then
      price_kind := 'direct_entry';
    end if;
  end if;

  actor_role := public.levelledup_current_admin_role();
  if actor_role is null then
    actor_role := 'admin';
  end if;

  stage_label := target_stage.display_name;

  -- Unplaced by design: the entry waits in the queue for Haider.
  insert into public.tournament_registration_paid_entries (
    registration_id, tournament_id, team_id, stage_id, session_id,
    entry_scope, source_payment_id, amount_minor, currency, status, created_by
  ) values (
    new.registration_id, new.tournament_id, new.team_id,
    target_stage.id, null,
    'session', new.id, new.expected_amount_minor, new.currency,
    'paid', new.submitted_by
  ) returning id into paid_entry_id;

  if price_kind = 'direct_entry' then
    reason_text := 'Session attempt purchase: verified direct-entry payment of '
      || new.expected_amount_minor::text || ' ' || new.currency
      || ' for stage "' || stage_label || '". Waiting for admin placement.';
  else
    reason_text := 'Session attempt purchase: verified payment of '
      || new.expected_amount_minor::text || ' ' || new.currency
      || ' for stage "' || stage_label || '". Waiting for admin placement.';
  end if;

  insert into public.tournament_session_entries (
    tournament_id, stage_id, session_id, registration_id, team_id,
    source_type, source_paid_entry_id, source_occurred_at, source_provenance,
    reason, request_id, created_by, created_by_role
  ) values (
    new.tournament_id, target_stage.id, null,
    new.registration_id, new.team_id,
    'paid', paid_entry_id, now(),
    jsonb_build_object(
      'payment_id', new.id::text,
      'price_kind', price_kind,
      'amount_minor', new.expected_amount_minor,
      'currency', new.currency,
      'preferred_session_id', new.session_id::text,
      'placement', 'admin_queue'
    ),
    reason_text, gen_random_uuid(), auth.uid(), actor_role
  ) returning id into new_entry_id;

  -- Queue number: first come, first served.
  select q.rn into queue_no
  from (
    select e.id,
           row_number() over (order by e.created_at, e.id)::integer as rn
    from public.tournament_session_entries as e
    where e.stage_id = target_stage.id
      and e.status = 'active'
  ) as q
  where q.id = new_entry_id;

  -- Team inbox notification.
  perform public.levelledup__notify_team(
    new.team_id,
    new.tournament_id,
    'session_entry_queued',
    'Entry confirmed',
    'Your '
      || case when price_kind = 'direct_entry' then 'direct entry' else 'session entry' end
      || ' for "' || stage_label || '" is confirmed. You are #'
      || coalesce(queue_no::text, '?')
      || ' in the queue — the admin will place you in a session. Good luck!',
    jsonb_build_object(
      'session_entry_id', new_entry_id::text,
      'stage_id', target_stage.id::text,
      'queue_number', queue_no
    )
  );

  return new;
end;
$$;

comment on function public.levelledup_mint_session_entry_on_payment_verified() is
  'Trigger: a verified session-attempt payment mints an UNPLACED paid entry + session entry in the admin queue (Haider places it by hand).';

alter function public.levelledup_mint_session_entry_on_payment_verified()
  owner to postgres;

-- ---------------------------------------------------------------------------
-- Section 10: paid-allocation guards, updated for unplaced queue entries.
--   * A session-scope paid entry may now have NULL session_id = bought but
--     not yet placed (the queue). The old NOT NULL requirement is widened.
--   * The validator skips session-identity checks for unplaced rows (they
--     run when Haider places the entry, because the trigger fires on update
--     too) and the captain-preference binding is deleted: the preferred
--     session no longer has to equal the placed session.
-- ---------------------------------------------------------------------------

alter table public.tournament_registration_paid_entries
  drop constraint tournament_registration_paid_entries_scope_valid;

alter table public.tournament_registration_paid_entries
  add constraint tournament_registration_paid_entries_scope_valid check (
    (entry_scope = 'stage' and session_id is null and lobby_id is null
      and not is_legacy_session_proxy)
    or (entry_scope = 'session'
      and (not is_legacy_session_proxy or lobby_id is not null))
  );

comment on constraint tournament_registration_paid_entries_scope_valid
  on public.tournament_registration_paid_entries is
  'Scope/shape guard. NULL session_id on a session-scope entry means bought but not yet placed (admin queue) — Haider places it later.';

create or replace function public.levelledup_validate_paid_entry_session_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_session public.tournament_stage_sessions;
  source_payment public.tournament_registration_payments;
begin
  select payment.* into source_payment
  from public.tournament_registration_payments as payment
  where payment.id = new.source_payment_id;

  if source_payment.id is null
    or source_payment.status <> 'verified'
    or source_payment.registration_id <> new.registration_id
    or source_payment.tournament_id <> new.tournament_id
    or source_payment.team_id <> new.team_id then
    raise exception 'A paid allocation requires its matching verified source payment.'
      using errcode = '22023';
  end if;

  if new.entry_scope = 'stage' then
    if new.session_id is not null or new.lobby_id is not null then
      raise exception 'A Stage paid entry cannot identify a Session or Lobby.'
        using errcode = '22023';
    end if;

    if source_payment.session_id is not null then
      raise exception 'A Session-bound payment cannot fund a Stage-wide paid entry.'
        using errcode = '22023';
    end if;
  elsif new.entry_scope = 'session' then
    -- Unplaced queue entries skip the session-identity checks; the money
    -- checks below still apply. Placement re-fires this trigger.
    if new.session_id is not null then
      select session.* into selected_session
      from public.tournament_stage_sessions as session
      where session.id = new.session_id
        and session.stage_id = new.stage_id
        and session.tournament_id = new.tournament_id;

      if selected_session.id is null then
        raise exception 'A Session paid entry requires its exact Session in the same Stage and Tournament.'
          using errcode = '23503';
      end if;
    end if;

    -- 2026-09-25: the captain''s preferred session no longer binds the entry
    -- (Haider places everyone), so the old payment-session = entry-session
    -- equality check is deleted.

    if source_payment.payment_purpose = 'session_attempt' then
      -- 190000: the paid entry must equal exactly what the pricing rules
      -- charged on the source payment — no more, no less.
      if new.amount_minor::bigint <> source_payment.expected_amount_minor::bigint
        or new.currency <> source_payment.currency then
        raise exception 'A Session paid entry must equal its verified session-attempt payment amount.'
          using errcode = '22023';
      end if;
    elsif new.session_id is not null then
      if new.amount_minor::bigint <> selected_session.entry_fee_minor
        or new.currency <> selected_session.fee_currency then
        raise exception 'A Session paid entry must equal its authoritative Session fee and currency.'
          using errcode = '22023';
      end if;

      if source_payment.expected_amount_minor::bigint <> selected_session.entry_fee_minor
        or source_payment.currency <> selected_session.fee_currency then
        raise exception 'A new Session allocation requires the exact authoritative payment for that same Session.'
          using errcode = '22023';
      end if;
    end if;

    if new.lobby_id is not null then
      if new.session_id is null then
        raise exception 'Paid-entry Lobby requires its Session.'
          using errcode = '23503';
      end if;

      if not exists (
        select 1 from public.tournament_lobbies as lobby
        where lobby.id = new.lobby_id
          and lobby.session_id = selected_session.id
          and lobby.stage_id = new.stage_id
          and lobby.tournament_id = new.tournament_id
      ) then
        raise exception 'Paid-entry Lobby must belong to its exact Session.'
          using errcode = '23503';
      end if;
    end if;
  else
    raise exception 'Paid-entry scope must be Stage or Session.' using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function public.levelledup_validate_paid_entry_session_scope() is
  'Paid-allocation guard. Session-scope rows may be unplaced (NULL session = admin queue); session-identity checks run on placement.';

alter function public.levelledup_validate_paid_entry_session_scope()
  owner to postgres;

-- ---------------------------------------------------------------------------
-- Section 11: session-entry source validator, updated for unplaced entries.
-- Session checks (identity, planned/open status) apply only once an entry is
-- placed. Unplaced entries still require an eligible team, confirmed squad,
-- live tournament and an open stage. (Fires on insert only; the place RPC
-- does its own checks on update.)
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_validate_session_entry_source()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  selected_session public.tournament_stage_sessions;
  selected_team public.teams;
  selected_tournament public.tournaments;
  selected_stage public.tournament_stages;
  paid_entry public.tournament_registration_paid_entries;
  source_payment public.tournament_registration_payments;
  earned_entry public.tournament_session_entries;
  credit_debit public.levelledup_credit_ledger_entries;
  initial_payment public.tournament_registration_payments;
begin
  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = new.registration_id;

  select current_session.* into selected_session
  from public.tournament_stage_sessions as current_session
  where current_session.id = new.session_id;

  if registration.id is null
    or registration.tournament_id <> new.tournament_id
    or registration.team_id <> new.team_id then
    raise exception 'Session Entry parents must share the same Tournament, registration and team.'
      using errcode = '23503';
  end if;

  -- Session identity applies only to placed entries; unplaced queue entries
  -- skip it (Haider places them later through the place RPC).
  if new.session_id is not null then
    if selected_session.id is null
      or selected_session.tournament_id <> new.tournament_id
      or selected_session.stage_id <> new.stage_id then
      raise exception 'Session Entry parents must share the same Tournament, Stage and Session.'
        using errcode = '23503';
    end if;
  end if;

  select team.* into selected_team
  from public.teams as team where team.id = new.team_id;
  select tournament.* into selected_tournament
  from public.tournaments as tournament where tournament.id = new.tournament_id;
  select stage.* into selected_stage
  from public.tournament_stages as stage where stage.id = new.stage_id;

  if selected_team.id is null or selected_team.status <> 'active'
    or registration.status <> 'confirmed'
    or registration.roster_status not in ('finalized', 'locked')
    or selected_tournament.id is null
    or selected_tournament.status in ('completed', 'cancelled')
    or selected_stage.id is null
    or selected_stage.status in ('completed', 'cancelled')
    or (new.session_id is not null
        and selected_session.status not in ('planned', 'open')) then
    raise exception 'A new Session Entry requires an active eligible team, confirmed Squad, and a live Tournament with an open Stage (and, once placed, a future permitted Session).'
      using errcode = 'P4417';
  end if;

  if new.source_type = 'paid' then
    select source.* into paid_entry
    from public.tournament_registration_paid_entries as source
    where source.id = new.source_paid_entry_id;

    select payment.* into source_payment
    from public.tournament_registration_payments as payment
    where payment.id = paid_entry.source_payment_id;

    if paid_entry.id is null
      or paid_entry.entry_scope <> 'session'
      or paid_entry.status <> 'paid'
      or paid_entry.registration_id <> new.registration_id
      or paid_entry.team_id <> new.team_id
      or paid_entry.tournament_id <> new.tournament_id
      or paid_entry.stage_id <> new.stage_id
      or paid_entry.session_id is distinct from new.session_id then
      raise exception 'Paid Session Entry requires an unused exact-price paid allocation for the same registration and Session.'
        using errcode = '22023';
    end if;

    -- 190000: a direct-entry session attempt costs the stage''s direct-entry
    -- premium, not the session fee. Its paid entry must equal exactly what
    -- the pricing rules charged on the source payment.
    if source_payment.payment_purpose = 'session_attempt' then
      if paid_entry.amount_minor::bigint <> source_payment.expected_amount_minor::bigint
        or paid_entry.currency <> source_payment.currency then
        raise exception 'Paid Session Entry requires an unused exact-price paid allocation for the same registration and Session.'
          using errcode = '22023';
      end if;
    elsif new.session_id is not null
      and (paid_entry.amount_minor::bigint <> selected_session.entry_fee_minor
        or paid_entry.currency <> selected_session.fee_currency) then
      raise exception 'Paid Session Entry requires an unused exact-price paid allocation for the same registration and Session.'
        using errcode = '22023';
    end if;
    new.source_occurred_at := paid_entry.created_at;
  elsif new.source_type = 'earned' then
    select source.* into earned_entry
    from public.tournament_session_entries as source
    where source.id = new.earned_from_session_entry_id;

    if earned_entry.id is null or earned_entry.status <> 'active'
      or earned_entry.registration_id <> new.registration_id
      or earned_entry.team_id <> new.team_id
      or earned_entry.tournament_id <> new.tournament_id
      or earned_entry.session_id = new.session_id then
      raise exception 'Earned Session Entry requires trusted prior-participation provenance for the same registration/team; this does not prove qualification.'
        using errcode = '22023';
    end if;
    new.source_occurred_at := earned_entry.created_at;
  elsif new.source_type = 'credit' then
    select source.* into credit_debit
    from public.levelledup_credit_ledger_entries as source
    where source.id = new.source_credit_ledger_entry_id;

    if credit_debit.id is null
      or credit_debit.event_type <> 'apply'
      or credit_debit.operational_team_id <> new.team_id
      or selected_team.status <> 'active'
      or (new.session_id is not null
        and (credit_debit.amount_delta_minor <> -selected_session.entry_fee_minor
          or credit_debit.currency <> selected_session.fee_currency))
      or exists (
        select 1 from public.levelledup_credit_ledger_entries as reversal
        where reversal.related_entry_id = credit_debit.id
          and reversal.event_type = 'reversal'
      ) then
      raise exception 'Credit Session Entry requires an unreversed exact-price credit debit scoped to the active operational team.'
        using errcode = '22023';
    end if;
    new.source_occurred_at := credit_debit.created_at;
  elsif new.source_type = 'registration' then
    select payment.* into initial_payment
    from public.tournament_registration_payments as payment
    where payment.id::text = new.source_provenance ->> 'payment_id'
      and payment.registration_id = new.registration_id
      and payment.tournament_id = new.tournament_id
      and payment.team_id = new.team_id
      and payment.session_id = new.session_id
      and payment.status = 'verified'
      and payment.expected_amount_minor::bigint = selected_tournament.entry_fee_minor
      and payment.currency = selected_tournament.currency;

    if selected_tournament.entry_fee_minor <= 0
      or registration.initial_session_id is distinct from new.session_id
      or selected_stage.stage_number <> 1
      or new.source_provenance ->> 'entitlement'
        is distinct from 'initial_registration_confirmation'
      or initial_payment.id is null then
      raise exception 'Paid initial registration Session Entry requires the verified Tournament-fee payment and selected Stage 1 Session provenance.'
        using errcode = '22023';
    end if;
    new.source_occurred_at := initial_payment.reviewed_at;
  elsif new.source_type = 'free' then
    if selected_tournament.entry_fee_minor <> 0
      or selected_session.entry_fee_minor <> 0
      or registration.initial_session_id is distinct from new.session_id
      or selected_stage.stage_number <> 1
      or new.source_provenance ->> 'entitlement'
        is distinct from 'initial_registration_confirmation' then
      raise exception 'Free Session Entry requires the selected zero-fee initial Stage 1 registration entitlement.'
        using errcode = '22023';
    end if;
    new.source_occurred_at := coalesce(registration.confirmed_at, now());
  else
    new.source_occurred_at := coalesce(new.source_occurred_at, now());
  end if;

  return new;
end;
$$;

comment on function public.levelledup_validate_session_entry_source() is
  'Session-entry source guard. Placed entries keep the full session checks; unplaced queue entries skip them (placement is validated by the place RPC).';

alter function public.levelledup_validate_session_entry_source()
  owner to postgres;

-- ---------------------------------------------------------------------------
-- Section 12: Haider''s placement controls.
--   * levelledup_admin_place_entry: stage a queue entry into a session.
--     Staged picks are NOT final and teams are NOT notified yet.
--   * levelledup_admin_unplace_entry: pull a staged (unfinalized) pick back
--     to the queue.
--   * levelledup_admin_finalize_session: finalize every staged pick in the
--     session and notify the teams. Only now do teams learn they are playing.
--   * levelledup_get_stage_entry_queue: the numbered per-stage queue
--     (#1 paid, #2 paid, #3 earned, ...) for the + picker UI.
--   * levelledup_stage_entry_pressure: unplaced count vs session capacity,
--     behind "Too many entries here — you can turn the entry off."
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_admin_place_entry(
  p_entry_id uuid,
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  entry public.tournament_session_entries;
  target_session public.tournament_stage_sessions;
  placed_count integer;
begin
  perform public.levelledup_require_admin('admin');

  if p_entry_id is null or p_session_id is null then
    raise exception 'Entry and session are required.' using errcode = '22023';
  end if;

  select e.* into entry
  from public.tournament_session_entries as e
  where e.id = p_entry_id
  for update;

  if entry.id is null then
    raise exception 'Entry not found.' using errcode = 'P4420';
  end if;

  if entry.status <> 'active' then
    raise exception 'Only active entries can be placed.' using errcode = 'P4417';
  end if;

  if entry.session_id is not null then
    raise exception 'This entry is already placed in a session.'
      using errcode = 'P4417';
  end if;

  select session.* into target_session
  from public.tournament_stage_sessions as session
  where session.id = p_session_id
  for share;

  if target_session.id is null
    or target_session.tournament_id <> entry.tournament_id then
    raise exception 'Session not found.' using errcode = 'P4420';
  end if;

  if target_session.stage_id <> entry.stage_id then
    raise exception 'The session belongs to a different stage.'
      using errcode = '23503';
  end if;

  if target_session.status not in ('planned', 'open') then
    raise exception 'The session is no longer open for entry.'
      using errcode = 'P4421';
  end if;

  -- Entry lock: a started session is closed.
  if public.levelledup_session_has_started(target_session.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  -- One entry per team per session.
  if exists (
    select 1
    from public.tournament_session_entries as other
    where other.registration_id = entry.registration_id
      and other.session_id = target_session.id
      and other.status = 'active'
      and other.id <> entry.id
  ) then
    raise exception 'This team already has an entry in this session.'
      using errcode = '23505';
  end if;

  -- Haider''s cap: staged + finalized picks both count. Lowering the cap
  -- never kicks anyone; it only refuses new picks once full.
  if target_session.max_teams is not null then
    select count(*)::integer into placed_count
    from public.tournament_session_entries as other
    where other.session_id = target_session.id
      and other.status = 'active';

    if placed_count >= target_session.max_teams then
      raise exception 'This session is full.'
        using errcode = 'P4005';
    end if;
  end if;

  update public.tournament_session_entries as e
  set session_id = target_session.id,
      placement_finalized = false
  where e.id = entry.id;

  -- Keep the money record in sync for paid entries (re-fires the
  -- paid-entry validator, which now runs its session checks).
  if entry.source_type = 'paid' and entry.source_paid_entry_id is not null then
    update public.tournament_registration_paid_entries as paid_entry
    set session_id = target_session.id,
        updated_at = now()
    where paid_entry.id = entry.source_paid_entry_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'entry_id', entry.id,
    'session_id', target_session.id,
    'finalized', false
  );
end;
$$;

comment on function public.levelledup_admin_place_entry(uuid, uuid) is
  'Admin: stage a queue entry into a session (draft pick). Not final, team not notified. Use finalize to confirm.';

alter function public.levelledup_admin_place_entry(uuid, uuid)
  owner to postgres;
revoke all on function public.levelledup_admin_place_entry(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_place_entry(uuid, uuid)
  to authenticated;

create or replace function public.levelledup_admin_unplace_entry(
  p_entry_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  entry public.tournament_session_entries;
begin
  perform public.levelledup_require_admin('admin');

  if p_entry_id is null then
    raise exception 'Entry is required.' using errcode = '22023';
  end if;

  select e.* into entry
  from public.tournament_session_entries as e
  where e.id = p_entry_id
  for update;

  if entry.id is null then
    raise exception 'Entry not found.' using errcode = 'P4420';
  end if;

  if entry.status <> 'active' then
    raise exception 'Only active entries can be unplaced.' using errcode = 'P4417';
  end if;

  if entry.session_id is null then
    raise exception 'This entry is not placed.' using errcode = 'P4417';
  end if;

  if entry.placement_finalized then
    raise exception 'This placement is already finalized.'
      using errcode = 'P4417';
  end if;

  update public.tournament_session_entries as e
  set session_id = null
  where e.id = entry.id;

  if entry.source_type = 'paid' and entry.source_paid_entry_id is not null then
    update public.tournament_registration_paid_entries as paid_entry
    set session_id = null,
        updated_at = now()
    where paid_entry.id = entry.source_paid_entry_id;
  end if;

  return jsonb_build_object('ok', true, 'entry_id', entry.id);
end;
$$;

comment on function public.levelledup_admin_unplace_entry(uuid) is
  'Admin: pull a staged (not yet finalized) pick back into the queue. Finalized placements use the session move instead.';

alter function public.levelledup_admin_unplace_entry(uuid)
  owner to postgres;
revoke all on function public.levelledup_admin_unplace_entry(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_unplace_entry(uuid)
  to authenticated;

create or replace function public.levelledup_admin_finalize_session(
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_session public.tournament_stage_sessions;
  target_stage public.tournament_stages;
  r record;
  finalized_count integer := 0;
begin
  perform public.levelledup_require_admin('admin');

  if p_session_id is null then
    raise exception 'Session is required.' using errcode = '22023';
  end if;

  select session.* into target_session
  from public.tournament_stage_sessions as session
  where session.id = p_session_id
  for share;

  if target_session.id is null then
    raise exception 'Session not found.' using errcode = 'P4420';
  end if;

  if target_session.status not in ('planned', 'open') then
    raise exception 'The session is no longer open for entry.'
      using errcode = 'P4421';
  end if;

  if public.levelledup_session_has_started(target_session.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  select stage.* into target_stage
  from public.tournament_stages as stage
  where stage.id = target_session.stage_id;

  for r in
    select e.id as entry_id,
           e.team_id as team_id,
           e.tournament_id as tournament_id,
           e.source_type as source_type
    from public.tournament_session_entries as e
    where e.session_id = target_session.id
      and e.status = 'active'
      and not e.placement_finalized
    order by e.created_at, e.id
    for update
  loop
    update public.tournament_session_entries as e
    set placement_finalized = true
    where e.id = r.entry_id;

    perform public.levelledup__notify_team(
      r.team_id,
      r.tournament_id,
      'session_finalized',
      'You are playing!',
      'Your '
        || case when r.source_type = 'earned' then 'FREE' else 'paid' end
        || ' entry is confirmed for "'
        || coalesce(target_stage.display_name, '?')
        || ' — ' || coalesce(target_session.display_name, '?')
        || '". Your lobby will be announced.',
      jsonb_build_object(
        'session_entry_id', r.entry_id::text,
        'session_id', target_session.id::text,
        'stage_id', target_session.stage_id::text
      )
    );

    finalized_count := finalized_count + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'session_id', target_session.id,
    'finalized', finalized_count
  );
end;
$$;

comment on function public.levelledup_admin_finalize_session(uuid) is
  'Admin: finalize every staged pick in a session and notify the teams. Teams learn they are playing only at finalize.';

alter function public.levelledup_admin_finalize_session(uuid)
  owner to postgres;
revoke all on function public.levelledup_admin_finalize_session(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_finalize_session(uuid)
  to authenticated;

-- The numbered queue: first come, first served, marked paid/earned.
create or replace function public.levelledup_get_stage_entry_queue(
  p_stage_id uuid
)
returns table (
  queue_number integer,
  entry_id uuid,
  team_id uuid,
  team_name text,
  source_type text,
  status text,
  session_id uuid,
  session_name text,
  placement_finalized boolean,
  created_at timestamptz
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
    row_number() over (order by e.created_at, e.id)::integer,
    e.id,
    e.team_id,
    t.name,
    e.source_type,
    e.status,
    e.session_id,
    s.display_name,
    e.placement_finalized,
    e.created_at
  from public.tournament_session_entries as e
  join public.teams as t on t.id = e.team_id
  left join public.tournament_stage_sessions as s on s.id = e.session_id
  where e.stage_id = p_stage_id
    and e.status = 'active'
  order by e.created_at, e.id;
end;
$$;

comment on function public.levelledup_get_stage_entry_queue(uuid) is
  'Admin: the numbered per-stage entry queue (#1 paid, #2 paid, #3 earned, ...) for the manual placement picker. First come, first served.';

alter function public.levelledup_get_stage_entry_queue(uuid)
  owner to postgres;
revoke all on function public.levelledup_get_stage_entry_queue(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_get_stage_entry_queue(uuid)
  to authenticated;

-- Entry pressure: is the queue outgrowing the planned capacity?
-- Behind Haider''s "Too many entries here — you can turn the entry off."
create or replace function public.levelledup_stage_entry_pressure(
  p_stage_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_stage public.tournament_stages;
  unplaced_count integer;
  open_session_count integer;
  capacity_sum integer;
  has_uncapped boolean;
begin
  perform public.levelledup_require_admin('admin');

  select stage.* into target_stage
  from public.tournament_stages as stage
  where stage.id = p_stage_id;

  if target_stage.id is null then
    raise exception 'Stage not found.' using errcode = 'P4420';
  end if;

  select count(*)::integer into unplaced_count
  from public.tournament_session_entries as e
  where e.stage_id = p_stage_id
    and e.status = 'active'
    and e.session_id is null;

  select count(*)::integer,
         coalesce(sum(session.max_teams), 0)::integer,
         bool_or(session.max_teams is null)
  into open_session_count, capacity_sum, has_uncapped
  from public.tournament_stage_sessions as session
  where session.stage_id = p_stage_id
    and session.status in ('planned', 'open')
    and not public.levelledup_session_has_started(session.id);

  return jsonb_build_object(
    'stage_id', p_stage_id,
    'entries_open', target_stage.entries_open,
    'unplaced_entries', unplaced_count,
    'open_sessions', open_session_count,
    'total_capacity', case when has_uncapped then null else capacity_sum end,
    'over_capacity', not coalesce(has_uncapped, true)
      and unplaced_count > coalesce(capacity_sum, 0)
  );
end;
$$;

comment on function public.levelledup_stage_entry_pressure(uuid) is
  'Admin: unplaced queue depth vs planned session capacity for a stage. over_capacity backs the "Too many entries here" warning.';

alter function public.levelledup_stage_entry_pressure(uuid)
  owner to postgres;
revoke all on function public.levelledup_stage_entry_pressure(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_stage_entry_pressure(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Section 13: lapse at stage end.
-- When a stage closes, unused FREE entries expire (no refund, no credit, no
-- carry) and the team is told plainly. Unused PAID entries that were never
-- placed stay live — the money was taken — each team is told to contact the
-- admin, and Haider gets a staff alert. (Exact refund/credit math is 200000.)
-- ---------------------------------------------------------------------------

-- The staff inbox kind allowlist gains one entry for the Haider alert.
alter table public.staff_notifications
  drop constraint staff_notifications_kind_valid;

alter table public.staff_notifications
  add constraint staff_notifications_kind_valid check (
    kind in ('self_approval_attempt', 'payment_needs_verification',
             'payment_rejected', 'unplaced_paid_entries_at_stage_close')
  );

create or replace function public.levelledup_expire_unused_earned_entries()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  stage_name text;
  r record;
  super_admin_id uuid;
  unplaced_paid_count integer;
begin
  if new.status in ('completed', 'cancelled')
    and old.status not in ('completed', 'cancelled') then

    select st.display_name into stage_name
    from public.tournament_stages as st
    where st.id = new.id;

    -- Unused free entries lapse with zero value. Entries already holding an
    -- active lobby assignment are left alone for Haider to see, never
    -- silently expired under an assignment.
    for r in
      select en.id as entry_id,
             en.team_id as team_id,
             en.tournament_id as tournament_id
      from public.tournament_session_entries as en
      where en.stage_id = new.id
        and en.status = 'active'
        and en.source_type = 'earned'
        and not public.levelledup_session_entry_consumed(en.id)
        and not exists (
          select 1
          from public.tournament_stage_assignments as assignment
          where assignment.session_entry_id = en.id
            and assignment.status = 'assigned'
        )
    loop
      update public.tournament_session_entries as en
      set status = 'expired',
          expired_at = now(),
          expired_reason = 'Stage "' || coalesce(stage_name, '?')
            || '" ended with this free entry unused. Free entries are not refunded, carry no credit, and cannot move to the next stage.'
      where en.id = r.entry_id;

      perform public.levelledup__notify_team(
        r.team_id,
        r.tournament_id,
        'earned_entry_expired',
        'Free entry expired',
        'Your FREE entry for "' || coalesce(stage_name, 'the stage')
          || '" expired unused. Free entries are not refunded and cannot move to the next stage.',
        jsonb_build_object(
          'session_entry_id', r.entry_id::text,
          'stage_id', new.id::text
        )
      );
    end loop;

    -- Unplaced PAID entries: the money was taken, so they stay live.
    for r in
      select en.id as entry_id,
             en.team_id as team_id,
             en.tournament_id as tournament_id
      from public.tournament_session_entries as en
      where en.stage_id = new.id
        and en.status = 'active'
        and en.source_type = 'paid'
        and en.session_id is null
    loop
      perform public.levelledup__notify_team(
        r.team_id,
        r.tournament_id,
        'paid_entry_unplaced_at_stage_close',
        'Your paid entry was never placed',
        'The stage "' || coalesce(stage_name, '?')
          || '" ended before your paid entry was placed in a session. Contact the admin about your payment.',
        jsonb_build_object(
          'session_entry_id', r.entry_id::text,
          'stage_id', new.id::text
        )
      );
    end loop;

    select count(*)::integer into unplaced_paid_count
    from public.tournament_session_entries as en
    where en.stage_id = new.id
      and en.status = 'active'
      and en.source_type = 'paid'
      and en.session_id is null;

    if unplaced_paid_count > 0 then
      select admin_users.user_id into super_admin_id
      from public.admin_users as admin_users
      where admin_users.role = 'super_admin'
        and admin_users.is_active
      limit 1;

      if super_admin_id is not null then
        insert into public.staff_notifications (
          recipient_user_id, kind, title, body, team_id, tournament_id
        ) values (
          super_admin_id,
          'unplaced_paid_entries_at_stage_close',
          'Stage closed with unplaced paid entries',
          'Stage "' || coalesce(stage_name, '?') || '" closed with '
            || unplaced_paid_count::text
            || ' paid '
            || case when unplaced_paid_count = 1 then 'entry' else 'entries' end
            || ' never placed in a session. The teams were told to contact the admin; settle their payments.',
          null,
          new.tournament_id
        );
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.levelledup_expire_unused_earned_entries() is
  'Trigger: when a stage closes, unused free entries expire (no value); unplaced paid entries stay live with team + Haider alerts.';

alter function public.levelledup_expire_unused_earned_entries()
  owner to postgres;

drop trigger if exists trg_expire_unused_earned_entries
  on public.tournament_stages;

create trigger trg_expire_unused_earned_entries
  after update of status on public.tournament_stages
  for each row
  execute function public.levelledup_expire_unused_earned_entries();

-- ---------------------------------------------------------------------------
-- Section 14: widen the session-entry history guard for the queue model.
-- Two defects fixed here:
--   1. The guard made session_id and source_provenance fully immutable, so
--      the 130000 admin session move could never run (it updates both), and
--      Haider''s queue placement / unplacement would fail the same way.
--      Session changes are now allowed while the entry stays active; the
--      place / unplace / move RPCs keep enforcing their own rules.
--   2. Only active -> cancelled was allowed. The lapse trigger needs
--      active -> expired for unused free entries at stage end.
-- Everything else stays locked: identity, money links, reason, request id,
-- created_by/created_at, no deletes, no other status jumps.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_guard_session_entry_history()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Session Entry history cannot be deleted.'
      using errcode = '22023';
  end if;

  if new.id is distinct from old.id
    or new.tournament_id is distinct from old.tournament_id
    or new.stage_id is distinct from old.stage_id
    or new.registration_id is distinct from old.registration_id
    or new.team_id is distinct from old.team_id
    or new.source_type is distinct from old.source_type
    or new.source_paid_entry_id is distinct from old.source_paid_entry_id
    or new.earned_from_session_entry_id is distinct from old.earned_from_session_entry_id
    or new.qualification_event_id is distinct from old.qualification_event_id
    or new.source_credit_ledger_entry_id is distinct from old.source_credit_ledger_entry_id
    or new.source_occurred_at is distinct from old.source_occurred_at
    or new.reason is distinct from old.reason
    or new.request_id is distinct from old.request_id
    or new.is_legacy_backfill is distinct from old.is_legacy_backfill
    or new.created_by is distinct from old.created_by
    or new.created_by_role is distinct from old.created_by_role
    or new.created_at is distinct from old.created_at then
    raise exception 'Session Entry identity and source provenance are immutable.'
      using errcode = '22023';
  end if;

  -- Queue movement: session_id may change only while the entry stays active
  -- (Haider''s placement, unplacement, and the 130000 admin session move).
  if new.session_id is distinct from old.session_id
    and not (old.status = 'active' and new.status = 'active') then
    raise exception 'A Session Entry can only change sessions while active.'
      using errcode = '22023';
  end if;

  -- Move audit notes live next to the session change.
  if new.source_provenance is distinct from old.source_provenance
    and not (old.status = 'active' and new.status = 'active') then
    raise exception 'Session Entry provenance can only be annotated while active.'
      using errcode = '22023';
  end if;

  -- Terminal states: cancelled (existing) and expired (unused free entries
  -- at stage end). Nothing leaves a terminal state.
  if new.status is distinct from old.status
    and not (old.status = 'active'
             and new.status in ('cancelled', 'expired')) then
    raise exception 'Invalid Session Entry status transition.'
      using errcode = '22023';
  end if;

  if new.status = 'cancelled' and exists(
    select 1
    from public.tournament_stage_assignments as assignment
    where assignment.session_entry_id = old.id
      and assignment.status = 'assigned'
  ) then
    raise exception 'Release the active Lobby assignment before cancelling its Session Entry.'
      using errcode = '22023';
  end if;

  if new.status = 'cancelled' and exists(
    select 1
    from public.tournament_session_entries as child
    where child.earned_from_session_entry_id = old.id
      and child.status = 'active'
  ) then
    raise exception 'A Session Entry backing active earned participation cannot be cancelled.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function public.levelledup_guard_session_entry_history() is
  'History guard. session_id may move while active (queue placement, unplacement, admin move); active may go to cancelled or expired; all identity and money links stay immutable.';

alter function public.levelledup_guard_session_entry_history()
  owner to postgres;

-- ---------------------------------------------------------------------------
-- Section 15: next-entry card, rewritten for the queue model.
-- The old card promised the team a SPECIFIC session ("your free entry is for
-- Session X"). Under Haider''s queue model nobody is promised a session:
-- entries wait unplaced and Haider places them. The card now reports the
-- queue position for earned entries and stage-level purchase info otherwise.
-- ---------------------------------------------------------------------------

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
  best_qual public.tournament_stage_qualifiers;
  best_stage_number integer;
  best_stage_name text;
  next_stage public.tournament_stages;
  target_stage public.tournament_stages;
  pricing_session public.tournament_stage_sessions;
  earned_entry public.tournament_session_entries;
  queue_no integer;
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
      -- Was the free entry granted? Then report the queue position.
      select e.* into earned_entry
      from public.tournament_session_entries as e
      where e.id = best_qual.earned_entry_id
        and e.status = 'active';

      if earned_entry.id is not null then
        select q.rn into queue_no
        from (
          select e2.id,
                 row_number() over (order by e2.created_at, e2.id)::integer as rn
          from public.tournament_session_entries as e2
          where e2.stage_id = next_stage.id
            and e2.status = 'active'
        ) as q
        where q.id = earned_entry.id;

        return jsonb_build_object(
          'kind', 'qualified_queued',
          'stage_id', next_stage.id,
          'stage_name', next_stage.display_name,
          'queue_number', queue_no,
          'session_placed', earned_entry.session_id is not null,
          'placement_finalized', earned_entry.placement_finalized,
          'fee_minor', 0,
          'qualifier_id', best_qual.id,
          'qualified_from_stage_id', best_qual.stage_id,
          'qualified_from_stage_name', best_stage_name,
          'qualifier_rank', best_qual.rank
        );
      end if;

      -- Qualified but the free entry is not granted yet: the team waits,
      -- no session is promised.
      return jsonb_build_object(
        'kind', 'qualified_next_stage_free',
        'stage_id', next_stage.id,
        'stage_name', next_stage.display_name,
        'fee_minor', 0,
        'qualifier_id', best_qual.id,
        'qualified_from_stage_id', best_qual.stage_id,
        'qualified_from_stage_name', best_stage_name,
        'qualifier_rank', best_qual.rank
      );
    end if;

    -- No free road left: a qualified team may still replay the stage it
    -- qualified from, but it pays like everyone else (per stage now).
    select st.* into target_stage
    from public.tournament_stages as st
    where st.id = best_qual.stage_id
      and st.status not in ('completed', 'cancelled')
    limit 1;

    if target_stage.id is not null then
      select sess.* into pricing_session
      from public.tournament_stage_sessions as sess
      where sess.stage_id = target_stage.id
        and sess.status in ('planned', 'open')
        and not public.levelledup_session_has_started(sess.id)
      order by sess.session_number, sess.id
      limit 1;

      if pricing_session.id is not null then
        return jsonb_build_object(
          'kind', 'qualified_stage_replay_paid',
          'stage_id', target_stage.id,
          'stage_name', target_stage.display_name,
          'fee_minor', pricing_session.entry_fee_minor,
          'currency', pricing_session.fee_currency,
          'entries_open', target_stage.entries_open,
          'qualifier_id', best_qual.id
        );
      end if;
    end if;

    return jsonb_build_object('kind', 'closed');
  end if;

  -- Not qualified: the earliest stage that is still alive.
  select stage.* into target_stage
  from public.tournament_stages as stage
  where stage.tournament_id = p_tournament_id
    and stage.status not in ('completed', 'cancelled')
  order by stage.stage_number
  limit 1;

  if target_stage.id is null then
    return jsonb_build_object('kind', 'closed');
  end if;

  select sess.* into pricing_session
  from public.tournament_stage_sessions as sess
  where sess.stage_id = target_stage.id
    and sess.status in ('planned', 'open')
    and not public.levelledup_session_has_started(sess.id)
  order by sess.session_number, sess.id
  limit 1;

  if pricing_session.id is null then
    return jsonb_build_object(
      'kind', 'closed',
      'stage_id', target_stage.id,
      'stage_name', target_stage.display_name
    );
  end if;

  return jsonb_build_object(
    'kind', case
      when pricing_session.entry_fee_minor > 0 then 'next_stage_paid'
      else 'next_stage_free'
    end,
    'stage_id', target_stage.id,
    'stage_name', target_stage.display_name,
    'fee_minor', pricing_session.entry_fee_minor,
    'currency', pricing_session.fee_currency,
    'entries_open', target_stage.entries_open
  );
end;
$$;

comment on function public.levelledup_get_next_entry_option(uuid, uuid) is
  'Team next-entry card for the queue model: earned entries report their queue number (no session promised); paid options are stage-level with the entries_open flag.';

alter function public.levelledup_get_next_entry_option(uuid, uuid)
  owner to postgres;

commit;
