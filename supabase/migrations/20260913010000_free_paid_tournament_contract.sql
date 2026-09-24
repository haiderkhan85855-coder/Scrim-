begin;

-- Tournament entry_fee_minor is the stable free/paid classification once a
-- tournament leaves draft. Existing participation and finance history is not
-- rewritten by this migration.
alter table public.tournament_session_entries
  drop constraint tournament_session_entries_source_valid,
  drop constraint tournament_session_entries_source_exactly_one,
  add constraint tournament_session_entries_source_valid check (
    source_type in (
      'paid', 'earned', 'credit', 'admin_grant', 'registration', 'free'
    )
  ),
  add constraint tournament_session_entries_source_exactly_one check (
    (source_type = 'paid' and source_paid_entry_id is not null
      and earned_from_session_entry_id is null
      and source_credit_ledger_entry_id is null)
    or (source_type = 'earned' and source_paid_entry_id is null
      and earned_from_session_entry_id is not null
      and source_credit_ledger_entry_id is null)
    or (source_type = 'credit' and source_paid_entry_id is null
      and earned_from_session_entry_id is null
      and source_credit_ledger_entry_id is not null)
    or (source_type in ('admin_grant', 'registration', 'free')
      and source_paid_entry_id is null
      and earned_from_session_entry_id is null
      and source_credit_ledger_entry_id is null)
  );

comment on column public.tournament_session_entries.source_type is
  'Immutable provenance category. free is the non-financial initial entitlement for a free Tournament; registration is the initial entitlement backed by a paid Tournament registration. paid remains reserved for an exact-price Session attempt allocation.';

create function public.levelledup_guard_tournament_free_paid_classification()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.entry_fee_minor is not distinct from old.entry_fee_minor then
    return new;
  end if;

  if old.status <> 'draft' then
    raise exception 'Tournament free/paid classification is immutable after draft.'
      using errcode = '22023';
  end if;

  if (old.entry_fee_minor = 0) is distinct from (new.entry_fee_minor = 0)
    and (
      exists (
        select 1 from public.tournament_stages as stage
        where stage.tournament_id = old.id
      )
      or exists (
        select 1 from public.tournament_stage_sessions as session
        where session.tournament_id = old.id
      )
    ) then
    raise exception 'Change the draft Tournament type before creating Stages or Sessions.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger tournaments_04_guard_free_paid_classification
before update of entry_fee_minor on public.tournaments
for each row execute function public.levelledup_guard_tournament_free_paid_classification();

create function public.levelledup_enforce_stage_free_paid_contract()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  tournament_fee bigint;
begin
  select tournament.entry_fee_minor into tournament_fee
  from public.tournaments as tournament
  where tournament.id = new.tournament_id;

  if tournament_fee is null then
    raise exception 'Stage Tournament pricing contract is unavailable.'
      using errcode = '23503';
  end if;

  if tournament_fee = 0 then
    if new.retry_allowed
      or (new.stage_fee_minor is not null and new.stage_fee_minor <> 0) then
      raise exception 'Free Tournament Stages must have a zero fee and cannot allow retries.'
        using errcode = '22023';
    end if;
  elsif new.stage_fee_minor is not null and new.stage_fee_minor <= 0 then
    raise exception 'Paid Tournament Stage fee templates must be positive.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger tournament_stages_04_free_paid_contract
before insert or update of tournament_id, stage_fee_minor, retry_allowed
on public.tournament_stages
for each row execute function public.levelledup_enforce_stage_free_paid_contract();

create function public.levelledup_enforce_session_free_paid_contract()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  tournament_fee bigint;
begin
  select tournament.entry_fee_minor into tournament_fee
  from public.tournaments as tournament
  where tournament.id = new.tournament_id;

  if tournament_fee is null then
    raise exception 'Session Tournament pricing contract is unavailable.'
      using errcode = '23503';
  end if;

  if tournament_fee = 0 and new.entry_fee_minor <> 0 then
    raise exception 'Free Tournament Session prices must be zero.'
      using errcode = '22023';
  elsif tournament_fee > 0 and new.entry_fee_minor <= 0 then
    raise exception 'Paid Tournament Session prices must be positive.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger tournament_stage_sessions_04_free_paid_contract
