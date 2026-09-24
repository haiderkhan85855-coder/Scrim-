begin;

-- Bind each new tournament registration attempt to one exact Stage 1 Session.
-- Historical rows remain NULL when no authoritative Session mapping exists.

alter table public.tournament_stage_sessions
  add constraint tournament_stage_sessions_id_tournament_unique
  unique (id, tournament_id);

alter table public.tournament_registrations
  add column initial_session_id uuid,
  add constraint tournament_registrations_initial_session_fk
    foreign key (initial_session_id, tournament_id)
    references public.tournament_stage_sessions(id, tournament_id)
    on delete restrict;

create index tournament_registrations_initial_session_idx
  on public.tournament_registrations(initial_session_id)
  where initial_session_id is not null;

comment on column public.tournament_registrations.initial_session_id is
  'Exact Stage 1 Session selected for this registration''s initial attempt. Retries use separate Session Entries and never replace this identity. NULL on unmapped legacy history means unknown.';

alter table public.tournament_registration_payments
  add column session_id uuid,
  add constraint tournament_registration_payments_session_fk
    foreign key (session_id, tournament_id)
    references public.tournament_stage_sessions(id, tournament_id)
    on delete restrict;

create index tournament_registration_payments_session_history_idx
  on public.tournament_registration_payments(session_id, submitted_at desc)
  where session_id is not null;

comment on column public.tournament_registration_payments.session_id is
  'Immutable exact Session price snapshot identity for new initial-attempt payments. NULL on preserved legacy payments means historically unknown and is never guessed.';
comment on column public.tournament_registration_payments.expected_amount_minor is
  'Authoritative exact Session fee copied by the trusted submission function for new initial attempts. Clients never provide this amount; legacy values remain preserved.';

-- A pending registration with any pre-contract payment attempt cannot safely
-- select an initial Session because payment history intentionally locks that
-- identity. Never guess or rewrite the Session for such financial history.
do $$
begin
  if exists (
    select 1
    from public.tournament_registrations as registration
    join public.tournaments as tournament
      on tournament.id = registration.tournament_id
    where registration.status = 'pending'
      and tournament.status not in ('completed', 'cancelled')
      and exists (
        select 1
        from public.tournament_registration_payments as payment
        where payment.registration_id = registration.id
          and payment.session_id is null
      )
  ) then
    raise exception 'Initial Session contract deployment blocked: legacy pending registration/payment history requires explicit manual resolution before migration.'
      using errcode = 'P4424';
  end if;
end;
$$;

-- A free initial registration is participation provenance, not a payment,
-- credit, earned qualification, or discretionary Admin grant.
alter table public.tournament_session_entries
  drop constraint tournament_session_entries_source_valid,
  drop constraint tournament_session_entries_source_exactly_one,
  add constraint tournament_session_entries_source_valid check (
    source_type in ('paid', 'earned', 'credit', 'admin_grant', 'registration')
  ),
  add constraint tournament_session_entries_source_exactly_one check (
    (source_type = 'paid' and source_paid_entry_id is not null
      and earned_from_session_entry_id is null and source_credit_ledger_entry_id is null)
    or (source_type = 'earned' and source_paid_entry_id is null
      and earned_from_session_entry_id is not null and source_credit_ledger_entry_id is null)
    or (source_type = 'credit' and source_paid_entry_id is null
      and earned_from_session_entry_id is null and source_credit_ledger_entry_id is not null)
    or (source_type in ('admin_grant', 'registration') and source_paid_entry_id is null
      and earned_from_session_entry_id is null and source_credit_ledger_entry_id is null)
  );

comment on column public.tournament_session_entries.source_type is
  'Immutable provenance category: paid, earned, credit, admin_grant, or registration. registration is the non-financial initial entitlement for a zero-fee Session.';

create function public.levelledup_validate_registration_initial_session()
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

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Select a future Stage 1 Session that is open or planned for entry.'
      using errcode = 'P4421';
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

create trigger tournament_registrations_00_validate_initial_session
before insert or update of initial_session_id
on public.tournament_registrations
for each row execute function public.levelledup_validate_registration_initial_session();

create function public.levelledup_select_registration_initial_session(
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

  if not public.levelledup_is_active_team_captain(registration.team_id) then
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

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Select a future Stage 1 Session that is open or planned for entry.'
      using errcode = 'P4421';
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

-- Once a payment attempt snapshots this Session, its price is financial
-- history and cannot move independently of that immutable payment.
create or replace function public.levelledup_guard_session_price_change()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.entry_fee_minor is not distinct from old.entry_fee_minor
    and new.fee_currency is not distinct from old.fee_currency then
    return new;
  end if;

  if old.status not in ('planned', 'open') then
    raise exception 'A started or retired Session price is historical.' using errcode = '22023';
  end if;

  if exists (
      select 1 from public.tournament_session_entries as session_entry
      where session_entry.session_id = old.id
    )
    or exists (
      select 1 from public.tournament_stage_assignments as assignment
      where assignment.session_id = old.id
    )
    or exists (
      select 1 from public.tournament_registration_payments as payment
      where payment.session_id = old.id
    )
    or exists (
      select 1 from public.tournament_registration_paid_entries as paid_entry
      where paid_entry.session_id = old.id
    )
    or exists (
      select 1 from public.tournament_stage_refund_cases as refund_case
      where refund_case.session_id = old.id
    )
    or exists (
      select 1 from public.tournament_stage_credit_entitlements as credit
      where credit.session_id = old.id
    ) then
    raise exception 'Session price is locked after participation or financial history exists.'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.tournament_session_price_events as event
    where event.session_id = old.id
      and event.event_type = 'changed'
      and event.old_entry_fee_minor = old.entry_fee_minor
      and event.new_entry_fee_minor = new.entry_fee_minor
      and event.old_fee_currency = old.fee_currency
      and event.new_fee_currency = new.fee_currency
      and event.changed_by = auth.uid()
      and event.transaction_id = txid_current()
  ) then
    raise exception 'Session price changes require the trusted audited Admin operation.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- Payment identity, including its exact Session, is immutable after insertion.
create or replace function public.levelledup_keep_tournament_payment_attempt()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Tournament payment history cannot be deleted.'
      using errcode = '22023';
  end if;

  if new.registration_id is distinct from old.registration_id
    or new.tournament_id is distinct from old.tournament_id
    or new.team_id is distinct from old.team_id
    or new.session_id is distinct from old.session_id
    or new.payment_method is distinct from old.payment_method
    or new.expected_amount_minor is distinct from old.expected_amount_minor
    or new.currency is distinct from old.currency
    or new.reference_id is distinct from old.reference_id
    or new.provider is distinct from old.provider
    or new.provider_transaction_id is distinct from old.provider_transaction_id
    or new.submitted_by is distinct from old.submitted_by
    or new.submitted_at is distinct from old.submitted_at
    or new.created_at is distinct from old.created_at then
    raise exception 'A submitted tournament payment attempt and its exact Session are immutable.'
      using errcode = '22023';
  end if;

  if old.status <> 'pending' and new.status is distinct from old.status then
    raise exception 'A reviewed tournament payment cannot change status.'
      using errcode = '22023';
  end if;

  if old.cancelled_reconciled_at is not null
    and (
      new.cancelled_reconciled_at is distinct from old.cancelled_reconciled_at
      or new.cancelled_reconciled_by is distinct from old.cancelled_reconciled_by
    ) then
    raise exception 'Cancelled-payment reconciliation provenance is immutable.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create function public.levelledup_validate_initial_session_payment()
