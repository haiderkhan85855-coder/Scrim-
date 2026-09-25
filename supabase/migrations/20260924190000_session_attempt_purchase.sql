-- 190000 — session-attempt purchase (the 700).
--
-- Locked product rules (Haider, 2026-09-25):
--   * "A paid entry covers exactly one session only. If a team fails and
--     wants to play the next session, they pay for that session
--     (retry = pay per session)."
--   * Any payment method is allowed. Reference ID + screenshot are both
--     mandatory at submit time (180000). A payment can never be pending
--     without a screenshot.
--   * Anyone can buy into any stage that is open for pay-to-play — no
--     qualification needed to enter. BUT the participation chain applies:
--     to ENTER stage N (N > 1) for the first time, the team must have
--     PLAYED at least one match in stage N-1 (sitting in a lobby whose
--     match went live or completed). Stage 1 has no prerequisite.
--   * The chain can be skipped with DIRECT ENTRY: a per-stage price Haider
--     sets when configuring the stage (e.g. normal 700, direct 1050).
--     If a stage has no direct-entry price, skipping is not offered there.
--   * The chain/skip gate applies only when ENTERING a stage. Retrying
--     within a stage the team already entered always costs the normal fee.
--   * Admin verify AUTO-MINTS the paid entry + session entry. One admin
--     action, no forgotten second step. If the world changed while the
--     payment was pending (session started / full / entry exists), verify
--     fails loudly instead of minting a bad entry.
--   * One pending session payment per team at a time ("paid one at a time").
--   * Free sessions (fee 0) refuse payment here; the free-claim path is a
--     separate follow-up file.
--   * Session payments never mix with registration (500) payments:
--     payment_purpose separates them, the unique indexes are purpose-aware,
--     and the submit gates make cross-use structurally impossible
--     (registration submit needs a pending registration; session submit
--     needs a confirmed one).
--
-- Covered here:
--   1. tournament_stages.direct_entry_fee_minor (per-stage skip price,
--      null = no direct entry offered).
--   2. tournament_registration_payments.payment_purpose
--      ('registration' | 'session_attempt').
--   3. Purpose-aware unique indexes (one open registration payment per
--      registration; one open session payment per registration+session).
--   4. levelledup_submit_session_attempt_payment — captain submit with the
--      chain / direct-entry / retry pricing.
--   5. Auto-mint trigger on payment verify (+ team inbox notification).
--   6. levelledup_admin_set_stage_direct_entry_fee — Haider's per-stage
--      price control until the app UI exists.

begin;

-- ---------------------------------------------------------------------------
-- 1. Per-stage direct-entry price. Null = direct entry not offered.
-- ---------------------------------------------------------------------------

alter table public.tournament_stages
  add column if not exists direct_entry_fee_minor integer;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'tournament_stages_direct_entry_fee_valid'
  ) then
    alter table public.tournament_stages
      add constraint tournament_stages_direct_entry_fee_valid
      check (direct_entry_fee_minor is null or direct_entry_fee_minor > 0);
  end if;
end
$$;

comment on column public.tournament_stages.direct_entry_fee_minor is
  'Direct-entry (skip) price for this stage in minor units. Null means direct entry is not offered: entering this stage requires the participation chain (a played match in the previous stage).';

-- ---------------------------------------------------------------------------
-- 2. Payment purpose: registration (500) vs session_attempt (700) never mix.
-- ---------------------------------------------------------------------------

alter table public.tournament_registration_payments
  add column if not exists payment_purpose text not null default 'registration';

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'tournament_registration_payments_purpose_valid'
  ) then
    alter table public.tournament_registration_payments
      add constraint tournament_registration_payments_purpose_valid
      check (payment_purpose in ('registration', 'session_attempt'));
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Purpose-aware uniqueness. The old registration-only index is replaced.
-- ---------------------------------------------------------------------------

drop index if exists tournament_registration_payments_one_open_attempt_idx;

create unique index if not exists tournament_registration_payments_one_open_registration_attempt_idx
  on public.tournament_registration_payments (registration_id)
  where status in ('pending', 'verified') and payment_purpose = 'registration';