before insert or update of tournament_id, entry_fee_minor
on public.tournament_stage_sessions
for each row execute function public.levelledup_enforce_session_free_paid_contract();

-- This trigger runs before the source validator and keeps initial Tournament
-- registration entitlements distinct from separately priced Session attempts.
create function public.levelledup_enforce_session_entry_free_paid_contract()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  tournament public.tournaments;
  stage public.tournament_stages;
  session public.tournament_stage_sessions;
begin
  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = new.registration_id;

  select current_tournament.* into tournament
  from public.tournaments as current_tournament
  where current_tournament.id = new.tournament_id;

  select current_stage.* into stage
  from public.tournament_stages as current_stage
  where current_stage.id = new.stage_id;

  select current_session.* into session
  from public.tournament_stage_sessions as current_session
  where current_session.id = new.session_id;

  if registration.id is null or tournament.id is null
    or stage.id is null or session.id is null then
    raise exception 'Session Entry free/paid parents are incomplete.'
      using errcode = '23503';
  end if;

  if tournament.entry_fee_minor = 0 then
    if session.entry_fee_minor <> 0 then
      raise exception 'Free Tournament participation requires a zero-price Session.'
        using errcode = '22023';
    end if;
    if new.source_type in ('paid', 'credit') then
      raise exception 'Free Tournament participation cannot create payment or credit-backed Session Entries.'
        using errcode = '22023';
    end if;
  elsif session.entry_fee_minor <= 0 then
    raise exception 'Paid Tournament Sessions must retain a positive authoritative price.'
      using errcode = '22023';
  end if;

  if new.source_type = 'free' then
    if tournament.entry_fee_minor <> 0
      or registration.initial_session_id is distinct from new.session_id
      or stage.stage_number <> 1
      or new.source_paid_entry_id is not null
      or new.earned_from_session_entry_id is not null
      or new.source_credit_ledger_entry_id is not null
      or new.source_provenance ->> 'entitlement'
        is distinct from 'initial_registration_confirmation' then
      raise exception 'Free Session Entry requires the selected zero-fee initial Stage 1 registration entitlement.'
        using errcode = '22023';
    end if;
  elsif new.source_type = 'registration' then
    if tournament.entry_fee_minor <= 0
      or registration.initial_session_id is distinct from new.session_id
      or stage.stage_number <> 1
      or new.source_paid_entry_id is not null
      or new.earned_from_session_entry_id is not null
      or new.source_credit_ledger_entry_id is not null
      or new.source_provenance ->> 'entitlement'
        is distinct from 'initial_registration_confirmation'
      or new.source_provenance ->> 'payment_id' is null then
      raise exception 'Paid initial registration entitlement requires its selected Stage 1 Session and verified Tournament payment provenance.'
        using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;

create trigger tournament_session_entries_00_free_paid_contract
before insert on public.tournament_session_entries
for each row execute function public.levelledup_enforce_session_entry_free_paid_contract();

-- The selected Session is exact participation identity. The Tournament, not
-- that Session, owns the one-time initial registration price.
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

  select current_session.* into selected_session
  from public.tournament_stage_sessions as current_session
  where current_session.id = registration.initial_session_id
  for share;

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

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Payment requires a future selected Session that is open or planned for entry.'
      using errcode = 'P4421';
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

create or replace function public.levelledup_require_verified_payment_for_confirmation()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  tournament public.tournaments;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    select current_tournament.* into tournament
    from public.tournaments as current_tournament
    where current_tournament.id = new.tournament_id
    for share;

    select current_session.* into selected_session
    from public.tournament_stage_sessions as current_session
    where current_session.id = new.initial_session_id
    for share;

    select current_stage.* into selected_stage
    from public.tournament_stages as current_stage
    where current_stage.id = selected_session.stage_id
    for share;

    if tournament.id is null or selected_session.id is null
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

    if tournament.entry_fee_minor > 0 and not exists (
      select 1
      from public.tournament_registration_payments as payment
      where payment.registration_id = new.id
        and payment.tournament_id = new.tournament_id
        and payment.team_id = new.team_id
        and payment.session_id = selected_session.id
        and payment.status = 'verified'
        and payment.expected_amount_minor::bigint = tournament.entry_fee_minor
        and payment.currency = tournament.currency
    ) then
      raise exception 'Verify the Tournament initial registration payment before approving this registration.'
        using errcode = 'P4508';
    end if;
  end if;

  return new;
