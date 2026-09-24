begin;

-- Batch 1: make the exact Session, rather than caller input or its Stage
-- template, the authoritative financial contract for one attempt.

do $$
begin
  if exists (
    select 1
    from public.tournament_stage_sessions as session
    join public.tournament_stages as stage
      on stage.id = session.stage_id
      and stage.tournament_id = session.tournament_id
    where stage.stage_fee_minor is null
      or stage.fee_currency is null
  ) then
    raise exception
      'Cannot backfill Session prices: at least one owning Stage has incomplete fee configuration. Resolve it explicitly before applying this migration.';
  end if;
end;
$$;

alter table public.tournament_stage_sessions
  add column entry_fee_minor bigint,
  add column fee_currency text;

update public.tournament_stage_sessions as session
set entry_fee_minor = stage.stage_fee_minor,
    fee_currency = stage.fee_currency
from public.tournament_stages as stage
where stage.id = session.stage_id
  and stage.tournament_id = session.tournament_id;

alter table public.tournament_stage_sessions
  alter column entry_fee_minor set not null,
  alter column fee_currency set not null,
  add constraint tournament_stage_sessions_entry_fee_valid
    check (entry_fee_minor >= 0),
  add constraint tournament_stage_sessions_fee_currency_valid
    check (fee_currency = upper(fee_currency) and fee_currency ~ '^[A-Z]{3}$');

comment on column public.tournament_stage_sessions.entry_fee_minor is
  'Authoritative price in minor units for one attempt in this exact Session. The Stage fee is only the creation template.';
comment on column public.tournament_stage_sessions.fee_currency is
  'Authoritative normalized ISO-style three-letter currency for this exact Session.';

-- Existing immutable financial rows are evidence. A mismatch is ambiguous and
-- must be resolved deliberately; never invent or rewrite money during backfill.
do $$
begin
  if exists (
    select 1
    from public.tournament_registration_paid_entries as paid_entry
    join public.tournament_stage_sessions as session
      on session.id = paid_entry.session_id
      and session.stage_id = paid_entry.stage_id
      and session.tournament_id = paid_entry.tournament_id
    where paid_entry.entry_scope = 'session'
      and (
        paid_entry.amount_minor::bigint <> session.entry_fee_minor
        or paid_entry.currency <> session.fee_currency
      )
  ) then
    raise exception
      'Cannot establish Session prices: preserved paid Session history conflicts with the owning Stage template. Manual auditable resolution is required.';
  end if;

  if exists (
    select 1
    from public.tournament_session_entries as session_entry
    join public.tournament_stage_sessions as session
      on session.id = session_entry.session_id
      and session.stage_id = session_entry.stage_id
      and session.tournament_id = session_entry.tournament_id
    join public.levelledup_credit_ledger_entries as debit
      on debit.id = session_entry.source_credit_ledger_entry_id
    where session_entry.source_type = 'credit'
      and (
        debit.event_type <> 'apply'
        or debit.amount_delta_minor <> -session.entry_fee_minor
        or debit.currency <> session.fee_currency
      )
  ) then
    raise exception
      'Cannot establish Session prices: preserved credit-backed Session history conflicts with the owning Stage template. Manual auditable resolution is required.';
  end if;
end;
$$;