create unique index if not exists tournament_registration_payments_one_open_session_attempt_idx
  on public.tournament_registration_payments (registration_id, session_id)
  where status in ('pending', 'verified') and payment_purpose = 'session_attempt';

-- ---------------------------------------------------------------------------
-- 4. Captain submits a session-attempt payment.
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
  authenticated_user_id uuid := auth.uid();
  normalized_reference text := btrim(coalesce(p_reference_id, ''));
  normalized_screenshot text := btrim(coalesce(p_screenshot_url, ''));
  registration public.tournament_registrations;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
  prev_stage public.tournament_stages;
  already_in_stage boolean := false;
  chain_ok boolean := false;
  expected_amount integer;
  price_kind text;
  total_capacity integer;
  assigned_count integer;
  created_payment public.tournament_registration_payments;
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

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = p_session_id
  for share;

  if selected_session.id is null then
    raise exception 'Session not found.' using errcode = 'P4420';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null
    or registration.tournament_id <> selected_session.tournament_id then
    raise exception 'Registration and Session must belong to the same Tournament.'
      using errcode = '23503';
  end if;

  if not public.levelledup_is_active_team_captain(registration.team_id) then
    raise exception 'Only the active team Captain can submit payment.'
      using errcode = '42501';
  end if;

  if registration.status <> 'confirmed' then
    raise exception 'Only a confirmed registration can buy a session attempt.'
      using errcode = 'P4503';
  end if;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = selected_session.stage_id
    and stage.tournament_id = selected_session.tournament_id
  for share;

  if selected_stage.id is null
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'This stage is closed for new entries.'
      using errcode = 'P4420';
  end if;

  -- Entry lock: a started session is closed.
  if public.levelledup_session_has_started(selected_session.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Payment requires a future Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  -- Free sessions need no payment (free claim is a separate follow-up).
  if selected_session.entry_fee_minor = 0 then
    raise exception 'This session is free; payment is not required.'
      using errcode = 'P4504';
  end if;

  -- One entry per team per session.
  if exists (
    select 1
    from public.tournament_session_entries as entry
    where entry.registration_id = registration.id
      and entry.session_id = selected_session.id
      and entry.status = 'active'
  ) then
    raise exception 'This team already has an active entry in this session.'
      using errcode = '23505';
  end if;

  -- Room check, only when lobbies already exist in the target session.
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
      raise exception 'The target session is full.'
        using errcode = 'P4005';
    end if;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(registration.id::text || ':session_payment', 0)
  );

  -- One pending session payment per team at a time.
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
      and entry.stage_id = selected_stage.id
      and entry.status = 'active'
  ) into already_in_stage;

  if already_in_stage or selected_stage.stage_number = 1 then
    expected_amount := selected_session.entry_fee_minor;
    price_kind := 'normal';
  else
    -- The participation chain: played at least one match in the previous
    -- stage (assigned to a lobby whose match went live or completed).
    select stage.* into prev_stage
    from public.tournament_stages as stage
    where stage.tournament_id = selected_stage.tournament_id
      and stage.stage_number = selected_stage.stage_number - 1
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
      expected_amount := selected_session.entry_fee_minor;
      price_kind := 'normal';
    elsif selected_stage.direct_entry_fee_minor is not null then
      expected_amount := selected_stage.direct_entry_fee_minor;
      price_kind := 'direct_entry';
    else
      raise exception 'Direct entry is not available for this stage yet. Play the previous stage first.'
        using errcode = 'P4422';
    end if;
  end if;

  insert into public.tournament_registration_payments (
    registration_id, tournament_id, team_id, session_id,
    payment_method, payment_purpose, status,
    expected_amount_minor, currency,
    reference_id, submitted_by,
    screenshot_url, screenshot_uploaded_at, screenshot_exempt
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    selected_session.id, 'manual', 'session_attempt', 'pending',
    expected_amount, selected_session.fee_currency,
    normalized_reference, authenticated_user_id,
    normalized_screenshot, now(), false
  ) returning * into created_payment;

  return created_payment;