returns trigger
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
  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = new.registration_id;

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = new.session_id;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = selected_session.stage_id;

  if registration.id is null
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

  if selected_session.entry_fee_minor <= 0 then
    raise exception 'The selected Session is free; payment is not required.'
      using errcode = 'P4504';
  end if;

  if new.expected_amount_minor::bigint <> selected_session.entry_fee_minor
    or new.currency <> selected_session.fee_currency then
    raise exception 'Payment amount and currency must equal the authoritative selected Session price.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger tournament_registration_payments_00_validate_initial_session
before insert or update of registration_id, tournament_id, team_id, session_id,
  expected_amount_minor, currency
on public.tournament_registration_payments
for each row execute function public.levelledup_validate_initial_session_payment();

-- The caller supplies only registration and manual reference. Session, amount,
-- currency and receiving destination are all derived inside trusted database code.
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
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
  created_payment public.tournament_registration_payments;
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

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = registration.initial_session_id
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
    raise exception 'Select an exact Stage 1 Session before submitting payment.'
      using errcode = 'P4420';
  end if;

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Payment requires a future selected Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  if selected_session.entry_fee_minor = 0 then
    raise exception 'The selected Session is free; payment is not required.'
      using errcode = 'P4504';
  end if;

  if selected_session.entry_fee_minor > 2147483647 then
    raise exception 'The selected Session fee exceeds the existing payment amount range.'
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

  insert into public.tournament_registration_payments (
    registration_id, tournament_id, team_id, session_id,
    payment_method, status, expected_amount_minor, currency,
    reference_id, submitted_by
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    selected_session.id, 'manual', 'pending',
    selected_session.entry_fee_minor::integer, selected_session.fee_currency,
    normalized_reference, authenticated_user_id
  ) returning * into created_payment;

  return created_payment;
exception
  when unique_violation then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
end;
$$;

-- Confirmation now uses the exact selected Session contract. Historical
-- registrations already confirmed before this migration are not re-evaluated.
create or replace function public.levelledup_require_verified_payment_for_confirmation()
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
  if new.status = 'confirmed'
    and old.status is distinct from 'confirmed' then
    select session.* into selected_session
    from public.tournament_stage_sessions as session
    where session.id = new.initial_session_id
    for share;

    select stage.* into selected_stage
    from public.tournament_stages as stage
    where stage.id = selected_session.stage_id
    for share;

    if selected_session.id is null
      or selected_session.tournament_id <> new.tournament_id
      or selected_stage.id is null
      or selected_stage.tournament_id <> new.tournament_id
      or selected_stage.stage_number <> 1
      or selected_stage.status in ('completed', 'cancelled') then
      raise exception 'Select a valid initial Stage 1 Session before approving this registration.'
        using errcode = 'P4420';
    end if;

    if selected_session.status not in ('planned', 'open')
      or (selected_session.scheduled_start_at is not null
        and selected_session.scheduled_start_at <= now()) then
      raise exception 'The selected initial Session no longer permits a future entry.'
        using errcode = 'P4421';
    end if;

    if selected_session.entry_fee_minor > 0
      and not exists (
        select 1
        from public.tournament_registration_payments as payment
        where payment.registration_id = new.id
          and payment.tournament_id = new.tournament_id
          and payment.team_id = new.team_id
          and payment.session_id = selected_session.id
          and payment.status = 'verified'
          and payment.expected_amount_minor::bigint = selected_session.entry_fee_minor
          and payment.currency = selected_session.fee_currency
      ) then
      raise exception 'Verify the exact selected Session payment before approving this registration.'
        using errcode = 'P4508';
    end if;
  end if;

  return new;
end;
$$;

-- Exact Session allocations must be backed by the payment for that same
-- Session. Legacy allocation rows are preserved because this validates future
-- inserts/updates only.
create or replace function public.levelledup_admin_create_stage_paid_entry(
  p_registration_id uuid,
  p_stage_id uuid,
  p_entry_scope text,
  p_source_payment_id uuid,
  p_session_id uuid default null,
  p_lobby_id uuid default null
)
returns public.tournament_registration_paid_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  selected_stage public.tournament_stages;
  selected_session public.tournament_stage_sessions;
  source_payment public.tournament_registration_payments;
  existing_entry public.tournament_registration_paid_entries;
  created_entry public.tournament_registration_paid_entries;
  scope text := lower(btrim(coalesce(p_entry_scope, '')));
  required_amount bigint;
  required_currency text;
  allocated_amount bigint;
begin
  perform public.levelledup_require_admin('admin');

  if scope not in ('stage', 'session')
    or (scope = 'stage' and (p_session_id is not null or p_lobby_id is not null))
    or (scope = 'session' and p_session_id is null) then
    raise exception 'Select a Stage scope or an exact Session scope.'
      using errcode = '22023';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = p_stage_id
  for share;

  select payment.* into source_payment
  from public.tournament_registration_payments as payment
  where payment.id = p_source_payment_id
  for update;

  if registration.id is null or selected_stage.id is null
    or selected_stage.tournament_id <> registration.tournament_id then
    raise exception 'Registration and Stage must belong to the same Tournament.'
      using errcode = '23503';
  end if;

  if source_payment.id is null or source_payment.status <> 'verified'
    or source_payment.registration_id <> registration.id
    or source_payment.tournament_id <> registration.tournament_id
    or source_payment.team_id <> registration.team_id then
    raise exception 'Paid entry requires the matching verified source payment.'
      using errcode = '22023';
  end if;

  if scope = 'session' then
    select session.* into selected_session
    from public.tournament_stage_sessions as session
    where session.id = p_session_id
    for update;

    if selected_session.id is null
      or selected_session.stage_id <> selected_stage.id
      or selected_session.tournament_id <> registration.tournament_id then
      raise exception 'Paid Session must belong to the selected Stage and Tournament.'
        using errcode = '23503';
    end if;

    if selected_session.status not in ('planned', 'open') then
      raise exception 'Paid allocation requires a future permitted Session.'
        using errcode = '22023';
    end if;

    if source_payment.session_id is distinct from selected_session.id then
      raise exception 'A Session-bound payment can fund only its exact Session.'
        using errcode = '22023';
    end if;

    if p_lobby_id is not null and not exists (
      select 1
      from public.tournament_lobbies as lobby
      where lobby.id = p_lobby_id
        and lobby.session_id = selected_session.id
        and lobby.stage_id = selected_stage.id
        and lobby.tournament_id = registration.tournament_id
    ) then
      raise exception 'Paid-entry Lobby must belong to the selected Session.'
        using errcode = '23503';
    end if;

    required_amount := selected_session.entry_fee_minor;
    required_currency := selected_session.fee_currency;
  else
    if source_payment.session_id is not null then
      raise exception 'A Session-bound payment cannot fund a Stage-wide paid entry.'
        using errcode = '22023';
    end if;

    required_amount := selected_stage.stage_fee_minor;
    required_currency := selected_stage.fee_currency;
  end if;

  if required_amount is null or required_currency is null then
    raise exception 'The selected participation scope has incomplete fee configuration.'
      using errcode = '22023';
  end if;

  if required_amount <= 0 then
    raise exception 'A paid entry requires a positive authoritative fee.'
      using errcode = '22023';
  end if;

  if required_amount > 2147483647 then
    raise exception 'The authoritative fee exceeds the existing payment allocation range.'
      using errcode = '22003';
  end if;

  if source_payment.currency <> required_currency
    or (
      scope = 'session'
      and source_payment.expected_amount_minor::bigint <> required_amount
    ) then
    raise exception 'Source payment must satisfy the authoritative participation price and currency.'
      using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('financial-stage:' || selected_stage.id::text, 0)
  );
  if scope = 'session' then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('financial-session:' || selected_session.id::text, 0)
    );
  end if;

  if scope = 'session' then
    select paid_entry.* into existing_entry
    from public.tournament_registration_paid_entries as paid_entry
    where paid_entry.registration_id = registration.id
      and paid_entry.session_id = selected_session.id
      and paid_entry.entry_scope = 'session'
      and not paid_entry.is_legacy_session_proxy;
  else
    select paid_entry.* into existing_entry
    from public.tournament_registration_paid_entries as paid_entry
    where paid_entry.registration_id = registration.id
      and paid_entry.stage_id = selected_stage.id
      and paid_entry.entry_scope = 'stage';
  end if;

  if existing_entry.id is not null then
    if existing_entry.source_payment_id = source_payment.id
      and existing_entry.amount_minor::bigint = required_amount
      and existing_entry.currency = required_currency then
      return existing_entry;
    end if;

    raise exception 'This registration already has preserved paid history for the selected scope.'
      using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.tournament_matches as match
    join public.tournament_lobbies as lobby on lobby.id = match.lobby_id
    where match.stage_id = selected_stage.id
      and (scope = 'stage' or lobby.session_id = selected_session.id)
      and match.status in ('live', 'completed')
  ) then
    raise exception 'A paid entry cannot be added after its Stage or Session has begun.'
      using errcode = '22023';
  end if;

  select coalesce(sum(paid_entry.amount_minor), 0)::bigint into allocated_amount
  from public.tournament_registration_paid_entries as paid_entry
  where paid_entry.source_payment_id = source_payment.id;

  if source_payment.expected_amount_minor::bigint - allocated_amount < required_amount then
    raise exception 'Verified source payment has insufficient unallocated value for the exact authoritative fee.'
      using errcode = '22023';
  end if;

  insert into public.tournament_registration_paid_entries (
    registration_id, tournament_id, team_id, stage_id, session_id, lobby_id,
    entry_scope, source_payment_id, amount_minor, currency, created_by
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    selected_stage.id, selected_session.id, p_lobby_id, scope, source_payment.id,
    required_amount::integer, required_currency, auth.uid()
  ) returning * into created_entry;

  return created_entry;