end;
$$;

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

create or replace function public.levelledup_admin_create_session_entry(
  p_session_id uuid,
  p_registration_id uuid,
  p_source_type text,
  p_source_paid_entry_id uuid,
  p_earned_from_session_entry_id uuid,
  p_source_credit_grant_entry_id uuid,
  p_reason text,
  p_request_id uuid,
  p_source_provenance jsonb
)
returns public.tournament_session_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  session public.tournament_stage_sessions;
  registration public.tournament_registrations;
  existing public.tournament_session_entries;
  existing_credit public.levelledup_credit_ledger_entries;
  credit_grant public.levelledup_credit_ledger_entries;
  applied_credit public.levelledup_credit_ledger_entries;
  created public.tournament_session_entries;
  normalized_source text := lower(btrim(coalesce(p_source_type, '')));
  normalized_reason text := btrim(coalesce(p_reason, ''));
  actor_role text;
begin
  perform public.levelledup_require_admin('admin');

  if p_request_id is null
    or char_length(normalized_reason) not between 10 and 1000
    or coalesce(jsonb_typeof(p_source_provenance), 'null') <> 'object' then
    raise exception 'Request ID, object provenance and a 10-1000 character reason are required.'
      using errcode = '22023';
  end if;

  if normalized_source not in ('paid', 'earned', 'credit', 'admin_grant', 'free')
    or (normalized_source = 'paid' and (
      p_source_paid_entry_id is null
      or p_earned_from_session_entry_id is not null
      or p_source_credit_grant_entry_id is not null
    ))
    or (normalized_source = 'earned' and (
      p_source_paid_entry_id is not null
      or p_earned_from_session_entry_id is null
      or p_source_credit_grant_entry_id is not null
    ))
    or (normalized_source = 'credit' and (
      p_source_paid_entry_id is not null
      or p_earned_from_session_entry_id is not null
      or p_source_credit_grant_entry_id is null
    ))
    or (normalized_source in ('admin_grant', 'free') and (
      p_source_paid_entry_id is not null
      or p_earned_from_session_entry_id is not null
      or p_source_credit_grant_entry_id is not null
    )) then
    raise exception 'Provide exactly the source fields required by the selected Session Entry source.'
      using errcode = '22023';
  end if;

  if normalized_source = 'credit' and char_length(normalized_reason) > 500 then
    raise exception 'Credit-backed Session Entry reason cannot exceed the ledger limit of 500 characters.'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('session-entry-request:' || p_request_id::text, 0)
  );

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  select current_session.* into session
  from public.tournament_stage_sessions as current_session
  where current_session.id = p_session_id
  for update;

  if session.id is null or registration.id is null
    or session.tournament_id <> registration.tournament_id then
    raise exception 'Session and registration must belong to the same Tournament.'
      using errcode = '23503';
  end if;

  select session_entry.* into existing
  from public.tournament_session_entries as session_entry
  where session_entry.request_id = p_request_id;

  if existing.id is not null then
    if existing.session_id <> p_session_id
      or existing.registration_id <> p_registration_id
      or existing.source_type <> normalized_source
      or existing.source_paid_entry_id is distinct from p_source_paid_entry_id
      or existing.earned_from_session_entry_id is distinct from p_earned_from_session_entry_id
      or existing.reason <> normalized_reason
      or existing.source_provenance <> p_source_provenance then
      raise exception 'Request ID is already used by another Session Entry.'
        using errcode = '23505';
    end if;

    if normalized_source = 'credit' then
      select ledger_entry.* into existing_credit
      from public.levelledup_credit_ledger_entries as ledger_entry
      where ledger_entry.id = existing.source_credit_ledger_entry_id;

      if existing_credit.related_entry_id is distinct from p_source_credit_grant_entry_id
        or existing_credit.amount_delta_minor is distinct from -session.entry_fee_minor
        or existing_credit.currency is distinct from session.fee_currency then
        raise exception 'Request ID is already used with different credit provenance.'
          using errcode = '23505';
      end if;
    elsif existing.source_credit_ledger_entry_id is not null then
      raise exception 'Request ID source provenance is inconsistent.' using errcode = '23505';
    end if;

    return existing;
  end if;

  actor_role := public.levelledup_current_admin_role();

  if normalized_source = 'credit' then
    if session.entry_fee_minor = 0 then
      raise exception 'A zero-fee Session must not create a credit debit; use a free, earned or Admin-granted Entry.'
        using errcode = '22023';
    end if;

    select grant_entry.* into credit_grant
    from public.levelledup_credit_ledger_entries as grant_entry
    where grant_entry.id = p_source_credit_grant_entry_id
      and grant_entry.event_type = 'grant';

    if credit_grant.id is null
      or credit_grant.operational_team_id <> registration.team_id then
      raise exception 'Credit grant must belong operationally to the active registration team.'
        using errcode = '22023';
    end if;
    if credit_grant.currency <> session.fee_currency then
      raise exception 'Credit currency must match the authoritative Session currency.'
        using errcode = '22023';
    end if;

    applied_credit := public.levelledup_admin_record_credit_debit(
      p_source_credit_grant_entry_id,
      'apply',
      session.entry_fee_minor,
      normalized_reason,
      'session-entry:' || p_request_id::text || ':credit-apply'
    );
  elsif normalized_source = 'paid' and session.entry_fee_minor = 0 then
    raise exception 'A zero-fee Session must not create a paid financial Entry.'
      using errcode = '22023';
  elsif normalized_source = 'free' and session.entry_fee_minor <> 0 then
    raise exception 'A free Session Entry requires a zero-price Session.'
      using errcode = '22023';
  end if;

  insert into public.tournament_session_entries (
    tournament_id, stage_id, session_id, registration_id, team_id,
    source_type, source_paid_entry_id, earned_from_session_entry_id,
    source_credit_ledger_entry_id, source_occurred_at, source_provenance,
    reason, request_id, created_by, created_by_role
  ) values (
    session.tournament_id, session.stage_id, session.id,
    registration.id, registration.team_id, normalized_source,
    p_source_paid_entry_id, p_earned_from_session_entry_id,
    applied_credit.id, now(), p_source_provenance,
    normalized_reason, p_request_id, auth.uid(), actor_role
  ) returning * into created;

  return created;