create table public.tournament_session_price_events (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null,
  stage_id uuid not null,
  session_id uuid not null,
  event_type text not null,
  old_entry_fee_minor bigint,
  new_entry_fee_minor bigint not null,
  old_fee_currency text,
  new_fee_currency text not null,
  changed_by uuid references auth.users(id) on delete restrict,
  changed_by_role text not null,
  reason text not null,
  request_id uuid not null unique,
  transaction_id bigint not null default txid_current(),
  created_at timestamptz not null default clock_timestamp(),
  constraint tournament_session_price_events_session_fk
    foreign key (session_id, stage_id, tournament_id)
    references public.tournament_stage_sessions(id, stage_id, tournament_id)
    on delete restrict,
  constraint tournament_session_price_events_type_valid
    check (event_type in ('initialized', 'changed')),
  constraint tournament_session_price_events_old_pair_valid
    check (
      (old_entry_fee_minor is null and old_fee_currency is null)
      or (old_entry_fee_minor is not null and old_fee_currency is not null)
    ),
  constraint tournament_session_price_events_values_valid
    check (
      new_entry_fee_minor >= 0
      and new_fee_currency = upper(new_fee_currency)
      and new_fee_currency ~ '^[A-Z]{3}$'
      and (old_entry_fee_minor is null or old_entry_fee_minor >= 0)
      and (
        old_fee_currency is null
        or (old_fee_currency = upper(old_fee_currency) and old_fee_currency ~ '^[A-Z]{3}$')
      )
    ),
  constraint tournament_session_price_events_transition_valid
    check (
      (event_type = 'initialized'
        and old_entry_fee_minor is null
        and old_fee_currency is null)
      or (event_type = 'changed'
        and old_entry_fee_minor is not null
        and old_fee_currency is not null
        and (
          old_entry_fee_minor is distinct from new_entry_fee_minor
          or old_fee_currency is distinct from new_fee_currency
        ))
    ),
  constraint tournament_session_price_events_actor_role_valid
    check (changed_by_role in ('system', 'admin', 'tournament_admin', 'super_admin')),
  constraint tournament_session_price_events_actor_valid
    check (event_type = 'initialized' or changed_by is not null),
  constraint tournament_session_price_events_reason_valid
    check (reason = btrim(reason) and char_length(reason) between 10 and 1000)
);

create index tournament_session_price_events_history_idx
  on public.tournament_session_price_events(session_id, created_at, id);

comment on table public.tournament_session_price_events is
  'Append-only audit history for every Session price initialization and trusted pre-participation change.';

insert into public.tournament_session_price_events (
  tournament_id, stage_id, session_id, event_type,
  old_entry_fee_minor, new_entry_fee_minor,
  old_fee_currency, new_fee_currency,
  changed_by, changed_by_role, reason, request_id
)
select session.tournament_id, session.stage_id, session.id, 'initialized',
  null, session.entry_fee_minor, null, session.fee_currency,
  null, 'system',
  'Session price baseline copied from the preserved owning Stage configuration during authoritative Session pricing repair.',
  gen_random_uuid()
from public.tournament_stage_sessions as session;

create function public.levelledup_preserve_session_price_events()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'Session price history is append-only.' using errcode = '22023';
end;
$$;

create trigger tournament_session_price_events_append_only
before update or delete on public.tournament_session_price_events
for each row execute function public.levelledup_preserve_session_price_events();

create function public.levelledup_record_initial_session_price()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_role text;
begin
  select case admin_user.role
      when 'tournament_admin' then 'admin'
      else admin_user.role
    end
  into actor_role
  from public.admin_users as admin_user
  where admin_user.user_id = new.created_by
    and admin_user.is_active;

  insert into public.tournament_session_price_events (
    tournament_id, stage_id, session_id, event_type,
    old_entry_fee_minor, new_entry_fee_minor,
    old_fee_currency, new_fee_currency,
    changed_by, changed_by_role, reason, request_id
  ) values (
    new.tournament_id, new.stage_id, new.id, 'initialized',
    null, new.entry_fee_minor, null, new.fee_currency,
    new.created_by, coalesce(actor_role, 'system'),
    'Session price initialized from the owning Stage template when the Session was created.',
    gen_random_uuid()
  );

  return new;
end;
$$;

create trigger tournament_stage_sessions_record_initial_price
after insert on public.tournament_stage_sessions
for each row execute function public.levelledup_record_initial_session_price();