end;
$$;

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

    if new.amount_minor::bigint <> selected_session.entry_fee_minor
      or new.currency <> selected_session.fee_currency then
      raise exception 'A Session paid entry must equal its authoritative Session fee and currency.'
        using errcode = '22023';
    end if;

    if source_payment.session_id is distinct from selected_session.id
      or source_payment.expected_amount_minor::bigint <> selected_session.entry_fee_minor
      or source_payment.currency <> selected_session.fee_currency then
      raise exception 'A new Session allocation requires the exact authoritative payment for that same Session.'
        using errcode = '22023';
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

-- Selecting a refund path is permanent financial routing. Serialize both
-- legacy tournament credits and Stage/Session refund cases by source payment
-- so concurrent trusted writers cannot create both entitlements.
create or replace function public.levelledup_validate_refund_session_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  paid_entry public.tournament_registration_paid_entries;
begin
  select entry.* into paid_entry
  from public.tournament_registration_paid_entries as entry
  where entry.id = new.paid_entry_id;

  if paid_entry.id is null then
    raise exception 'Refund case paid entry not found.' using errcode = '23503';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'credit-source-payment:' || paid_entry.source_payment_id::text,
      0
    )
  );

  if exists (
    select 1
    from public.tournament_team_credits as legacy_credit
    where legacy_credit.source_payment_id = paid_entry.source_payment_id
  ) then
    raise exception 'This payment already uses the legacy tournament cancellation credit path.'
      using errcode = '23505';
  end if;

  if new.session_id is null then
    new.session_id := paid_entry.session_id;
  end if;

  if new.registration_id <> paid_entry.registration_id
    or new.tournament_id <> paid_entry.tournament_id
    or new.team_id <> paid_entry.team_id
    or new.stage_id <> paid_entry.stage_id
    or new.session_id is distinct from paid_entry.session_id
    or new.lobby_id is distinct from paid_entry.lobby_id
    or new.source_payment_id <> paid_entry.source_payment_id
    or new.amount_minor <> paid_entry.amount_minor
    or new.currency <> paid_entry.currency then
    raise exception 'Refund case must preserve the exact paid-entry Tournament, Stage and Session identity.'
      using errcode = '23503';
  end if;

  return new;
end;
$$;

create or replace function public.levelledup_validate_credit_session_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  paid_entry public.tournament_registration_paid_entries;
  refund_case public.tournament_stage_refund_cases;
begin
  select entry.* into paid_entry
  from public.tournament_registration_paid_entries as entry
  where entry.id = new.paid_entry_id;

  select current_case.* into refund_case
  from public.tournament_stage_refund_cases as current_case
  where current_case.id = new.refund_case_id;

  if paid_entry.id is null or refund_case.id is null then
    raise exception 'Stage credit requires its paid entry and refund case.'
      using errcode = '23503';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'credit-source-payment:' || paid_entry.source_payment_id::text,
      0
    )
  );

  if exists (
    select 1
    from public.tournament_team_credits as legacy_credit
    where legacy_credit.source_payment_id = paid_entry.source_payment_id
  ) then
    raise exception 'This payment already uses the legacy tournament cancellation credit path.'
      using errcode = '23505';
  end if;

  if new.stage_id is null then
    new.stage_id := paid_entry.stage_id;
  end if;
  if new.session_id is null then
    new.session_id := paid_entry.session_id;
  end if;

  if refund_case.paid_entry_id <> paid_entry.id
    or new.registration_id <> paid_entry.registration_id
    or new.tournament_id <> paid_entry.tournament_id
    or new.team_id <> paid_entry.team_id
    or new.stage_id <> paid_entry.stage_id
    or new.session_id is distinct from paid_entry.session_id
    or refund_case.session_id is distinct from paid_entry.session_id
    or new.source_payment_id <> paid_entry.source_payment_id
    or new.amount_minor <> paid_entry.amount_minor
    or new.currency <> paid_entry.currency then
    raise exception 'Stage credit must preserve the exact refund and paid-entry Session identity.'
      using errcode = '23503';
  end if;

  return new;
end;
$$;

create or replace function public.levelledup_guard_tournament_team_credit_history()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  source_payment public.tournament_registration_payments;
  source_tournament public.tournaments;
begin
  if tg_op = 'DELETE' then
    raise exception 'Tournament credit history cannot be deleted.'
      using errcode = 'P4514';
  end if;

  if tg_op = 'UPDATE' then
    if new.tournament_id is distinct from old.tournament_id
      or new.registration_id is distinct from old.registration_id
      or new.team_id is distinct from old.team_id
      or new.source_payment_id is distinct from old.source_payment_id
      or new.source_reference_id is distinct from old.source_reference_id
      or new.amount_minor is distinct from old.amount_minor
      or new.currency is distinct from old.currency
      or new.created_by is distinct from old.created_by
      or new.created_at is distinct from old.created_at then
      raise exception 'Tournament credit source and value are immutable.'
        using errcode = 'P4514';
    end if;

    if new.status is distinct from old.status and not (
      old.status = 'available' and new.status in ('used', 'refunded')
    ) then
      raise exception 'Invalid tournament credit status transition.'
        using errcode = 'P4515';
    end if;

    return new;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'credit-source-payment:' || new.source_payment_id::text,
      0
    )
  );

  select payment.* into source_payment
  from public.tournament_registration_payments as payment
  where payment.id = new.source_payment_id
  for share;

  select tournament.* into source_tournament
  from public.tournaments as tournament
  where tournament.id = new.tournament_id
  for share;

  if source_payment.id is null
    or source_payment.status <> 'verified'
    or source_payment.session_id is not null
    or source_payment.registration_id <> new.registration_id
    or source_payment.tournament_id <> new.tournament_id
    or source_payment.team_id <> new.team_id
    or source_payment.reference_id <> new.source_reference_id then
    raise exception 'Legacy tournament credit requires its matching verified payment with no Session identity.'
      using errcode = 'P4516';
  end if;

  if exists (
    select 1
    from public.tournament_stage_refund_cases as refund_case
    where refund_case.source_payment_id = source_payment.id
      and refund_case.status <> 'rejected'
  ) or exists (
    select 1
    from public.tournament_stage_credit_entitlements as stage_credit
    where stage_credit.source_payment_id = source_payment.id
  ) then
    raise exception 'This payment already uses the Stage/Session refund-credit path.'
      using errcode = '23505';
  end if;

  if source_tournament.id is null
    or source_tournament.status <> 'cancelled'
    or source_tournament.entry_fee_minor <= 0
    or source_tournament.entry_fee_minor <> new.amount_minor
    or source_tournament.currency <> new.currency then
    raise exception 'Tournament credit must match the cancelled tournament entry fee.'
      using errcode = 'P4516';
  end if;

  return new;