end;
$$;

create or replace function public.levelledup_cancel_unused_registration_session_entries(
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
      and entry.source_type in ('paid', 'registration', 'free')
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
      raise exception 'Only a preserved initial registration entitlement can be lifecycle-cancelled.'
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
    set status = 'cancelled',
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

-- Initial registration payments keep their selected Session identity, while
-- cancellation returns the Tournament registration value through the existing
-- Tournament-credit path.
create or replace function public.levelledup_guard_tournament_team_credit_history()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  source_payment public.tournament_registration_payments;
  source_registration public.tournament_registrations;
  source_tournament public.tournaments;
  is_initial_registration_payment boolean := false;
begin
  if tg_op = 'DELETE' then
    raise exception 'Tournament credit history cannot be deleted.'
      using errcode = 'P4514';
  end if;

  if tg_op = 'UPDATE' then
    if new.registration_id is distinct from old.registration_id
      or new.tournament_id is distinct from old.tournament_id
      or new.team_id is distinct from old.team_id
      or new.source_payment_id is distinct from old.source_payment_id
      or new.source_reference_id is distinct from old.source_reference_id
      or new.amount_minor is distinct from old.amount_minor
      or new.currency is distinct from old.currency
      or new.created_by is distinct from old.created_by
      or new.created_at is distinct from old.created_at then
      raise exception 'Tournament credit history is immutable.'
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
    pg_catalog.hashtextextended('credit-source-payment:' || new.source_payment_id::text, 0)
  );

  select payment.* into source_payment
  from public.tournament_registration_payments as payment
  where payment.id = new.source_payment_id
  for share;

  select registration.* into source_registration
  from public.tournament_registrations as registration
  where registration.id = new.registration_id
  for share;

  select tournament.* into source_tournament
  from public.tournaments as tournament
  where tournament.id = new.tournament_id
  for share;

  is_initial_registration_payment := source_payment.session_id is not null
    and source_registration.initial_session_id = source_payment.session_id
    and source_payment.expected_amount_minor::bigint = source_tournament.entry_fee_minor
    and source_payment.currency = source_tournament.currency;

  if source_payment.id is null
    or source_registration.id is null
    or source_tournament.id is null
    or source_payment.status <> 'verified'
    or source_payment.registration_id <> new.registration_id
    or source_payment.tournament_id <> new.tournament_id
    or source_payment.team_id <> new.team_id
    or source_registration.tournament_id <> new.tournament_id
    or source_registration.team_id <> new.team_id
    or source_payment.reference_id <> new.source_reference_id
    or (source_payment.session_id is not null and not is_initial_registration_payment)
    or source_tournament.status <> 'cancelled'
    or source_tournament.entry_fee_minor <= 0
    or new.amount_minor::bigint <> source_tournament.entry_fee_minor
    or new.currency <> source_tournament.currency then
    raise exception 'Tournament credit requires a verified initial registration payment at the authoritative Tournament fee.'
      using errcode = 'P4516';
  end if;

  if exists (
    select 1 from public.tournament_stage_refund_cases as refund_case
    where refund_case.source_payment_id = source_payment.id
      and refund_case.status <> 'rejected'
  ) or exists (
    select 1 from public.tournament_stage_credit_entitlements as credit
    where credit.source_payment_id = source_payment.id
  ) then
    raise exception 'The source payment is already represented by Session-attempt refund history.'
      using errcode = '23505';
  end if;

  return new;
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

  if selected_tournament.status not in ('draft', 'registration_open', 'registration_closed')
    or selected_tournament.archived_at is not null then
    raise exception 'Only an active tournament that has not begun can be cancelled.'
      using errcode = 'P4303';
  end if;

  if exists (
    select 1 from public.tournament_matches as match
    where match.tournament_id = selected_tournament.id
      and match.status in ('live', 'completed')
  ) or exists (
    select 1 from public.match_results as result
    where result.tournament_id = selected_tournament.id
  ) then
    raise exception 'This tournament has begun and must remain historical.'
      using errcode = 'P4303';
  end if;

  perform 1 from public.tournament_registrations as current_registration
  where current_registration.tournament_id = selected_tournament.id
  for update;
  perform 1 from public.tournament_registration_payments as payment
  where payment.tournament_id = selected_tournament.id
  for update;

  -- Only true Session-attempt payments enter the Session refund path. Initial
  -- Tournament payments retain their selected Session identity but are not
  -- converted into an exact-price paid Session allocation.
  for session_payment in
    select payment.id as payment_id, payment.registration_id,
      session.stage_id, session.id as session_id
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
      and not (
        current_registration.initial_session_id = payment.session_id
        and payment.expected_amount_minor::bigint = selected_tournament.entry_fee_minor
        and payment.currency = selected_tournament.currency
      )
    order by payment.submitted_at, payment.id
  loop
    perform public.levelledup_admin_create_stage_paid_entry(
      session_payment.registration_id, session_payment.stage_id, 'session',
      session_payment.payment_id, session_payment.session_id, null
    );
  end loop;

  for registration in
    select current_registration.id
    from public.tournament_registrations as current_registration
    where current_registration.tournament_id = selected_tournament.id
    order by current_registration.created_at, current_registration.id
  loop
    perform public.levelledup_cancel_unused_registration_session_entries(
      registration.id, authenticated_admin_id,
      'Tournament cancelled before competition; unused Session participation cancelled'
    );
    perform public.levelledup_credit_unused_registration_paid_entries(
      registration.id, authenticated_admin_id,
      'Tournament cancelled before competition; unused Session payment credited', true
    );
  end loop;

  update public.tournaments set status = 'cancelled'
  where id = selected_tournament.id
  returning * into selected_tournament;

  insert into public.tournament_team_credits (
    tournament_id, registration_id, team_id, source_payment_id,
    source_reference_id, amount_minor, currency, status,
    created_by, status_updated_by
  )
  select selected_tournament.id, current_registration.id,
    current_registration.team_id, payment.id, payment.reference_id,
    selected_tournament.entry_fee_minor, selected_tournament.currency,
    'available', authenticated_admin_id, authenticated_admin_id
  from public.tournament_registrations as current_registration
  join public.tournament_registration_payments as payment
    on payment.registration_id = current_registration.id
   and payment.tournament_id = current_registration.tournament_id
   and payment.team_id = current_registration.team_id
   and payment.status = 'verified'
  where current_registration.tournament_id = selected_tournament.id
    and selected_tournament.entry_fee_minor > 0
    and (
      payment.session_id is null
      or (
        current_registration.initial_session_id = payment.session_id
        and payment.expected_amount_minor::bigint = selected_tournament.entry_fee_minor
        and payment.currency = selected_tournament.currency
      )
    )
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
  existing_tournament_credit public.tournament_team_credits;
  existing_session_credit public.tournament_stage_credit_entitlements;
  uses_tournament_registration_value boolean := false;
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

  if selected_payment.id is null or selected_payment.payment_method <> 'manual' then
    raise exception 'Cancelled tournament payment submission not found.'
      using errcode = 'P4507';
  end if;

  select tournament.* into selected_tournament
  from public.tournaments as tournament
  where tournament.id = selected_payment.tournament_id
  for update;

  select registration.* into selected_registration
  from public.tournament_registrations as registration
  where registration.id = selected_payment.registration_id
  for update;

  if selected_tournament.id is null or selected_tournament.status <> 'cancelled'
    or selected_registration.id is null
    or selected_registration.tournament_id <> selected_payment.tournament_id
    or selected_registration.team_id <> selected_payment.team_id then
    raise exception 'This action is only available for a valid cancelled Tournament payment.'
      using errcode = 'P4518';
  end if;

  uses_tournament_registration_value := selected_payment.session_id is null
    or (
      selected_registration.initial_session_id = selected_payment.session_id
      and selected_payment.expected_amount_minor::bigint = selected_tournament.entry_fee_minor
      and selected_payment.currency = selected_tournament.currency
    );

  if selected_payment.status = 'rejected' then
    if normalized_decision = 'reject' then return selected_payment; end if;
    raise exception 'A rejected payment cannot later be confirmed.' using errcode = 'P4518';
  end if;

  if selected_payment.status = 'verified' then
    if uses_tournament_registration_value then
      select credit.* into existing_tournament_credit
      from public.tournament_team_credits as credit
      where credit.registration_id = selected_payment.registration_id
      for share;

      if normalized_decision = 'confirm'
        and selected_payment.cancelled_reconciled_at is not null
        and existing_tournament_credit.source_payment_id = selected_payment.id
        and existing_tournament_credit.amount_minor = selected_payment.expected_amount_minor
        and existing_tournament_credit.currency = selected_payment.currency then
        return selected_payment;
      end if;
    else
      select credit.* into existing_session_credit
      from public.tournament_stage_credit_entitlements as credit
      where credit.source_payment_id = selected_payment.id
      order by credit.created_at, credit.id limit 1
      for share;

      if normalized_decision = 'confirm'
        and selected_payment.cancelled_reconciled_at is not null
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
    set status = 'rejected', verification_source = 'admin',
      reviewed_by = authenticated_admin_id, reviewed_at = now()
    where id = selected_payment.id
    returning * into selected_payment;
    return selected_payment;
  end if;

  if uses_tournament_registration_value then
    if selected_tournament.entry_fee_minor <= 0
      or selected_payment.expected_amount_minor::bigint <> selected_tournament.entry_fee_minor
      or selected_payment.currency <> selected_tournament.currency then
      raise exception 'The preserved payment does not match the cancelled Tournament initial registration fee.'
        using errcode = 'P4519';
    end if;
  else
    select session.* into selected_session
    from public.tournament_stage_sessions as session
    where session.id = selected_payment.session_id
    for share;
    select stage.* into selected_stage
    from public.tournament_stages as stage
    where stage.id = selected_session.stage_id
    for share;

    if selected_session.id is null
      or selected_session.tournament_id <> selected_payment.tournament_id
      or selected_stage.id is null
      or selected_stage.tournament_id <> selected_payment.tournament_id
      or selected_payment.expected_amount_minor::bigint <> selected_session.entry_fee_minor
      or selected_payment.currency <> selected_session.fee_currency then
      raise exception 'The preserved Session-attempt payment does not match its exact Session identity and price.'
        using errcode = 'P4519';
    end if;
  end if;

  update public.tournament_registration_payments
  set status = 'verified', verification_source = 'admin',
    reviewed_by = authenticated_admin_id, reviewed_at = now(),
    cancelled_reconciled_at = now(), cancelled_reconciled_by = authenticated_admin_id
  where id = selected_payment.id
  returning * into selected_payment;

  if uses_tournament_registration_value then
    insert into public.tournament_team_credits (
      tournament_id, registration_id, team_id, source_payment_id,
      source_reference_id, amount_minor, currency, status,
      created_by, status_updated_by
    ) values (
      selected_payment.tournament_id, selected_payment.registration_id,
      selected_payment.team_id, selected_payment.id, selected_payment.reference_id,
      selected_payment.expected_amount_minor, selected_payment.currency,
      'available', authenticated_admin_id, authenticated_admin_id
    ) on conflict (registration_id) do nothing;

    select credit.* into existing_tournament_credit
    from public.tournament_team_credits as credit
    where credit.registration_id = selected_payment.registration_id
    for share;

    if existing_tournament_credit.id is null
      or existing_tournament_credit.source_payment_id <> selected_payment.id
      or existing_tournament_credit.amount_minor <> selected_payment.expected_amount_minor
      or existing_tournament_credit.currency <> selected_payment.currency then
      raise exception 'A conflicting cancellation credit already exists for this registration.'
        using errcode = 'P4519';
    end if;
  else
    perform public.levelledup_admin_create_stage_paid_entry(
      selected_payment.registration_id, selected_stage.id, 'session',
      selected_payment.id, selected_session.id, null
    );
    perform public.levelledup_cancel_unused_registration_session_entries(
      selected_payment.registration_id, authenticated_admin_id,
      'Cancelled tournament payment reconciled; unused Session participation cancelled'
    );
    perform public.levelledup_credit_unused_registration_paid_entries(
      selected_payment.registration_id, authenticated_admin_id,
      'Cancelled tournament payment reconciled to exact Session credit', true
    );

    if not exists (
      select 1 from public.tournament_stage_credit_entitlements as credit
      where credit.source_payment_id = selected_payment.id
        and credit.session_id = selected_payment.session_id
        and credit.amount_minor = selected_payment.expected_amount_minor
        and credit.currency = selected_payment.currency
    ) then
      raise exception 'Session-bound cancellation credit creation failed.'
        using errcode = 'P4519';
    end if;
  end if;

  return selected_payment;