create function public.levelledup_guard_session_price_change()
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

  -- A Session price is permanently locked after any participation identity,
  -- assignment, or financial linkage exists, including cancelled history.
  if exists (
      select 1 from public.tournament_session_entries as session_entry
      where session_entry.session_id = old.id
    )
    or exists (
      select 1 from public.tournament_stage_assignments as assignment
      where assignment.session_id = old.id
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

create trigger tournament_stage_sessions_05_guard_price_change
before update of entry_fee_minor, fee_currency
on public.tournament_stage_sessions
for each row execute function public.levelledup_guard_session_price_change();

create function public.levelledup_admin_set_session_price(
  p_session_id uuid,
  p_entry_fee_minor bigint,
  p_fee_currency text,
  p_reason text,
  p_request_id uuid
)
returns public.tournament_stage_sessions
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  session public.tournament_stage_sessions;
  existing_event public.tournament_session_price_events;
  normalized_currency text := nullif(upper(btrim(p_fee_currency)), '');
  normalized_reason text := btrim(coalesce(p_reason, ''));
  actor_role text;
begin
  perform public.levelledup_require_admin('admin');

  if p_request_id is null
    or p_entry_fee_minor is null
    or p_entry_fee_minor < 0
    or normalized_currency is null
    or normalized_currency !~ '^[A-Z]{3}$'
    or char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'A non-negative fee, three-letter currency, request ID and 10-1000 character reason are required.'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('session-price-request:' || p_request_id::text, 0)
  );

  select event.* into existing_event
  from public.tournament_session_price_events as event
  where event.request_id = p_request_id;

  if existing_event.id is not null then
    if existing_event.event_type <> 'changed'
      or existing_event.session_id <> p_session_id
      or existing_event.new_entry_fee_minor <> p_entry_fee_minor
      or existing_event.new_fee_currency <> normalized_currency
      or existing_event.reason <> normalized_reason
      or existing_event.changed_by <> auth.uid() then
      raise exception 'Request ID is already used by another Session price action.'
        using errcode = '23505';
    end if;

    select current_session.* into session
    from public.tournament_stage_sessions as current_session
    where current_session.id = p_session_id;
    return session;
  end if;

  select current_session.* into session
  from public.tournament_stage_sessions as current_session
  where current_session.id = p_session_id
  for update;

  if session.id is null or session.status not in ('planned', 'open') then
    raise exception 'A configurable future Tournament Session is required.'
      using errcode = '22023';
  end if;
  if session.entry_fee_minor = p_entry_fee_minor
    and session.fee_currency = normalized_currency then
    raise exception 'Session price is already set to the requested value.'
      using errcode = '22023';
  end if;

  actor_role := public.levelledup_current_admin_role();
  insert into public.tournament_session_price_events (
    tournament_id, stage_id, session_id, event_type,
    old_entry_fee_minor, new_entry_fee_minor,
    old_fee_currency, new_fee_currency,
    changed_by, changed_by_role, reason, request_id
  ) values (
    session.tournament_id, session.stage_id, session.id, 'changed',
    session.entry_fee_minor, p_entry_fee_minor,
    session.fee_currency, normalized_currency,
    auth.uid(), actor_role, normalized_reason, p_request_id
  );

  update public.tournament_stage_sessions
  set entry_fee_minor = p_entry_fee_minor,
      fee_currency = normalized_currency
  where id = session.id
  returning * into session;

  return session;
end;
$$;

-- New Sessions copy the current Stage template once. Later Stage changes never
-- mutate an existing Session contract.
create or replace function public.levelledup_admin_create_tournament_session(
  p_stage_id uuid,
  p_display_name text,
  p_scheduled_start_at timestamptz default null,
  p_scheduled_end_at timestamptz default null
)
returns public.tournament_stage_sessions
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  stage public.tournament_stages;
  created public.tournament_stage_sessions;
  next_number integer;
begin
  perform public.levelledup_require_admin('admin');

  select current_stage.* into stage
  from public.tournament_stages as current_stage
  where current_stage.id = p_stage_id
  for update;

  if stage.id is null or stage.status in ('completed', 'cancelled') then
    raise exception 'An active Tournament Stage is required.' using errcode = '22023';
  end if;
  if stage.stage_fee_minor is null or stage.fee_currency is null then
    raise exception 'Complete the Stage fee template before creating a Session.'
      using errcode = '22023';
  end if;

  select coalesce(max(session.session_number), 0) + 1 into next_number
  from public.tournament_stage_sessions as session
  where session.stage_id = stage.id;

  insert into public.tournament_stage_sessions (
    tournament_id, stage_id, session_number, display_name,
    scheduled_start_at, scheduled_end_at,
    max_concurrent_lobbies, default_matches_per_lobby,
    entry_fee_minor, fee_currency, created_by
  ) values (
    stage.tournament_id, stage.id, next_number, btrim(p_display_name),
    p_scheduled_start_at, p_scheduled_end_at,
    stage.concurrent_lobby_capacity, stage.matches_per_lobby,
    stage.stage_fee_minor, stage.fee_currency, auth.uid()
  ) returning * into created;

  return created;