end;
$$;

-- Releasing an existing assignment is a historical close operation, not a new
-- eligibility decision. Permit only the pure assigned -> released transition;
-- all assignment creation/movement checks remain unchanged.
create or replace function public.levelledup_guard_stage_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_lobby public.tournament_lobbies;
  selected_registration public.tournament_registrations;
begin
  if tg_op = 'UPDATE'
    and old.status = 'assigned'
    and new.status = 'released'
    and new.tournament_id = old.tournament_id
    and new.stage_id = old.stage_id
    and new.lobby_id = old.lobby_id
    and new.registration_id = old.registration_id
    and new.slot_number = old.slot_number
    and new.session_id = old.session_id
    and new.session_entry_id = old.session_entry_id
    and new.assigned_at = old.assigned_at
    and new.assigned_by is not distinct from old.assigned_by
    and new.created_at = old.created_at then
    return new;
  end if;

  select lobby.* into selected_lobby
  from public.tournament_lobbies as lobby
  where lobby.id = new.lobby_id
  for update;

  if selected_lobby.id is null
    or selected_lobby.tournament_id <> new.tournament_id
    or selected_lobby.stage_id <> new.stage_id then
    raise exception 'Lobby assignment scope is invalid.' using errcode = 'P4410';
  end if;

  if selected_lobby.status not in ('planned', 'open') then
    raise exception 'The selected lobby is not accepting assignments.'
      using errcode = 'P4411';
  end if;

  if new.slot_number < 1 or new.slot_number > selected_lobby.capacity then
    raise exception 'Slot must be between 1 and % for %.',
      selected_lobby.capacity,
      selected_lobby.display_label
      using errcode = 'P4412';
  end if;

  select registration.* into selected_registration
  from public.tournament_registrations as registration
  where registration.id = new.registration_id
  for update;

  if selected_registration.id is null
    or selected_registration.tournament_id <> new.tournament_id
    or selected_registration.status not in ('pending', 'confirmed')
    or selected_registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Only an eligible finalized registration can receive an assignment.'
      using errcode = 'P4413';
  end if;

  return new;
end;
$$;

-- Preserve historical Squad snapshots. Eligibility for this Session-level
-- participation identity depends on the active team and locked/finalized
-- registration, not on every snapshotted player's current live-team status.
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
  earned_entry public.tournament_session_entries;
  credit_debit public.levelledup_credit_ledger_entries;
begin
  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = new.registration_id;

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = new.session_id;

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

    if paid_entry.id is null
      or paid_entry.entry_scope <> 'session'
      or paid_entry.status <> 'paid'
      or paid_entry.registration_id <> new.registration_id
      or paid_entry.team_id <> new.team_id
      or paid_entry.tournament_id <> new.tournament_id
      or paid_entry.stage_id <> new.stage_id
      or paid_entry.session_id <> new.session_id
      or paid_entry.amount_minor::bigint <> selected_session.entry_fee_minor
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
    if registration.initial_session_id is distinct from new.session_id
      or selected_stage.stage_number <> 1
      or selected_session.entry_fee_minor <> 0
      or new.source_provenance ->> 'entitlement'
        is distinct from 'initial_registration_confirmation' then
      raise exception 'Registration Session Entry requires the confirmed zero-fee initial Stage 1 Session entitlement.'
        using errcode = '22023';
    end if;
    new.source_occurred_at := coalesce(registration.confirmed_at, now());
  else
    new.source_occurred_at := coalesce(new.source_occurred_at, now());
  end if;

  return new;
end;
$$;