end;
$$;

-- Initial approval grants one registration entitlement to the exact selected
-- Session. It does not reclassify the Tournament registration payment as a
-- Session-attempt purchase; future paid attempts continue to use paid entries.
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
    select session_entry.* into existing_entry
    from public.tournament_session_entries as session_entry
    where session_entry.registration_id = registration.id
      and session_entry.session_id = registration.initial_session_id
    order by session_entry.created_at, session_entry.id
    limit 1;

    if existing_entry.id is not null then
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

  if selected_tournament.entry_fee_minor > 0 then
    select payment.* into verified_payment
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.tournament_id = registration.tournament_id
      and payment.team_id = registration.team_id
      and payment.session_id = selected_session.id
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

alter function public.levelledup_guard_tournament_free_paid_classification() owner to postgres;
alter function public.levelledup_enforce_stage_free_paid_contract() owner to postgres;
alter function public.levelledup_enforce_session_free_paid_contract() owner to postgres;
alter function public.levelledup_enforce_session_entry_free_paid_contract() owner to postgres;
alter function public.levelledup_validate_initial_session_payment() owner to postgres;
alter function public.levelledup_submit_manual_tournament_payment(uuid, text) owner to postgres;
alter function public.levelledup_require_verified_payment_for_confirmation() owner to postgres;
alter function public.levelledup_validate_session_entry_source() owner to postgres;
alter function public.levelledup_admin_create_session_entry(uuid, uuid, text, uuid, uuid, uuid, text, uuid, jsonb) owner to postgres;
alter function public.levelledup_cancel_unused_registration_session_entries(uuid, uuid, text) owner to postgres;
alter function public.levelledup_guard_tournament_team_credit_history() owner to postgres;
alter function public.levelledup_admin_cancel_tournament_with_credits(uuid) owner to postgres;
alter function public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text) owner to postgres;
alter function public.levelledup_admin_review_tournament_registration(uuid, text) owner to postgres;