end;
$$;

-- Remove the amount-bearing allocation RPC. Both Stage and Session allocations
-- now derive their exact value from stored configuration.
drop function public.levelledup_admin_create_stage_paid_entry(
  uuid, uuid, text, uuid, integer, uuid, uuid
);

create function public.levelledup_admin_create_stage_paid_entry(
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
  stage public.tournament_stages;
  session public.tournament_stage_sessions;
  payment public.tournament_registration_payments;
  existing public.tournament_registration_paid_entries;
  created public.tournament_registration_paid_entries;
  scope text := lower(btrim(coalesce(p_entry_scope, '')));
  required_amount bigint;
  required_currency text;
  allocated bigint;
begin
  perform public.levelledup_require_admin('admin');

  if scope not in ('stage', 'session')
    or (scope = 'stage' and (p_session_id is not null or p_lobby_id is not null))
    or (scope = 'session' and p_session_id is null) then
    raise exception 'Select a Stage scope or an exact Session scope.' using errcode = '22023';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  select current_stage.* into stage
  from public.tournament_stages as current_stage
  where current_stage.id = p_stage_id
  for share;

  if registration.id is null or stage.id is null
    or stage.tournament_id <> registration.tournament_id then
    raise exception 'Registration and Stage must belong to the same Tournament.'
      using errcode = '23503';
  end if;

  if scope = 'session' then
    select current_session.* into session
    from public.tournament_stage_sessions as current_session
    where current_session.id = p_session_id
    for update;

    if session.id is null
      or session.stage_id <> stage.id
      or session.tournament_id <> registration.tournament_id then
      raise exception 'Paid Session must belong to the selected Stage and Tournament.'
        using errcode = '23503';
    end if;
    if session.status not in ('planned', 'open') then
      raise exception 'Paid allocation requires a future permitted Session.'
        using errcode = '22023';
    end if;
    if p_lobby_id is not null and not exists (
      select 1 from public.tournament_lobbies as lobby
      where lobby.id = p_lobby_id
        and lobby.session_id = session.id
        and lobby.stage_id = stage.id
        and lobby.tournament_id = registration.tournament_id
    ) then
      raise exception 'Paid-entry Lobby must belong to the selected Session.'
        using errcode = '23503';
    end if;

    required_amount := session.entry_fee_minor;
    required_currency := session.fee_currency;
  else
    required_amount := stage.stage_fee_minor;
    required_currency := stage.fee_currency;
  end if;

  if required_amount is null or required_currency is null then
    raise exception 'The selected participation scope has incomplete fee configuration.'
      using errcode = '22023';
  end if;
  if required_amount <= 0 then
    raise exception 'A paid entry requires a positive authoritative fee.' using errcode = '22023';
  end if;
  if required_amount > 2147483647 then
    raise exception 'The authoritative fee exceeds the existing payment allocation range.'
      using errcode = '22003';
  end if;

  select current_payment.* into payment
  from public.tournament_registration_payments as current_payment
  where current_payment.id = p_source_payment_id
  for update;

  if payment.id is null or payment.status <> 'verified'
    or payment.registration_id <> registration.id
    or payment.tournament_id <> registration.tournament_id
    or payment.team_id <> registration.team_id then
    raise exception 'Paid entry requires the matching verified source payment.'
      using errcode = '22023';
  end if;
  if payment.currency <> required_currency then
    raise exception 'Source payment currency must match the authoritative participation currency.'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('financial-stage:' || stage.id::text, 0)
  );
  if scope = 'session' then
    perform pg_advisory_xact_lock(
      hashtextextended('financial-session:' || session.id::text, 0)
    );
  end if;

  if scope = 'session' then
    select paid_entry.* into existing
    from public.tournament_registration_paid_entries as paid_entry
    where paid_entry.registration_id = registration.id
      and paid_entry.session_id = session.id
      and paid_entry.entry_scope = 'session'
      and not paid_entry.is_legacy_session_proxy;
  else
    select paid_entry.* into existing
    from public.tournament_registration_paid_entries as paid_entry
    where paid_entry.registration_id = registration.id
      and paid_entry.stage_id = stage.id
      and paid_entry.entry_scope = 'stage';
  end if;

  if existing.id is not null then
    if existing.source_payment_id = payment.id
      and existing.amount_minor::bigint = required_amount
      and existing.currency = required_currency then
      return existing;
    end if;
    raise exception 'This registration already has preserved paid history for the selected scope.'
      using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.tournament_matches as match
    join public.tournament_lobbies as lobby on lobby.id = match.lobby_id
    where match.stage_id = stage.id
      and (scope = 'stage' or lobby.session_id = session.id)
      and match.status in ('live', 'completed')
  ) then
    raise exception 'A paid entry cannot be added after its Stage or Session has begun.'
      using errcode = '22023';
  end if;

  select coalesce(sum(paid_entry.amount_minor), 0)::bigint into allocated
  from public.tournament_registration_paid_entries as paid_entry
  where paid_entry.source_payment_id = payment.id;

  if payment.expected_amount_minor::bigint - allocated < required_amount then
    raise exception 'Verified source payment has insufficient unallocated value for the exact authoritative fee.'
      using errcode = '22023';
  end if;

  insert into public.tournament_registration_paid_entries (
    registration_id, tournament_id, team_id, stage_id, session_id, lobby_id,
    entry_scope, source_payment_id, amount_minor, currency, created_by
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    stage.id, session.id, p_lobby_id, scope, payment.id,
    required_amount::integer, required_currency, auth.uid()
  ) returning * into created;

  return created;