-- Trusted lifecycle workflows use this internal helper to release routing and
-- cancel only unused paid or zero-fee registration participation. It is never
-- granted to browser roles and deliberately raises instead of erasing consumed
-- participation history.
create function public.levelledup_cancel_unused_registration_session_entries(
  p_registration_id uuid,
  p_actor_user_id uuid,
  p_reason text
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  session_entry public.tournament_session_entries;
  source_paid_entry public.tournament_registration_paid_entries;
  cancelled_count integer := 0;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  decision_at timestamptz := clock_timestamp();
begin
  if p_actor_user_id is null then
    raise exception 'A trusted Session Entry cancellation actor is required.'
      using errcode = '42501';
  end if;

  if char_length(normalized_reason) not between 10 and 500 then
    raise exception 'Provide a Session Entry cancellation reason between 10 and 500 characters.'
      using errcode = '22023';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4013';
  end if;

  for session_entry in
    select entry.*
    from public.tournament_session_entries as entry
    where entry.registration_id = registration.id
      and entry.status = 'active'
      and entry.source_type in ('paid', 'registration')
    order by entry.created_at, entry.id
    for update
  loop
    source_paid_entry := null;

    if session_entry.source_type = 'paid' then
      select paid_entry.* into source_paid_entry
      from public.tournament_registration_paid_entries as paid_entry
      where paid_entry.id = session_entry.source_paid_entry_id
      for update;

      if source_paid_entry.id is null
        or source_paid_entry.registration_id <> registration.id
        or source_paid_entry.session_id <> session_entry.session_id then
        raise exception 'Paid Session Entry source history is inconsistent.'
          using errcode = '23503';
      end if;

      if source_paid_entry.status <> 'paid' then
        raise exception 'Consumed or already-processed Session participation cannot be cancelled by this lifecycle workflow.'
          using errcode = '22023';
      end if;
    elsif session_entry.source_provenance ->> 'entitlement'
      is distinct from 'initial_registration_confirmation' then
      raise exception 'Only the preserved initial zero-fee registration entitlement can be lifecycle-cancelled.'
        using errcode = '22023';
    end if;

    if exists (
      select 1
      from public.tournament_stage_assignments as assignment
      join public.tournament_matches as match
        on match.lobby_id = assignment.lobby_id
       and match.stage_id = assignment.stage_id
       and match.tournament_id = assignment.tournament_id
      where assignment.session_entry_id = session_entry.id
        and match.status in ('live', 'completed')
    ) then
      raise exception 'Consumed Session participation cannot be cancelled or refunded.'
        using errcode = '22023';
    end if;

    update public.tournament_stage_assignments
    set status = 'released', released_at = decision_at
    where session_entry_id = session_entry.id
      and status = 'assigned';

    update public.tournament_session_entries
    set
      status = 'cancelled',
      cancelled_by = p_actor_user_id,
      cancelled_at = decision_at,
      cancellation_reason = normalized_reason,
      cancellation_request_id = gen_random_uuid()
    where id = session_entry.id;

    cancelled_count := cancelled_count + 1;
  end loop;

  return cancelled_count;
end;
$$;

-- Internal financial primitive shared by withdrawal/disband and whole-
-- tournament cancellation. The caller decides whether to include all paid
-- history or only the new Session-bound payment path.
create function public.levelledup_credit_unused_registration_paid_entries(
  p_registration_id uuid,
  p_actor_user_id uuid,
  p_reason text,
  p_session_bound_only boolean
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  paid_entry public.tournament_registration_paid_entries;
  source_payment public.tournament_registration_payments;
  refund_case public.tournament_stage_refund_cases;
  credited_count integer := 0;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  decision_at timestamptz := clock_timestamp();
begin
  if p_actor_user_id is null then
    raise exception 'A trusted credit actor is required.' using errcode = '42501';
  end if;

  if char_length(normalized_reason) not between 3 and 500 then
    raise exception 'Provide a credit reason between 3 and 500 characters.'
      using errcode = '22023';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4013';
  end if;

  for paid_entry in
    select entry.*
    from public.tournament_registration_paid_entries as entry
    join public.tournament_registration_payments as payment
      on payment.id = entry.source_payment_id
    where entry.registration_id = registration.id
      and entry.status in ('paid', 'refund_pending')
      and (not p_session_bound_only or payment.session_id is not null)
    order by entry.created_at, entry.id
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('financial-stage:' || paid_entry.stage_id::text, 0)
    );
    if paid_entry.entry_scope = 'session' then
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('financial-session:' || paid_entry.session_id::text, 0)
      );
    end if;

    select entry.* into paid_entry
    from public.tournament_registration_paid_entries as entry
    where entry.id = paid_entry.id
    for update;

    if paid_entry.status not in ('paid', 'refund_pending') then
      continue;
    end if;

    select payment.* into source_payment
    from public.tournament_registration_payments as payment
    where payment.id = paid_entry.source_payment_id
    for share;

    if source_payment.id is null
      or source_payment.status <> 'verified'
      or source_payment.registration_id <> paid_entry.registration_id
      or source_payment.tournament_id <> paid_entry.tournament_id
      or source_payment.team_id <> paid_entry.team_id then
      raise exception 'Unused paid entry has invalid source-payment history.'
        using errcode = '23503';
    end if;

    if p_session_bound_only and (
      source_payment.session_id is null
      or paid_entry.entry_scope <> 'session'
      or paid_entry.session_id is distinct from source_payment.session_id
    ) then
      raise exception 'Tournament cancellation Session credit requires the exact Session-bound paid allocation.'
        using errcode = '23503';
    end if;

    if exists (
      select 1
      from public.tournament_matches as match
      join public.tournament_lobbies as lobby on lobby.id = match.lobby_id
      where match.stage_id = paid_entry.stage_id
        and (
          paid_entry.entry_scope = 'stage'
          or lobby.session_id = paid_entry.session_id
        )
        and match.status in ('live', 'completed')
    ) then
      continue;
    end if;

    if exists (
      select 1
      from public.tournament_session_entries as entry
      where entry.source_paid_entry_id = paid_entry.id
        and entry.status = 'active'
    ) then
      raise exception 'Cancel the unused active Session Entry before processing its refund or credit.'
        using errcode = '22023';
    end if;

    if paid_entry.status = 'paid' then
      insert into public.tournament_stage_refund_cases (
        paid_entry_id, registration_id, tournament_id, team_id, stage_id,
        session_id, lobby_id, source_payment_id, amount_minor, currency,
        processing_mode, status, reason, created_by, reviewed_by, reviewed_at
      ) values (
        paid_entry.id, paid_entry.registration_id, paid_entry.tournament_id,
        paid_entry.team_id, paid_entry.stage_id, paid_entry.session_id,
        paid_entry.lobby_id, paid_entry.source_payment_id, paid_entry.amount_minor,
        paid_entry.currency, 'automatic', 'approved', normalized_reason,
        p_actor_user_id, p_actor_user_id, decision_at
      ) returning * into refund_case;

      update public.tournament_registration_paid_entries
      set status = 'refund_pending', updated_at = decision_at
      where id = paid_entry.id;
    else
      select current_case.* into refund_case
      from public.tournament_stage_refund_cases as current_case
      where current_case.paid_entry_id = paid_entry.id
        and current_case.status <> 'rejected'
      for update;

      if refund_case.id is null
        or refund_case.status not in ('pending_review', 'approved') then
        raise exception 'Unused paid entry has no creditable refund case.'
          using errcode = '22023';
      end if;

      if refund_case.status = 'pending_review' then
        update public.tournament_stage_refund_cases
        set
          status = 'approved',
          reviewed_by = p_actor_user_id,
          reviewed_at = decision_at,
          updated_at = decision_at
        where id = refund_case.id
        returning * into refund_case;
      end if;
    end if;

    insert into public.tournament_stage_credit_entitlements (
      refund_case_id, paid_entry_id, registration_id, tournament_id, team_id,
      stage_id, session_id, source_payment_id, amount_minor, currency,
      created_by, status_updated_by, status_updated_at, created_at, updated_at
    ) values (
      refund_case.id, paid_entry.id, paid_entry.registration_id,
      paid_entry.tournament_id, paid_entry.team_id, paid_entry.stage_id,
      paid_entry.session_id, paid_entry.source_payment_id, paid_entry.amount_minor,
      paid_entry.currency, p_actor_user_id, p_actor_user_id,
      decision_at, decision_at, decision_at
    );

    update public.tournament_registration_paid_entries
    set status = 'credited', updated_at = decision_at
    where id = paid_entry.id;

    update public.tournament_stage_refund_cases
    set
      status = 'credited',
      credit_issued_at = decision_at,
      updated_at = decision_at
    where id = refund_case.id;

    credited_count := credited_count + 1;
  end loop;

  return credited_count;
end;
$$;