exception
  when unique_violation then
    get stacked diagnostics violated_constraint = constraint_name;
    if violated_constraint = 'tournament_registration_payments_manual_reference_unique_idx' then
      raise exception 'This payment reference has already been used. Each bank transaction can back only one payment.'
        using errcode = 'P4510';
    end if;
    raise exception 'This registration already has a pending or verified session payment for this session.'
      using errcode = 'P4505';
end;
$$;

alter function public.levelledup_submit_session_attempt_payment(uuid, uuid, text, text)
  owner to postgres;
revoke all on function public.levelledup_submit_session_attempt_payment(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_submit_session_attempt_payment(uuid, uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Auto-mint on verify: a verified session payment becomes a paid entry
--    plus a session entry, atomically. If the world changed while the
--    payment was pending, verification fails loudly instead of minting.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_mint_session_entry_on_payment_verified()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
  registration public.tournament_registrations;
  prev_stage public.tournament_stages;
  already_in_stage boolean := false;
  chain_ok boolean := false;
  price_kind text := 'normal';
  actor_role text;
  session_label text;
  reason_text text;
  paid_entry_id uuid;
  new_entry_id uuid;
  notification_id uuid;
  total_capacity integer;
  assigned_count integer;
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

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = new.session_id
  for share;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = selected_session.stage_id
  for share;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = new.registration_id
  for share;

  if selected_session.id is null
    or selected_stage.id is null
    or registration.id is null then
    raise exception 'Verified session payment references a missing session.'
      using errcode = '23503';
  end if;

  -- The world may have changed while the payment sat pending.
  if public.levelledup_session_has_started(selected_session.id) then
    raise exception 'This session is already closed.'
      using errcode = 'P4407';
  end if;

  if selected_session.status not in ('planned', 'open') then
    raise exception 'The session is no longer open for entry.'
      using errcode = 'P4421';
  end if;

  if exists (
    select 1
    from public.tournament_session_entries as entry
    where entry.registration_id = new.registration_id
      and entry.session_id = new.session_id
      and entry.status = 'active'
  ) then
    raise exception 'This team already has an active entry in this session.'
      using errcode = '23505';
  end if;

  select coalesce(sum(lobby.capacity), 0)::integer into total_capacity
  from public.tournament_lobbies as lobby
  where lobby.session_id = new.session_id
    and lobby.status <> 'cancelled';

  if total_capacity > 0 then
    select count(*)::integer into assigned_count
    from public.tournament_stage_assignments as assignment
    where assignment.session_id = new.session_id
      and assignment.status = 'assigned';

    if assigned_count >= total_capacity then
      raise exception 'The target session is full.'
        using errcode = 'P4005';
    end if;
  end if;

  -- Re-derive the price kind for the audit trail.
  select exists (
    select 1
    from public.tournament_session_entries as entry
    where entry.registration_id = new.registration_id
      and entry.stage_id = selected_stage.id
      and entry.status = 'active'
  ) into already_in_stage;

  if not already_in_stage and selected_stage.stage_number > 1 then
    select stage.* into prev_stage
    from public.tournament_stages as stage
    where stage.tournament_id = selected_stage.tournament_id
      and stage.stage_number = selected_stage.stage_number - 1
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

  session_label := selected_stage.display_name || ' - ' || selected_session.display_name;

  insert into public.tournament_registration_paid_entries (
    registration_id, tournament_id, team_id, stage_id, session_id,
    entry_scope, source_payment_id, amount_minor, currency, status, created_by
  ) values (
    new.registration_id, new.tournament_id, new.team_id,
    selected_stage.id, new.session_id,
    'session', new.id, new.expected_amount_minor, new.currency,
    'paid', new.submitted_by
  ) returning id into paid_entry_id;

  if price_kind = 'direct_entry' then
    reason_text := 'Session attempt purchase: verified direct-entry payment of '
      || new.expected_amount_minor::text || ' ' || new.currency
      || ' for session "' || session_label || '".';
  else
    reason_text := 'Session attempt purchase: verified payment of '
      || new.expected_amount_minor::text || ' ' || new.currency
      || ' for session "' || session_label || '".';
  end if;

  insert into public.tournament_session_entries (
    tournament_id, stage_id, session_id, registration_id, team_id,
    source_type, source_paid_entry_id, source_occurred_at, source_provenance,
    reason, request_id, created_by, created_by_role
  ) values (
    new.tournament_id, selected_stage.id, new.session_id,
    new.registration_id, new.team_id,
    'paid', paid_entry_id, now(),
    jsonb_build_object(
      'payment_id', new.id::text,
      'price_kind', price_kind,
      'amount_minor', new.expected_amount_minor,
      'currency', new.currency
    ),
    reason_text, gen_random_uuid(), auth.uid(), actor_role
  ) returning id into new_entry_id;

  -- Team inbox notification.
  insert into public.team_notifications
    (team_id, tournament_id, type, title, message, metadata)
  values (
    new.team_id, new.tournament_id,
    'session_entry',
    'Entry confirmed',
    'Your '
      || case when price_kind = 'direct_entry' then 'direct entry' else 'session entry' end
      || ' for "' || session_label || '" is confirmed. Good luck!',
    jsonb_build_object(
      'session_entry_id', new_entry_id::text,
      'session_id', new.session_id::text
    )
  ) returning id into notification_id;

  insert into public.team_notification_recipients (notification_id, user_id)
  select notification_id, member.profile_id
  from public.team_roster_members as member
  where member.team_id = new.team_id
    and member.status = 'active'
    and member.profile_id is not null
  on conflict do nothing;

  return new;
end;
$$;

alter function public.levelledup_mint_session_entry_on_payment_verified()
  owner to postgres;

drop trigger if exists trg_mint_session_entry_on_payment_verified
  on public.tournament_registration_payments;

create trigger trg_mint_session_entry_on_payment_verified
  after update of status on public.tournament_registration_payments
  for each row
  execute function public.levelledup_mint_session_entry_on_payment_verified();

-- ---------------------------------------------------------------------------
-- 6. Haider's per-stage direct-entry price control (until the app UI exists).
--    Pass null to stop offering direct entry for the stage.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_admin_set_stage_direct_entry_fee(
  p_stage_id uuid,
  p_fee_minor integer
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

  if p_fee_minor is not null and p_fee_minor <= 0 then
    raise exception 'The direct entry fee must be positive.'
      using errcode = '22023';
  end if;

  update public.tournament_stages
  set direct_entry_fee_minor = p_fee_minor,
      updated_at = now()
  where id = p_stage_id
  returning * into selected_stage;

  if selected_stage.id is null then
    raise exception 'Stage not found.' using errcode = 'P4420';
  end if;

  return selected_stage;
end;
$$;

alter function public.levelledup_admin_set_stage_direct_entry_fee(uuid, integer)
  owner to postgres;
revoke all on function public.levelledup_admin_set_stage_direct_entry_fee(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_set_stage_direct_entry_fee(uuid, integer)
  to authenticated;

commit;

-- ---------------------------------------------------------------------------
-- 7. Admin review, extended for session-attempt verification.
--    The review RPC from 110000 (self-approval trap) only allowed 'verify'
--    while the registration was still pending. Session-attempt payments are
--    submitted after confirmation, so without this change they could never be
--    verified and section 5 would never fire. Everything else is unchanged:
--    the trap, the reject-reason rule, and the pending-only rule for
--    registration payments.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_admin_review_tournament_payment(
  p_payment_id uuid,
  p_decision text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_decision text := lower(btrim(coalesce(p_decision, '')));
  trimmed_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  actor_id uuid := auth.uid();
  actor_role text;
  selected_payment public.tournament_registration_payments;
  registration_status text;
  team_name text;
  tournament_name text;
  actor_display text;
  super_admin_id uuid;
  other_staff_id uuid;
  blocked_message constant text :=
    'Nice try 😄 — you can’t approve your own team’s payment. The boss has been notified. Haha.';
begin
  perform public.levelledup_require_admin('admin');

  if normalized_decision not in ('verify', 'reject') then
    raise exception 'Unsupported payment review decision.'
      using errcode = 'P4506';
  end if;

  if normalized_decision = 'reject' and trimmed_reason is null then
    raise exception 'A reason is required to reject a payment.'
      using errcode = 'P4509';
  end if;

  if trimmed_reason is not null and char_length(trimmed_reason) > 1000 then
    raise exception 'The rejection reason is too long.'
      using errcode = '22023';
  end if;

  select payments.*
  into selected_payment
  from public.tournament_registration_payments as payments
  where payments.id = p_payment_id
  for update;

  if selected_payment.id is null
    or selected_payment.status <> 'pending'
    or selected_payment.payment_method <> 'manual' then
    raise exception 'Pending payment submission not found.'
      using errcode = 'P4507';
  end if;

  select admin_users.role
  into actor_role
  from public.admin_users as admin_users
  where admin_users.user_id = actor_id
    and admin_users.is_active;

  -- Self-approval trap: everyone except the Super Admin is completely hands-off
  -- on payments for teams where they are an active roster member.
  if actor_role is distinct from 'super_admin'
    and exists (
      select 1
      from public.team_roster_members as members
      where members.team_id = selected_payment.team_id
        and members.profile_id = actor_id
        and members.status = 'active'
    ) then
    select teams.name
    into team_name
    from public.teams as teams
    where teams.id = selected_payment.team_id;

    select tournaments.name
    into tournament_name
    from public.tournaments as tournaments
    where tournaments.id = selected_payment.tournament_id;

    select coalesce(profiles.display_name, 'An admin')
    into actor_display
    from public.profiles as profiles
    where profiles.id = actor_id;

    select admin_users.user_id
    into super_admin_id
    from public.admin_users as admin_users
    where admin_users.role = 'super_admin'
      and admin_users.is_active
    limit 1;

    -- The attempt itself is visible to the Super Admin ONLY.
    if super_admin_id is not null then
      insert into public.staff_notifications (
        recipient_user_id, kind, title, body,
        payment_id, team_id, tournament_id
      ) values (
        super_admin_id,
        'self_approval_attempt',
        'Self-approval attempt blocked',
        actor_display || ' tried to ' || normalized_decision ||
          ' the payment for their own team "' || coalesce(team_name, '?') ||
          '" (' || coalesce(tournament_name, '?') ||
          '). Blocked automatically; the payment is still pending.',
        selected_payment.id,
        selected_payment.team_id,
        selected_payment.tournament_id
      );
    end if;

    -- Everyone else on staff (except the actor) just gets a work item:
    -- this payment still needs a legitimate review. No mention of the attempt.
    for other_staff_id in
      select admin_users.user_id
      from public.admin_users as admin_users
      where admin_users.is_active
        and admin_users.user_id is distinct from actor_id
    loop
      insert into public.staff_notifications (
        recipient_user_id, kind, title, body,
        payment_id, team_id, tournament_id
      ) values (
        other_staff_id,
        'payment_needs_verification',
        'Payment needs verification',
        'The payment for team "' || coalesce(team_name, '?') ||
          '" (' || coalesce(tournament_name, '?') ||
          ') is waiting for review. Please verify it.',
        selected_payment.id,
        selected_payment.team_id,
        selected_payment.tournament_id
      );
    end loop;

    -- No raise: the notifications above must survive. The UI shows the message.
    return jsonb_build_object('status', 'blocked', 'message', blocked_message);
  end if;

  select registrations.status
  into registration_status
  from public.tournament_registrations as registrations
  where registrations.id = selected_payment.registration_id
  for share;

  -- 190000: session-attempt payments are bought only after the registration
  -- is confirmed, so a confirmed registration may receive a verified session
  -- attempt. Registration payments (purpose 'registration' or legacy null)
  -- still require a pending registration.
  if normalized_decision = 'verify' and registration_status <> 'pending' then
    if selected_payment.payment_purpose is distinct from 'session_attempt'
       or registration_status <> 'confirmed' then
      raise exception 'Only a pending tournament registration can receive verified payment.'
        using errcode = 'P4503';
    end if;
  end if;

  update public.tournament_registration_payments
  set
    status = case normalized_decision
      when 'verify' then 'verified'
      else 'rejected'
    end,
    verification_source = 'admin',
    review_reason = trimmed_reason,
    reviewed_by = actor_id,
    reviewed_at = now()
  where id = selected_payment.id
  returning * into selected_payment;

  -- A rejection is contestable: tell every other active staff member why,
  -- with the payment attached (the screenshot rides along once screenshot
  -- upload exists).
  if normalized_decision = 'reject' then
    select teams.name
    into team_name
    from public.teams as teams
    where teams.id = selected_payment.team_id;

    select tournaments.name
    into tournament_name
    from public.tournaments as tournaments
    where tournaments.id = selected_payment.tournament_id;

    for other_staff_id in
      select admin_users.user_id
      from public.admin_users as admin_users
      where admin_users.is_active
        and admin_users.user_id is distinct from actor_id
    loop
      insert into public.staff_notifications (
        recipient_user_id, kind, title, body,
        payment_id, team_id, tournament_id
      ) values (
        other_staff_id,
        'payment_rejected',
        'Payment rejected',
        'The payment for team "' || coalesce(team_name, '?') ||
          '" (' || coalesce(tournament_name, '?') ||
          ') was rejected. Reason: ' || trimmed_reason,
        selected_payment.id,
        selected_payment.team_id,
        selected_payment.tournament_id
      );
    end loop;
  end if;

  return jsonb_build_object(
    'status', normalized_decision,
    'payment_id', selected_payment.id
  );
end;
$$;

alter function public.levelledup_admin_review_tournament_payment(uuid, text, text)
  owner to postgres;
revoke all on function public.levelledup_admin_review_tournament_payment(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_review_tournament_payment(uuid, text, text)
  to authenticated;

comment on function public.levelledup_admin_review_tournament_payment(uuid, text, text) is
  'Admin payment review with the self-approval trap. Tournament Admins are blocked (not raised) from touching their own team''s payments; the block returns {status:''blocked''} so the attempt notification survives. Rejection requires a reason. Super Admin is exempt. 190000: verify is additionally allowed for session_attempt payments on confirmed registrations; registration payments still require a pending registration.';

-- ---------------------------------------------------------------------------
-- 8. Purpose-aware initial-session validator.
--    The 130000 initial-session contract trigger fires on every payment insert
--    and validates it as an initial registration payment (exact selected
--    Stage 1 session). Session-attempt payments target any session the rules
--    allow, so they skip that contract; their own checks live in section 4.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_validate_initial_session_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  tournament public.tournaments;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
begin
  -- 190000: session-attempt payments carry their own validation inside
  -- levelledup_submit_session_attempt_payment (session choice, stage pricing,
  -- room, duplicates). The initial-session contract below applies only to
  -- registration payments.
  if new.payment_purpose = 'session_attempt' then
    return new;
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = new.registration_id;

  select current_tournament.* into tournament
  from public.tournaments as current_tournament
  where current_tournament.id = new.tournament_id;

  select current_session.* into selected_session
  from public.tournament_stage_sessions as current_session
  where current_session.id = new.session_id;

  select current_stage.* into selected_stage
  from public.tournament_stages as current_stage
  where current_stage.id = selected_session.stage_id;

  if registration.id is null or tournament.id is null
    or selected_session.id is null
    or registration.initial_session_id is distinct from selected_session.id
    or registration.tournament_id <> new.tournament_id
    or registration.team_id <> new.team_id
    or selected_session.tournament_id <> new.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> new.tournament_id
    or selected_stage.stage_number <> 1
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'A new initial payment must match the registration''s exact selected Stage 1 Session.'
      using errcode = '23503';
  end if;

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Payment requires a future selected Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  if tournament.entry_fee_minor <= 0 then
    raise exception 'This Tournament has no initial registration fee; payment is not required.'
      using errcode = 'P4504';
  end if;

  if new.expected_amount_minor::bigint <> tournament.entry_fee_minor
    or new.currency <> tournament.currency then
    raise exception 'Payment amount and currency must equal the authoritative Tournament initial registration fee.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Purpose-aware paid-entry amount validation.
--    The 110000 paid-entry validator requires every session paid entry (and
--    its source payment) to equal the session fee. A direct-entry session
--    attempt legitimately costs the stage's direct-entry premium instead, so
--    verifying one was impossible. For session_attempt source payments the
--    authoritative amount is now exactly what the pricing rules charged;
--    registration payments keep the old session-fee equality.
-- ---------------------------------------------------------------------------

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
    select session.* into selected_session
    from public.tournament_stage_sessions as session
    where session.id = new.session_id
      and session.stage_id = new.stage_id
      and session.tournament_id = new.tournament_id;

    if selected_session.id is null then
      raise exception 'A Session paid entry requires its exact Session in the same Stage and Tournament.'
        using errcode = '23503';
    end if;

    if source_payment.session_id is distinct from selected_session.id
      or source_payment.currency <> new.currency then
      raise exception 'A new Session allocation requires the exact authoritative payment for that same Session.'
        using errcode = '22023';
    end if;

    if source_payment.payment_purpose = 'session_attempt' then
      -- 190000: a direct-entry session attempt costs the stage's direct-entry
      -- premium, not the session fee. The submit function already priced it
      -- under the approved rules, so the paid entry must equal exactly what
      -- was paid — no more, no less.
      if new.amount_minor::bigint <> source_payment.expected_amount_minor::bigint then
        raise exception 'A Session paid entry must equal its verified session-attempt payment amount.'
          using errcode = '22023';
      end if;
    else
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

    if new.lobby_id is not null and not exists (
      select 1 from public.tournament_lobbies as lobby
      where lobby.id = new.lobby_id
        and lobby.session_id = selected_session.id
        and lobby.stage_id = new.stage_id
        and lobby.tournament_id = new.tournament_id
    ) then
      raise exception 'Paid-entry Lobby must belong to its exact Session.'
        using errcode = '23503';
    end if;
  else
    raise exception 'Paid-entry scope must be Stage or Session.' using errcode = '22023';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Purpose-aware session-entry source validation.
--    The 130000 session-entry validator requires a paid session entry to
--    equal the session fee. A direct-entry attempt's paid entry equals the
--    direct-entry premium instead, so its session entry could never be
--    created. For session_attempt-sourced paid entries the exact price is now
--    the source payment's charged amount; everything else keeps the old rule.
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

  if registration.id is null or selected_session.id is null
    or registration.tournament_id <> new.tournament_id
    or registration.team_id <> new.team_id
    or selected_session.tournament_id <> new.tournament_id
    or selected_session.stage_id <> new.stage_id then
    raise exception 'Session Entry parents must share the same Tournament, Stage, Session and registration/team.'
      using errcode = '23503';
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
    or selected_session.status not in ('planned', 'open') then
    raise exception 'A new Session Entry requires an active eligible team, confirmed Squad, and a future permitted Session.'
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
      or paid_entry.session_id <> new.session_id then
      raise exception 'Paid Session Entry requires an unused exact-price paid allocation for the same registration and Session.'
        using errcode = '22023';
    end if;

    -- 190000: a direct-entry session attempt costs the stage's direct-entry
    -- premium, not the session fee. Its paid entry must equal exactly what
    -- the pricing rules charged on the source payment.
    if source_payment.payment_purpose = 'session_attempt' then
      if paid_entry.amount_minor::bigint <> source_payment.expected_amount_minor::bigint
        or paid_entry.currency <> source_payment.currency then
        raise exception 'Paid Session Entry requires an unused exact-price paid allocation for the same registration and Session.'
          using errcode = '22023';
      end if;
    elsif paid_entry.amount_minor::bigint <> selected_session.entry_fee_minor
      or paid_entry.currency <> selected_session.fee_currency then
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
      or credit_debit.amount_delta_minor <> -selected_session.entry_fee_minor
      or credit_debit.currency <> selected_session.fee_currency
      or credit_debit.operational_team_id <> new.team_id
      or selected_team.status <> 'active'
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

-- ============================================================================
-- Section 11: duplicate manual payment references are rejected.
-- The submit RPC converts a unique-violation on the normalized manual
-- reference into a clean captain-facing error; that handler is dead code
-- without a backing constraint. One bank/EasyPaisa transaction reference may
-- back exactly one payment row, across registration and session-attempt
-- payments alike. Rejected payments keep their reference reserved so a
-- transaction cannot be recycled into a second payment.
-- ============================================================================
create unique index if not exists tournament_registration_payments_manual_reference_unique_idx
  on public.tournament_registration_payments (manual_reference_normalized)
  where payment_method = 'manual'
    and manual_reference_normalized is not null;