end;
$$;

-- Enforce the authoritative Session value even for any future trusted database
-- writer that does not call the allocation RPC directly.
create or replace function public.levelledup_validate_paid_entry_session_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  session public.tournament_stage_sessions;
begin
  if new.entry_scope = 'stage' then
    if new.session_id is not null or new.lobby_id is not null then
      raise exception 'A Stage paid entry cannot identify a Session or Lobby.'
        using errcode = '22023';
    end if;
  elsif new.entry_scope = 'session' then
    select current_session.* into session
    from public.tournament_stage_sessions as current_session
    where current_session.id = new.session_id
      and current_session.stage_id = new.stage_id
      and current_session.tournament_id = new.tournament_id;

    if session.id is null then
      raise exception 'A Session paid entry requires its exact Session in the same Stage and Tournament.'
        using errcode = '23503';
    end if;
    if new.amount_minor::bigint <> session.entry_fee_minor
      or new.currency <> session.fee_currency then
      raise exception 'A Session paid entry must equal its authoritative Session fee and currency.'
        using errcode = '22023';
    end if;
    if new.lobby_id is not null and not exists (
      select 1 from public.tournament_lobbies as lobby
      where lobby.id = new.lobby_id
        and lobby.session_id = session.id
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

-- Source validation also fixes the financial contract of preserved/new Session
-- Entries to their immutable payment or credit evidence.
create or replace function public.levelledup_validate_session_entry_source()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  session public.tournament_stage_sessions;
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

  select current_session.* into session
  from public.tournament_stage_sessions as current_session
  where current_session.id = new.session_id;

  if registration.id is null or session.id is null
    or registration.tournament_id <> new.tournament_id
    or registration.team_id <> new.team_id
    or session.tournament_id <> new.tournament_id
    or session.stage_id <> new.stage_id then
    raise exception 'Session Entry parents must share the same Tournament, Stage, Session and registration/team.'
      using errcode = '23503';
  end if;

  select team.* into selected_team from public.teams as team where team.id = new.team_id;
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
    or session.status not in ('planned', 'open') then
    raise exception 'A new Session Entry requires an active eligible team, confirmed Squad, and a future permitted Session.'
      using errcode = 'P4417';
  end if;

  if exists (
    select 1
    from public.tournament_registration_roster as squad
    left join public.team_roster_members as current_member
      on current_member.id = squad.source_roster_member_id
    where squad.registration_id = registration.id
      and squad.revision_number = registration.roster_revision
      and (current_member.id is null or current_member.status <> 'active')
  ) then
    raise exception 'The current Tournament Squad contains a player who is no longer eligible for a future Session Entry.'
      using errcode = 'P4418';
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
      or paid_entry.amount_minor::bigint <> session.entry_fee_minor
      or paid_entry.currency <> session.fee_currency then
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
      or credit_debit.amount_delta_minor <> -session.entry_fee_minor
      or credit_debit.currency <> session.fee_currency
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
  else
    new.source_occurred_at := coalesce(new.source_occurred_at, now());
  end if;

  return new;
end;
$$;

-- Remove the amount-bearing credit Entry RPC. The Session fee is the only debit
-- amount accepted by the replacement operation.
drop function public.levelledup_admin_create_session_entry(
  uuid, uuid, text, uuid, uuid, uuid, bigint, text, uuid, jsonb
);

create function public.levelledup_admin_create_session_entry(
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

  if normalized_source not in ('paid', 'earned', 'credit', 'admin_grant')
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
    or (normalized_source = 'admin_grant' and (
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
      raise exception 'A zero-fee Session must not create a credit debit; use an earned or Admin-granted Entry.'
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

alter table public.tournament_session_price_events enable row level security;
revoke all on table public.tournament_session_price_events
  from public, anon, authenticated;
grant select on table public.tournament_session_price_events to authenticated;
create policy tournament_session_price_events_admin_read
  on public.tournament_session_price_events
  for select to authenticated
  using (public.levelledup_has_admin_role('admin'));

-- Existing Session row policy still applies. Extend only the existing
-- column-level read grant; no browser write privilege is introduced.
grant select(entry_fee_minor, fee_currency)
  on public.tournament_stage_sessions to authenticated;

alter function public.levelledup_preserve_session_price_events() owner to postgres;
alter function public.levelledup_record_initial_session_price() owner to postgres;
alter function public.levelledup_guard_session_price_change() owner to postgres;
alter function public.levelledup_admin_set_session_price(uuid, bigint, text, text, uuid) owner to postgres;
alter function public.levelledup_admin_create_tournament_session(uuid, text, timestamptz, timestamptz) owner to postgres;
alter function public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, uuid, uuid) owner to postgres;
alter function public.levelledup_validate_session_entry_source() owner to postgres;
alter function public.levelledup_admin_create_session_entry(uuid, uuid, text, uuid, uuid, uuid, text, uuid, jsonb) owner to postgres;

revoke all on function public.levelledup_preserve_session_price_events(),
  public.levelledup_record_initial_session_price(),
  public.levelledup_guard_session_price_change(),
  public.levelledup_admin_set_session_price(uuid, bigint, text, text, uuid),
  public.levelledup_admin_create_tournament_session(uuid, text, timestamptz, timestamptz),
  public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, uuid, uuid),
  public.levelledup_validate_session_entry_source(),
  public.levelledup_admin_create_session_entry(uuid, uuid, text, uuid, uuid, uuid, text, uuid, jsonb)
  from public, anon, authenticated;

grant execute on function
  public.levelledup_admin_set_session_price(uuid, bigint, text, text, uuid),
  public.levelledup_admin_create_tournament_session(uuid, text, timestamptz, timestamptz),
  public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, uuid, uuid),
  public.levelledup_admin_create_session_entry(uuid, uuid, text, uuid, uuid, uuid, text, uuid, jsonb)
  to authenticated;

comment on function public.levelledup_admin_set_session_price(uuid, bigint, text, text, uuid) is
  'Tournament Admin/Super Admin-only audited Session price change. Permanently blocked after any participation or financial history exists.';
comment on function public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, uuid, uuid) is
  'Admin-only exact allocation from a verified payment. Session allocations derive amount/currency exclusively from the Session contract; Stage allocations derive them from the Stage template.';