create or replace function public.levelledup_credit_unused_entries_before_registration_close(
  p_registration_id uuid,
  p_actor_user_id uuid,
  p_reason text
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  tournament public.tournaments;
begin
  if p_actor_user_id is null then
    raise exception 'A trusted credit actor is required.' using errcode = '42501';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4013';
  end if;

  select current_tournament.* into tournament
  from public.tournaments as current_tournament
  where current_tournament.id = registration.tournament_id
  for share;

  if tournament.id is null
    or clock_timestamp() >= tournament.registration_closes_at then
    return 0;
  end if;

  perform public.levelledup_cancel_unused_registration_session_entries(
    registration.id,
    p_actor_user_id,
    p_reason
  );

  return public.levelledup_credit_unused_registration_paid_entries(
    registration.id,
    p_actor_user_id,
    p_reason,
    false
  );
end;
$$;

create or replace function public.levelledup_admin_cancel_tournament_with_credits(
  p_tournament_id uuid
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_admin_id uuid := auth.uid();
  selected_tournament public.tournaments;
  registration record;
  session_payment record;
begin
  perform public.levelledup_require_admin('admin');

  select tournament.* into selected_tournament
  from public.tournaments as tournament
  where tournament.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.' using errcode = 'P4301';
  end if;

  if selected_tournament.status not in (
    'draft', 'registration_open', 'registration_closed'
  ) then
    raise exception 'Only a tournament that has not begun can be cancelled.'
      using errcode = 'P4303';
  end if;

  if selected_tournament.archived_at is not null then
    raise exception 'An archived tournament cannot be cancelled again.'
      using errcode = 'P4303';
  end if;

  if exists (
    select 1
    from public.tournament_matches as match
    where match.tournament_id = selected_tournament.id
      and match.status in ('live', 'completed')
  ) or exists (
    select 1
    from public.match_results as result
    where result.tournament_id = selected_tournament.id
  ) then
    raise exception 'This tournament has begun and must remain historical.'
      using errcode = 'P4303';
  end if;

  perform 1
  from public.tournament_registrations as current_registration
  where current_registration.tournament_id = selected_tournament.id
  for update;

  perform 1
  from public.tournament_registration_payments as payment
  where payment.tournament_id = selected_tournament.id
  for update;

  -- A verified Session payment that was not yet approved still represents
  -- preserved value. Materialize its exact allocation solely so the existing
  -- Stage/Session refund-credit path can own the cancellation entitlement.
  for session_payment in
    select
      payment.id as payment_id,
      payment.registration_id,
      session.stage_id,
      session.id as session_id
    from public.tournament_registration_payments as payment
    join public.tournament_registrations as current_registration
      on current_registration.id = payment.registration_id
     and current_registration.tournament_id = payment.tournament_id
     and current_registration.team_id = payment.team_id
    join public.tournament_stage_sessions as session
      on session.id = payment.session_id
     and session.tournament_id = payment.tournament_id
    where payment.tournament_id = selected_tournament.id
      and payment.status = 'verified'
      and payment.session_id is not null
    order by payment.submitted_at, payment.id
  loop
    perform public.levelledup_admin_create_stage_paid_entry(
      session_payment.registration_id,
      session_payment.stage_id,
      'session',
      session_payment.payment_id,
      session_payment.session_id,
      null
    );
  end loop;

  for registration in
    select current_registration.id
    from public.tournament_registrations as current_registration
    where current_registration.tournament_id = selected_tournament.id
    order by current_registration.created_at, current_registration.id
  loop
    perform public.levelledup_cancel_unused_registration_session_entries(
      registration.id,
      authenticated_admin_id,
      'Tournament cancelled before competition; unused Session participation cancelled'
    );

    perform public.levelledup_credit_unused_registration_paid_entries(
      registration.id,
      authenticated_admin_id,
      'Tournament cancelled before competition; unused Session payment credited',
      true
    );
  end loop;

  update public.tournaments
  set status = 'cancelled'
  where id = selected_tournament.id
  returning * into selected_tournament;

  -- Only payments that predate exact Session identity retain the legacy whole-
  -- tournament credit path. The insertion trigger rejects any competing
  -- Stage/Session refund route for the same source payment.
  insert into public.tournament_team_credits (
    tournament_id, registration_id, team_id, source_payment_id,
    source_reference_id, amount_minor, currency, status,
    created_by, status_updated_by
  )
  select
    selected_tournament.id,
    current_registration.id,
    current_registration.team_id,
    payment.id,
    payment.reference_id,
    selected_tournament.entry_fee_minor,
    selected_tournament.currency,
    'available',
    authenticated_admin_id,
    authenticated_admin_id
  from public.tournament_registrations as current_registration
  join public.tournament_registration_payments as payment
    on payment.registration_id = current_registration.id
   and payment.tournament_id = current_registration.tournament_id
   and payment.team_id = current_registration.team_id
   and payment.status = 'verified'
   and payment.session_id is null
  where current_registration.tournament_id = selected_tournament.id
    and selected_tournament.entry_fee_minor > 0
  on conflict (registration_id) do nothing;

  return selected_tournament;
end;
$$;

create or replace function public.levelledup_admin_reconcile_cancelled_tournament_payment(
  p_payment_id uuid,
  p_decision text
)
returns public.tournament_registration_payments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_admin_id uuid := auth.uid();
  normalized_decision text := lower(btrim(coalesce(p_decision, '')));
  selected_payment public.tournament_registration_payments;
  selected_tournament public.tournaments;
  selected_registration public.tournament_registrations;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
  existing_legacy_credit public.tournament_team_credits;
  existing_session_credit public.tournament_stage_credit_entitlements;
begin
  perform public.levelledup_require_admin('admin');

  if normalized_decision not in ('confirm', 'reject') then
    raise exception 'Unsupported cancelled-payment reconciliation decision.'
      using errcode = 'P4518';
  end if;

  select payment.* into selected_payment
  from public.tournament_registration_payments as payment
  where payment.id = p_payment_id
  for update;

  if selected_payment.id is null
    or selected_payment.payment_method <> 'manual' then
    raise exception 'Cancelled tournament payment submission not found.'
      using errcode = 'P4507';
  end if;

  select tournament.* into selected_tournament
  from public.tournaments as tournament
  where tournament.id = selected_payment.tournament_id
  for update;

  if selected_tournament.id is null
    or selected_tournament.status <> 'cancelled' then
    raise exception 'This action is only available for a cancelled tournament.'
      using errcode = 'P4518';
  end if;

  if selected_payment.status = 'rejected' then
    if normalized_decision = 'reject' then
      return selected_payment;
    end if;
    raise exception 'A rejected payment cannot later be confirmed.'
      using errcode = 'P4518';
  end if;

  if selected_payment.status = 'verified' then
    if selected_payment.session_id is null then
      select credit.* into existing_legacy_credit
      from public.tournament_team_credits as credit
      where credit.registration_id = selected_payment.registration_id
      for share;

      if normalized_decision = 'confirm'
        and selected_payment.cancelled_reconciled_at is not null
        and existing_legacy_credit.id is not null
        and existing_legacy_credit.source_payment_id = selected_payment.id
        and existing_legacy_credit.amount_minor = selected_payment.expected_amount_minor
        and existing_legacy_credit.currency = selected_payment.currency then
        return selected_payment;
      end if;
    else
      select credit.* into existing_session_credit
      from public.tournament_stage_credit_entitlements as credit
      where credit.source_payment_id = selected_payment.id
      order by credit.created_at, credit.id
      limit 1
      for share;

      if normalized_decision = 'confirm'
        and selected_payment.cancelled_reconciled_at is not null
        and existing_session_credit.id is not null
        and existing_session_credit.amount_minor = selected_payment.expected_amount_minor
        and existing_session_credit.currency = selected_payment.currency then
        return selected_payment;
      end if;
    end if;

    raise exception 'This payment has already been reviewed through another workflow.'
      using errcode = 'P4518';
  end if;

  if selected_payment.status <> 'pending' then
    raise exception 'Only a preserved pending payment can be reconciled.'
      using errcode = 'P4518';
  end if;

  if normalized_decision = 'reject' then
    update public.tournament_registration_payments
    set
      status = 'rejected',
      verification_source = 'admin',
      reviewed_by = authenticated_admin_id,
      reviewed_at = now()
    where id = selected_payment.id
    returning * into selected_payment;

    return selected_payment;
  end if;

  if selected_payment.session_id is null then
    if selected_tournament.entry_fee_minor <= 0
      or selected_payment.expected_amount_minor <> selected_tournament.entry_fee_minor
      or selected_payment.currency <> selected_tournament.currency then
      raise exception 'The preserved legacy payment does not match the cancelled tournament entry fee.'
        using errcode = 'P4519';
    end if;
  else
    select current_registration.* into selected_registration
    from public.tournament_registrations as current_registration
    where current_registration.id = selected_payment.registration_id
    for update;

    select session.* into selected_session
    from public.tournament_stage_sessions as session
    where session.id = selected_payment.session_id
    for share;

    select stage.* into selected_stage
    from public.tournament_stages as stage
    where stage.id = selected_session.stage_id
    for share;

    if selected_registration.id is null
      or selected_registration.tournament_id <> selected_payment.tournament_id
      or selected_registration.team_id <> selected_payment.team_id
      or selected_registration.initial_session_id is distinct from selected_payment.session_id
      or selected_session.id is null
      or selected_session.tournament_id <> selected_payment.tournament_id
      or selected_stage.id is null
      or selected_stage.tournament_id <> selected_payment.tournament_id
      or selected_stage.stage_number <> 1
      or selected_payment.expected_amount_minor::bigint <> selected_session.entry_fee_minor
      or selected_payment.currency <> selected_session.fee_currency then
      raise exception 'The preserved payment does not match its exact Stage 1 Session identity and price.'
        using errcode = 'P4519';
    end if;
  end if;

  update public.tournament_registration_payments
  set
    status = 'verified',
    verification_source = 'admin',
    reviewed_by = authenticated_admin_id,
    reviewed_at = now(),
    cancelled_reconciled_at = now(),
    cancelled_reconciled_by = authenticated_admin_id
  where id = selected_payment.id
  returning * into selected_payment;

  if selected_payment.session_id is null then
    insert into public.tournament_team_credits (
      tournament_id, registration_id, team_id, source_payment_id,
      source_reference_id, amount_minor, currency, status,
      created_by, status_updated_by
    ) values (
      selected_payment.tournament_id,
      selected_payment.registration_id,
      selected_payment.team_id,
      selected_payment.id,
      selected_payment.reference_id,
      selected_payment.expected_amount_minor,
      selected_payment.currency,
      'available',
      authenticated_admin_id,
      authenticated_admin_id
    )
    on conflict (registration_id) do nothing;

    select credit.* into existing_legacy_credit
    from public.tournament_team_credits as credit
    where credit.registration_id = selected_payment.registration_id
    for share;

    if existing_legacy_credit.id is null
      or existing_legacy_credit.source_payment_id <> selected_payment.id
      or existing_legacy_credit.amount_minor <> selected_payment.expected_amount_minor
      or existing_legacy_credit.currency <> selected_payment.currency
      or existing_legacy_credit.source_reference_id <> selected_payment.reference_id then
      raise exception 'A conflicting cancellation credit already exists for this registration.'
        using errcode = 'P4519';
    end if;
  else
    perform public.levelledup_admin_create_stage_paid_entry(
      selected_payment.registration_id,
      selected_stage.id,
      'session',
      selected_payment.id,
      selected_session.id,
      null
    );

    perform public.levelledup_cancel_unused_registration_session_entries(
      selected_payment.registration_id,
      authenticated_admin_id,
      'Cancelled tournament payment reconciled; unused Session participation cancelled'
    );

    perform public.levelledup_credit_unused_registration_paid_entries(
      selected_payment.registration_id,
      authenticated_admin_id,
      'Cancelled tournament payment reconciled to exact Session credit',
      true
    );

    select credit.* into existing_session_credit
    from public.tournament_stage_credit_entitlements as credit
    where credit.source_payment_id = selected_payment.id
      and credit.session_id = selected_payment.session_id
      and credit.amount_minor = selected_payment.expected_amount_minor
      and credit.currency = selected_payment.currency
    order by credit.created_at, credit.id
    limit 1
    for share;

    if existing_session_credit.id is null then
      raise exception 'Session-bound cancellation credit creation failed.'
        using errcode = 'P4519';
    end if;
  end if;

  return selected_payment;
end;
$$;

-- Registration confirmation, financial allocation and first Session Entry are
-- one transaction because they execute within this single PostgreSQL function.
create or replace function public.levelledup_admin_review_tournament_registration(
  p_registration_id uuid,
  p_decision text
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
  paid_allocation public.tournament_registration_paid_entries;
  existing_entry public.tournament_session_entries;
  created_entry public.tournament_session_entries;
  confirmed_count integer;
  actor_role text;
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
    if registration.initial_session_id is not null and exists (
      select 1 from public.tournament_session_entries as session_entry
      where session_entry.registration_id = registration.id
        and session_entry.session_id = registration.initial_session_id
    ) then
      return registration;
    end if;

    raise exception 'Confirmed registration is missing its preserved initial Session Entry; manual investigation is required.'
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

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = registration.initial_session_id
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

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'The selected initial Session no longer permits a future entry.'
      using errcode = 'P4421';
  end if;

  select count(*)::integer into confirmed_count
  from public.tournament_registrations as confirmed_registration
  where confirmed_registration.tournament_id = selected_tournament.id
    and confirmed_registration.status = 'confirmed';

  if confirmed_count >= selected_tournament.max_team_slots then
    raise exception 'The tournament has reached its overall team capacity.'
      using errcode = 'P4005';
  end if;

  if selected_session.entry_fee_minor > 0 then
    select payment.* into verified_payment
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.tournament_id = registration.tournament_id
      and payment.team_id = registration.team_id
      and payment.session_id = selected_session.id
      and payment.status = 'verified'
      and payment.expected_amount_minor::bigint = selected_session.entry_fee_minor
      and payment.currency = selected_session.fee_currency
    order by payment.submitted_at, payment.id
    limit 1
    for update;

    if verified_payment.id is null then
      raise exception 'Verify the exact selected Session payment before approving this registration.'
        using errcode = 'P4508';
    end if;
  end if;

  update public.tournament_registrations
  set status = 'confirmed', reviewed_by = auth.uid()
  where id = registration.id
  returning * into registration;

  actor_role := public.levelledup_current_admin_role();

  if selected_session.entry_fee_minor > 0 then
    paid_allocation := public.levelledup_admin_create_stage_paid_entry(
      registration.id,
      selected_stage.id,
      'session',
      verified_payment.id,
      selected_session.id,
      null
    );

    insert into public.tournament_session_entries (
      tournament_id, stage_id, session_id, registration_id, team_id,
      source_type, source_paid_entry_id, source_occurred_at,
      source_provenance, reason, request_id, created_by, created_by_role
    ) values (
      registration.tournament_id, selected_stage.id, selected_session.id,
      registration.id, registration.team_id, 'paid', paid_allocation.id,
      paid_allocation.created_at,
      jsonb_build_object(
        'entitlement', 'initial_registration_confirmation',
        'registration_id', registration.id,
        'session_id', selected_session.id,
        'payment_id', verified_payment.id,
        'paid_allocation_id', paid_allocation.id
      ),
      'Initial paid Session Entry created atomically with registration approval.',
      gen_random_uuid(), auth.uid(), actor_role
    ) returning * into created_entry;
  else
    insert into public.tournament_session_entries (
      tournament_id, stage_id, session_id, registration_id, team_id,
      source_type, source_occurred_at, source_provenance, reason,
      request_id, created_by, created_by_role
    ) values (
      registration.tournament_id, selected_stage.id, selected_session.id,
      registration.id, registration.team_id, 'registration',
      registration.confirmed_at,
      jsonb_build_object(
        'entitlement', 'initial_registration_confirmation',
        'registration_id', registration.id,
        'session_id', selected_session.id,
        'confirmed_by', auth.uid()
      ),
      'Initial zero-fee Session Entry created atomically with registration approval.',
      gen_random_uuid(), auth.uid(), actor_role
    ) returning * into created_entry;
  end if;

  return registration;
end;
$$;

alter function public.levelledup_validate_registration_initial_session() owner to postgres;
alter function public.levelledup_select_registration_initial_session(uuid, uuid) owner to postgres;
alter function public.levelledup_guard_session_price_change() owner to postgres;
alter function public.levelledup_keep_tournament_payment_attempt() owner to postgres;
alter function public.levelledup_validate_initial_session_payment() owner to postgres;
alter function public.levelledup_submit_manual_tournament_payment(uuid, text) owner to postgres;
alter function public.levelledup_require_verified_payment_for_confirmation() owner to postgres;
alter function public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, uuid, uuid) owner to postgres;
alter function public.levelledup_validate_paid_entry_session_scope() owner to postgres;
alter function public.levelledup_validate_refund_session_scope() owner to postgres;
alter function public.levelledup_validate_credit_session_scope() owner to postgres;
alter function public.levelledup_guard_tournament_team_credit_history() owner to postgres;
alter function public.levelledup_guard_stage_assignment() owner to postgres;
alter function public.levelledup_validate_session_entry_source() owner to postgres;
alter function public.levelledup_cancel_unused_registration_session_entries(uuid, uuid, text) owner to postgres;
alter function public.levelledup_credit_unused_registration_paid_entries(uuid, uuid, text, boolean) owner to postgres;
alter function public.levelledup_credit_unused_entries_before_registration_close(uuid, uuid, text) owner to postgres;
alter function public.levelledup_admin_cancel_tournament_with_credits(uuid) owner to postgres;
alter function public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text) owner to postgres;
alter function public.levelledup_admin_review_tournament_registration(uuid, text) owner to postgres;

revoke all on function
  public.levelledup_validate_registration_initial_session(),
  public.levelledup_select_registration_initial_session(uuid, uuid),
  public.levelledup_guard_session_price_change(),
  public.levelledup_keep_tournament_payment_attempt(),
  public.levelledup_validate_initial_session_payment(),
  public.levelledup_submit_manual_tournament_payment(uuid, text),
  public.levelledup_require_verified_payment_for_confirmation(),
  public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, uuid, uuid),
  public.levelledup_validate_paid_entry_session_scope(),
  public.levelledup_validate_refund_session_scope(),
  public.levelledup_validate_credit_session_scope(),
  public.levelledup_guard_tournament_team_credit_history(),
  public.levelledup_guard_stage_assignment(),
  public.levelledup_validate_session_entry_source(),
  public.levelledup_cancel_unused_registration_session_entries(uuid, uuid, text),
  public.levelledup_credit_unused_registration_paid_entries(uuid, uuid, text, boolean),
  public.levelledup_credit_unused_entries_before_registration_close(uuid, uuid, text),
  public.levelledup_admin_cancel_tournament_with_credits(uuid),
  public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text),
  public.levelledup_admin_review_tournament_registration(uuid, text)
  from public, anon, authenticated;