revoke all on function public.levelledup_guard_tournament_free_paid_classification()
  from public, anon, authenticated;
revoke all on function public.levelledup_enforce_stage_free_paid_contract()
  from public, anon, authenticated;
revoke all on function public.levelledup_enforce_session_free_paid_contract()
  from public, anon, authenticated;
revoke all on function public.levelledup_enforce_session_entry_free_paid_contract()
  from public, anon, authenticated;
revoke all on function public.levelledup_validate_initial_session_payment()
  from public, anon, authenticated;
revoke all on function public.levelledup_require_verified_payment_for_confirmation()
  from public, anon, authenticated;
revoke all on function public.levelledup_validate_session_entry_source()
  from public, anon, authenticated;
revoke all on function public.levelledup_guard_tournament_team_credit_history()
  from public, anon, authenticated;

comment on function public.levelledup_submit_manual_tournament_payment(uuid, text) is
  'Captain-only initial manual payment submission. The exact selected Stage 1 Session is preserved as identity; amount and currency come only from the Tournament initial registration fee.';
comment on function public.levelledup_admin_review_tournament_registration(uuid, text) is
  'Admin-only atomic review. Approval creates one initial registration entitlement for the selected Session; it never converts the Tournament registration payment into a Session-attempt paid allocation.';

do $$
begin
  if exists (
    select 1
    from public.tournament_stages as stage
    join public.tournaments as tournament on tournament.id = stage.tournament_id
    where tournament.status not in ('completed', 'cancelled')
      and (
        (tournament.entry_fee_minor = 0 and (
          stage.retry_allowed or coalesce(stage.stage_fee_minor, 0) <> 0
        ))
        or (tournament.entry_fee_minor > 0
          and stage.stage_fee_minor is not null
          and stage.stage_fee_minor <= 0)
      )
  ) then
    raise exception 'Operational Stage pricing conflicts with the free/paid Tournament contract.';
  end if;

  if exists (
    select 1
    from public.tournament_stage_sessions as session
    join public.tournaments as tournament on tournament.id = session.tournament_id
    where tournament.status not in ('completed', 'cancelled')
      and (
        (tournament.entry_fee_minor = 0 and session.entry_fee_minor <> 0)
        or (tournament.entry_fee_minor > 0 and session.entry_fee_minor <= 0)
      )
  ) then
    raise exception 'Operational Session pricing conflicts with the free/paid Tournament contract.';
  end if;

  if has_function_privilege(
      'anon',
      'public.levelledup_enforce_session_entry_free_paid_contract()'::regprocedure,
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.levelledup_enforce_session_entry_free_paid_contract()'::regprocedure,
      'EXECUTE'
    ) then
    raise exception 'Free/paid contract helpers must not be browser-executable.';
  end if;
end;
$$;

commit;