comment on function public.levelledup_admin_create_session_entry(uuid, uuid, text, uuid, uuid, uuid, text, uuid, jsonb) is
  'Admin-only idempotent exact Session participation creation. Credit debits derive exclusively from the Session contract and roll back atomically if Entry creation fails.';

-- Deployment assertions: financial history remains exact, the replacement
-- amount-bearing RPCs are gone, and browser roles have no direct write path.
do $$
begin
  if (
    select count(*)
    from public.tournament_session_price_events as event
    where event.event_type = 'initialized'
  ) <> (
    select count(*) from public.tournament_stage_sessions
  ) then
    raise exception 'Session price baseline history validation failed.';
  end if;

  if exists (
    select 1
    from public.tournament_stage_sessions as session
    where session.entry_fee_minor < 0
      or session.fee_currency !~ '^[A-Z]{3}$'
      or session.fee_currency <> upper(session.fee_currency)
  ) then
    raise exception 'Session price validation failed.';
  end if;

  if exists (
    select 1
    from public.tournament_registration_paid_entries as paid_entry
    join public.tournament_stage_sessions as session
      on session.id = paid_entry.session_id
    where paid_entry.entry_scope = 'session'
      and (
        paid_entry.stage_id <> session.stage_id
        or paid_entry.tournament_id <> session.tournament_id
        or paid_entry.amount_minor::bigint <> session.entry_fee_minor
        or paid_entry.currency <> session.fee_currency
      )
  ) then
    raise exception 'Paid Session financial linkage validation failed.';
  end if;

  if exists (
    select 1
    from public.tournament_session_entries as session_entry
    join public.tournament_stage_sessions as session
      on session.id = session_entry.session_id
    join public.levelledup_credit_ledger_entries as debit
      on debit.id = session_entry.source_credit_ledger_entry_id
    where session_entry.source_type = 'credit'
      and (
        session_entry.stage_id <> session.stage_id
        or session_entry.tournament_id <> session.tournament_id
        or debit.amount_delta_minor <> -session.entry_fee_minor
        or debit.currency <> session.fee_currency
      )
  ) then
    raise exception 'Credit Session financial linkage validation failed.';
  end if;

  if has_table_privilege('anon', 'public.tournament_stage_sessions', 'INSERT')
    or has_table_privilege('anon', 'public.tournament_stage_sessions', 'UPDATE')
    or has_table_privilege('authenticated', 'public.tournament_stage_sessions', 'INSERT')
    or has_table_privilege('authenticated', 'public.tournament_stage_sessions', 'UPDATE')
    or has_table_privilege('anon', 'public.tournament_session_price_events', 'INSERT')
    or has_table_privilege('authenticated', 'public.tournament_session_price_events', 'INSERT') then
    raise exception 'Browser direct-write denial validation failed.';
  end if;

  if has_function_privilege(
      'anon',
      'public.levelledup_admin_set_session_price(uuid,bigint,text,text,uuid)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.levelledup_admin_create_stage_paid_entry(uuid,uuid,text,uuid,uuid,uuid)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.levelledup_admin_create_session_entry(uuid,uuid,text,uuid,uuid,uuid,text,uuid,jsonb)',
      'EXECUTE'
    ) then
    raise exception 'Anonymous trusted-RPC denial validation failed.';
  end if;

  if to_regprocedure(
      'public.levelledup_admin_create_stage_paid_entry(uuid,uuid,text,uuid,integer,uuid,uuid)'
    ) is not null
    or to_regprocedure(
      'public.levelledup_admin_create_session_entry(uuid,uuid,text,uuid,uuid,uuid,bigint,text,uuid,jsonb)'
    ) is not null then
    raise exception 'Caller-controlled financial RPC signature removal validation failed.';
  end if;

  if to_regprocedure(
      'public.levelledup_admin_create_stage_paid_entry(uuid,uuid,text,uuid,uuid,uuid)'
    ) is null
    or to_regprocedure(
      'public.levelledup_admin_create_session_entry(uuid,uuid,text,uuid,uuid,uuid,text,uuid,jsonb)'
    ) is null
    or to_regprocedure(
      'public.levelledup_admin_set_session_price(uuid,bigint,text,text,uuid)'
    ) is null then
    raise exception 'Authoritative Session financial RPC installation validation failed.';
  end if;
end;
$$;

commit;