grant execute on function
  public.levelledup_select_registration_initial_session(uuid, uuid),
  public.levelledup_submit_manual_tournament_payment(uuid, text),
  public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, uuid, uuid),
  public.levelledup_admin_cancel_tournament_with_credits(uuid),
  public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text),
  public.levelledup_admin_review_tournament_registration(uuid, text)
  to authenticated;

comment on function public.levelledup_select_registration_initial_session(uuid, uuid) is
  'Captain-only selection/change of a pending registration''s exact future Stage 1 Session. Any payment, allocation or participation history permanently locks the selection.';
comment on function public.levelledup_submit_manual_tournament_payment(uuid, text) is
  'Captain-only initial manual payment submission. Session, amount and currency are derived exclusively from registration.initial_session_id and its authoritative Session price.';
comment on function public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, uuid, uuid) is
  'Admin-only authoritative paid allocation. Legacy Stage scope requires a NULL payment Session; Session scope requires the source payment''s exact Session and authoritative Session price.';
comment on function public.levelledup_admin_cancel_tournament_with_credits(uuid) is
  'Admin-only atomic pre-competition cancellation. Legacy NULL-Session payments retain tournament credits; exact Session payments use only the Stage/Session refund-credit path after unused participation is cancelled.';
comment on function public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text) is
  'Admin-only cancelled-payment reconciliation. Legacy NULL-Session payments use tournament price/credit; exact Session payments preserve Session price and use only the Stage/Session refund-credit path.';
comment on function public.levelledup_admin_review_tournament_registration(uuid, text) is
  'Admin-only atomic registration review. Approval confirms the registration and creates its exact paid allocation plus paid Session Entry, or its non-financial registration Session Entry for a zero-fee Session.';

-- Deployment assertions. These inspect contracts and privileges only; they do
-- not invent mappings for historical registrations or payments.
do $$
begin
  if to_regprocedure(
      'public.levelledup_select_registration_initial_session(uuid,uuid)'
    ) is null then
    raise exception 'Initial Session selection RPC installation failed.';
  end if;

  if not has_function_privilege(
      'authenticated',
      'public.levelledup_select_registration_initial_session(uuid,uuid)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.levelledup_select_registration_initial_session(uuid,uuid)',
      'EXECUTE'
    ) then
    raise exception 'Initial Session selection RPC grants validation failed.';
  end if;

  if has_column_privilege(
      'authenticated',
      'public.tournament_registrations',
      'initial_session_id',
      'UPDATE'
    )
    or has_table_privilege(
      'anon', 'public.tournament_registration_payments', 'INSERT'
    )
    or has_table_privilege(
      'authenticated', 'public.tournament_registration_payments', 'INSERT'
    )
    or has_table_privilege(
      'anon', 'public.tournament_registration_paid_entries', 'INSERT'
    )
    or has_table_privilege(
      'authenticated', 'public.tournament_registration_paid_entries', 'INSERT'
    )
    or has_table_privilege(
      'anon', 'public.tournament_session_entries', 'INSERT'
    )
    or has_table_privilege(
      'authenticated', 'public.tournament_session_entries', 'INSERT'
    ) then
    raise exception 'Browser direct-write denial validation failed.';
  end if;

  if has_function_privilege(
      'anon',
      'public.levelledup_submit_manual_tournament_payment(uuid,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.levelledup_admin_review_tournament_registration(uuid,text)',
      'EXECUTE'
    ) then
    raise exception 'Anonymous trusted-mutation denial validation failed.';
  end if;

  if has_function_privilege(
      'anon',
      'public.levelledup_cancel_unused_registration_session_entries(uuid,uuid,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.levelledup_cancel_unused_registration_session_entries(uuid,uuid,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.levelledup_credit_unused_registration_paid_entries(uuid,uuid,text,boolean)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.levelledup_credit_unused_registration_paid_entries(uuid,uuid,text,boolean)',
      'EXECUTE'
    ) then
    raise exception 'Internal lifecycle helper privilege validation failed.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.tournament_session_entries'::regclass
      and constraint_record.conname = 'tournament_session_entries_source_valid'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%registration%'
  ) then
    raise exception 'Registration Session Entry source constraint validation failed.';
  end if;

  if exists (
    select 1
    from public.tournament_registration_payments as payment
    join public.tournament_stage_sessions as session
      on session.id = payment.session_id
    where payment.session_id is not null
      and (
        payment.tournament_id <> session.tournament_id
        or payment.expected_amount_minor::bigint <> session.entry_fee_minor
        or payment.currency <> session.fee_currency
      )
  ) then
    raise exception 'Exact Session payment contract validation failed.';
  end if;

  if exists (
    select 1
    from public.tournament_team_credits as legacy_credit
    join public.tournament_stage_refund_cases as refund_case
      on refund_case.source_payment_id = legacy_credit.source_payment_id
    where refund_case.status <> 'rejected'
  ) then
    raise exception 'A source payment already has both legacy tournament-credit and Stage/Session refund routing; manual resolution is required.';
  end if;

  if to_regprocedure(
      'public.levelledup_submit_manual_tournament_payment(uuid,text)'
    ) is null
    or to_regprocedure(
      'public.levelledup_submit_manual_tournament_payment(uuid,text,integer,text)'
    ) is not null then
    raise exception 'Caller-independent payment pricing signature validation failed.';
  end if;

  if to_regprocedure(
      'public.levelledup_admin_create_stage_paid_entry(uuid,uuid,text,uuid,uuid,uuid)'
    ) is null then
    raise exception 'Authoritative paid-allocation signature validation failed.';
  end if;
end;
$$;

commit;
