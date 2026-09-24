begin;

create table public.levelledup_credit_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null
    references public.profiles (id) on delete restrict,
  operational_team_id uuid not null
    references public.teams (id) on delete restrict,
  registration_id uuid not null,
  tournament_id uuid not null,
  stage_id uuid,
  lobby_id uuid,
  source_payment_id uuid not null
    references public.tournament_registration_payments (id) on delete restrict,
  legacy_tournament_credit_id uuid
    references public.tournament_team_credits (id) on delete restrict,
  stage_credit_entitlement_id uuid
    references public.tournament_stage_credit_entitlements (id) on delete restrict,
  related_entry_id uuid
    references public.levelledup_credit_ledger_entries (id) on delete restrict,
  event_type text not null,
  amount_delta_minor bigint not null,
  currency text not null,
  reason text not null,
  idempotency_key text not null,
  actor_user_id uuid not null references auth.users (id) on delete restrict,
  actor_role text not null,
  provenance jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint levelledup_credit_ledger_registration_fk
    foreign key (registration_id, tournament_id, operational_team_id)
    references public.tournament_registrations (id, tournament_id, team_id)
    on delete restrict,
  constraint levelledup_credit_ledger_stage_fk
    foreign key (stage_id, tournament_id)
    references public.tournament_stages (id, tournament_id)
    on delete restrict,
  constraint levelledup_credit_ledger_lobby_fk
    foreign key (lobby_id, stage_id, tournament_id)
    references public.tournament_lobbies (id, stage_id, tournament_id)
    on delete restrict,
  constraint levelledup_credit_ledger_source_exactly_one check (
    num_nonnulls(legacy_tournament_credit_id, stage_credit_entitlement_id) = 1
  ),
  constraint levelledup_credit_ledger_event_valid check (
    event_type in ('grant', 'apply', 'cash_refund', 'reversal')
  ),
  constraint levelledup_credit_ledger_amount_direction check (
    (event_type in ('grant', 'reversal') and amount_delta_minor > 0)
    or (event_type in ('apply', 'cash_refund') and amount_delta_minor < 0)
  ),
  constraint levelledup_credit_ledger_relationship_valid check (
    (event_type = 'grant' and related_entry_id is null)
    or (event_type <> 'grant' and related_entry_id is not null)
  ),
  constraint levelledup_credit_ledger_currency_valid check (
    currency = upper(currency) and currency ~ '^[A-Z]{3}$'
  ),
  constraint levelledup_credit_ledger_reason_valid check (
    reason = btrim(reason) and char_length(reason) between 3 and 500
  ),
  constraint levelledup_credit_ledger_idempotency_valid check (
    idempotency_key = lower(btrim(idempotency_key))
    and char_length(idempotency_key) between 8 and 200
    and idempotency_key ~ '^[a-z0-9:_-]+$'
  ),
  constraint levelledup_credit_ledger_actor_role_valid check (
    actor_role in ('system', 'payer', 'team_captain', 'admin', 'super_admin')
  ),
  constraint levelledup_credit_ledger_provenance_object check (
    jsonb_typeof(provenance) = 'object'
  ),
  constraint levelledup_credit_ledger_idempotency_unique unique (idempotency_key)
);

create index levelledup_credit_ledger_owner_balance_idx
  on public.levelledup_credit_ledger_entries (owner_profile_id, currency, created_at);
create index levelledup_credit_ledger_team_history_idx
  on public.levelledup_credit_ledger_entries (operational_team_id, created_at desc);
create index levelledup_credit_ledger_payment_history_idx
  on public.levelledup_credit_ledger_entries (source_payment_id, created_at);
create index levelledup_credit_ledger_related_entry_idx
  on public.levelledup_credit_ledger_entries (related_entry_id)
  where related_entry_id is not null;

comment on table public.levelledup_credit_ledger_entries is
  'Immutable profile-owned credit journal. Balances are sums of ledger deltas; source teams are operational context and never own the money.';
comment on column public.levelledup_credit_ledger_entries.owner_profile_id is
  'Immutable verified payer identity, derived from tournament_registration_payments.submitted_by.';
comment on column public.levelledup_credit_ledger_entries.operational_team_id is
  'Team for which the payment was made. Captaincy changes never alter ledger ownership.';
comment on column public.levelledup_credit_ledger_entries.idempotency_key is
  'Stable action key used to make grants, applications, refunds and reversals retry-safe.';

create function public.levelledup_guard_credit_ledger_append_only()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'Credit ledger entries are append-only and cannot be changed or deleted.'
    using errcode = '22023';
end;
$$;

alter function public.levelledup_guard_credit_ledger_append_only() owner to postgres;
revoke all on function public.levelledup_guard_credit_ledger_append_only()
  from public, anon, authenticated;

create trigger levelledup_credit_ledger_append_only
before update or delete on public.levelledup_credit_ledger_entries
for each row execute function public.levelledup_guard_credit_ledger_append_only();

create function public.levelledup_validate_credit_ledger_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_payment public.tournament_registration_payments;
  legacy_credit public.tournament_team_credits;
  stage_credit public.tournament_stage_credit_entitlements;
  stage_refund_case public.tournament_stage_refund_cases;
  related_entry public.levelledup_credit_ledger_entries;
begin
  select payments.* into selected_payment
  from public.tournament_registration_payments as payments
  where payments.id = new.source_payment_id;

  if selected_payment.id is null or selected_payment.status <> 'verified'
    or selected_payment.submitted_by <> new.owner_profile_id
    or selected_payment.registration_id <> new.registration_id
    or selected_payment.tournament_id <> new.tournament_id
    or selected_payment.team_id <> new.operational_team_id
    or selected_payment.currency <> new.currency then
    raise exception 'Credit ledger identity must match its verified payer and source payment.'
      using errcode = '22023';
  end if;

  if new.legacy_tournament_credit_id is not null then
    select credits.* into legacy_credit
    from public.tournament_team_credits as credits
    where credits.id = new.legacy_tournament_credit_id;

    if legacy_credit.id is null
      or legacy_credit.source_payment_id <> new.source_payment_id
      or legacy_credit.registration_id <> new.registration_id
      or legacy_credit.tournament_id <> new.tournament_id
      or legacy_credit.team_id <> new.operational_team_id
      or legacy_credit.currency <> new.currency
      or new.stage_id is not null
      or new.lobby_id is not null
      or (new.event_type = 'grant' and new.amount_delta_minor <> legacy_credit.amount_minor) then
      raise exception 'Ledger row does not match its legacy tournament credit.'
        using errcode = '22023';
    end if;
  else
    select credits.* into stage_credit
    from public.tournament_stage_credit_entitlements as credits
    where credits.id = new.stage_credit_entitlement_id;
    select cases.* into stage_refund_case
    from public.tournament_stage_refund_cases as cases
    where cases.id = stage_credit.refund_case_id;

    if stage_credit.id is null or stage_refund_case.id is null
      or stage_credit.source_payment_id <> new.source_payment_id
      or stage_credit.registration_id <> new.registration_id
      or stage_credit.tournament_id <> new.tournament_id
      or stage_credit.team_id <> new.operational_team_id
      or stage_credit.currency <> new.currency
      or stage_refund_case.stage_id is distinct from new.stage_id
      or stage_refund_case.lobby_id is distinct from new.lobby_id
      or (new.event_type = 'grant' and new.amount_delta_minor <> stage_credit.amount_minor) then
      raise exception 'Ledger row does not match its stage/session credit entitlement.'
        using errcode = '22023';
    end if;
  end if;

  if new.event_type <> 'grant' then
    select entries.* into related_entry
    from public.levelledup_credit_ledger_entries as entries
    where entries.id = new.related_entry_id;

    if related_entry.id is null
      or related_entry.owner_profile_id <> new.owner_profile_id
      or related_entry.operational_team_id <> new.operational_team_id
      or related_entry.registration_id <> new.registration_id
      or related_entry.tournament_id <> new.tournament_id
      or related_entry.stage_id is distinct from new.stage_id
      or related_entry.lobby_id is distinct from new.lobby_id
      or related_entry.source_payment_id <> new.source_payment_id
      or related_entry.legacy_tournament_credit_id is distinct from new.legacy_tournament_credit_id
      or related_entry.stage_credit_entitlement_id is distinct from new.stage_credit_entitlement_id
      or related_entry.currency <> new.currency
      or (new.event_type in ('apply', 'cash_refund') and related_entry.event_type <> 'grant')
      or (new.event_type = 'reversal' and related_entry.event_type not in ('apply', 'cash_refund')) then
      raise exception 'Ledger action must preserve the identity of its related credit entry.'
        using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;

alter function public.levelledup_validate_credit_ledger_entry() owner to postgres;
revoke all on function public.levelledup_validate_credit_ledger_entry()
  from public, anon, authenticated;

create trigger levelledup_credit_ledger_validate
before insert on public.levelledup_credit_ledger_entries
for each row execute function public.levelledup_validate_credit_ledger_entry();

create function public.levelledup_record_legacy_credit_grant(
  p_credit_id uuid
)
returns public.levelledup_credit_ledger_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_credit public.tournament_team_credits;
  selected_payment public.tournament_registration_payments;
  selected_actor_role text;
  ledger_entry public.levelledup_credit_ledger_entries;
  stable_key text;
begin
  select credits.* into selected_credit
  from public.tournament_team_credits as credits
  where credits.id = p_credit_id;

  if selected_credit.id is null then
    raise exception 'Legacy tournament credit not found.' using errcode = '22023';
  end if;

  select payments.* into selected_payment
  from public.tournament_registration_payments as payments
  where payments.id = selected_credit.source_payment_id;

  if selected_payment.id is null or selected_payment.status <> 'verified'
    or selected_payment.registration_id <> selected_credit.registration_id
    or selected_payment.tournament_id <> selected_credit.tournament_id
    or selected_payment.team_id <> selected_credit.team_id then
    raise exception 'Legacy credit source payment is invalid.' using errcode = '22023';
  end if;

  select admins.role into selected_actor_role
  from public.admin_users as admins
  where admins.user_id = selected_credit.created_by;
  selected_actor_role := coalesce(selected_actor_role, 'system');
  stable_key := 'legacy-credit:' || selected_credit.id::text || ':grant';

  insert into public.levelledup_credit_ledger_entries (
    owner_profile_id, operational_team_id, registration_id, tournament_id,
    source_payment_id, legacy_tournament_credit_id, event_type,
    amount_delta_minor, currency, reason, idempotency_key,
    actor_user_id, actor_role, provenance, created_at
  ) values (
    selected_payment.submitted_by, selected_credit.team_id,
    selected_credit.registration_id, selected_credit.tournament_id,
    selected_credit.source_payment_id, selected_credit.id, 'grant',
    selected_credit.amount_minor, selected_credit.currency,
    'Tournament cancellation credit granted', stable_key,
    selected_credit.created_by, selected_actor_role,
    jsonb_build_object('source', 'tournament_team_credits'),
    selected_credit.created_at
  )
  on conflict (idempotency_key) do nothing
  returning * into ledger_entry;

  if ledger_entry.id is null then
    select entries.* into ledger_entry
    from public.levelledup_credit_ledger_entries as entries
    where entries.idempotency_key = stable_key;
  end if;

  return ledger_entry;
end;
$$;

create function public.levelledup_record_stage_credit_grant(
  p_entitlement_id uuid
)
returns public.levelledup_credit_ledger_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_credit public.tournament_stage_credit_entitlements;
  selected_case public.tournament_stage_refund_cases;
  selected_payment public.tournament_registration_payments;
  selected_actor_role text;
  ledger_entry public.levelledup_credit_ledger_entries;
  stable_key text;
begin
  select credits.* into selected_credit
  from public.tournament_stage_credit_entitlements as credits
  where credits.id = p_entitlement_id;
  if selected_credit.id is null then
    raise exception 'Stage/session credit entitlement not found.' using errcode = '22023';
  end if;

  select cases.* into selected_case
  from public.tournament_stage_refund_cases as cases
  where cases.id = selected_credit.refund_case_id;
  select payments.* into selected_payment
  from public.tournament_registration_payments as payments
  where payments.id = selected_credit.source_payment_id;

  if selected_case.id is null or selected_payment.id is null
    or selected_payment.status <> 'verified'
    or selected_payment.registration_id <> selected_credit.registration_id
    or selected_payment.tournament_id <> selected_credit.tournament_id
    or selected_payment.team_id <> selected_credit.team_id
    or selected_case.paid_entry_id <> selected_credit.paid_entry_id then
    raise exception 'Stage/session credit source is invalid.' using errcode = '22023';
  end if;

  select admins.role into selected_actor_role
  from public.admin_users as admins
  where admins.user_id = selected_credit.created_by;
  selected_actor_role := coalesce(selected_actor_role, 'system');
  stable_key := 'stage-credit:' || selected_credit.id::text || ':grant';

  insert into public.levelledup_credit_ledger_entries (
    owner_profile_id, operational_team_id, registration_id, tournament_id,
    stage_id, lobby_id, source_payment_id, stage_credit_entitlement_id,
    event_type, amount_delta_minor, currency, reason, idempotency_key,
    actor_user_id, actor_role, provenance, created_at
  ) values (
    selected_payment.submitted_by, selected_credit.team_id,
    selected_credit.registration_id, selected_credit.tournament_id,
    selected_case.stage_id, selected_case.lobby_id, selected_credit.source_payment_id,
    selected_credit.id, 'grant', selected_credit.amount_minor,
    selected_credit.currency, selected_case.reason, stable_key,
    selected_credit.created_by, selected_actor_role,
    jsonb_build_object(
      'source', 'tournament_stage_credit_entitlements',
      'refund_case_id', selected_case.id,
      'processing_mode', selected_case.processing_mode
    ), selected_credit.created_at
  )
  on conflict (idempotency_key) do nothing
  returning * into ledger_entry;

  if ledger_entry.id is null then
    select entries.* into ledger_entry
    from public.levelledup_credit_ledger_entries as entries
    where entries.idempotency_key = stable_key;
  end if;

  return ledger_entry;
end;
$$;

create function public.levelledup_record_credit_terminal_event(
  p_legacy_credit_id uuid,
  p_stage_credit_entitlement_id uuid,
  p_terminal_status text,
  p_actor_user_id uuid,
  p_occurred_at timestamptz
)
returns public.levelledup_credit_ledger_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  grant_entry public.levelledup_credit_ledger_entries;
  selected_actor_role text;
  ledger_entry public.levelledup_credit_ledger_entries;
  normalized_status text := lower(btrim(coalesce(p_terminal_status, '')));
  stable_key text;
  available_minor bigint;
begin
  if num_nonnulls(p_legacy_credit_id, p_stage_credit_entitlement_id) <> 1
    or normalized_status not in ('used', 'refunded') then
    raise exception 'Invalid terminal credit event.' using errcode = '22023';
  end if;

  if p_legacy_credit_id is not null then
    grant_entry := public.levelledup_record_legacy_credit_grant(p_legacy_credit_id);
  else
    grant_entry := public.levelledup_record_stage_credit_grant(p_stage_credit_entitlement_id);
  end if;

  stable_key := grant_entry.idempotency_key || ':' || normalized_status;

  perform pg_advisory_xact_lock(
    hashtextextended('credit-grant:' || grant_entry.id::text, 0)
  );

  select entries.* into ledger_entry
  from public.levelledup_credit_ledger_entries as entries
  where entries.idempotency_key = stable_key;
  if ledger_entry.id is not null then
    return ledger_entry;
  end if;

  select coalesce(sum(entries.amount_delta_minor), 0) into available_minor
  from public.levelledup_credit_ledger_entries as entries
  where entries.id = grant_entry.id
    or entries.related_entry_id = grant_entry.id
    or entries.related_entry_id in (
      select debits.id
      from public.levelledup_credit_ledger_entries as debits
      where debits.related_entry_id = grant_entry.id
    );

  -- A legacy entitlement may be marked terminal after part of its value has
  -- already moved through the ledger. Consume only what remains.
  if available_minor <= 0 then
    return grant_entry;
  end if;

  select admins.role into selected_actor_role
  from public.admin_users as admins
  where admins.user_id = p_actor_user_id;
  selected_actor_role := coalesce(selected_actor_role, 'system');

  insert into public.levelledup_credit_ledger_entries (
    owner_profile_id, operational_team_id, registration_id, tournament_id,
    stage_id, lobby_id, source_payment_id, legacy_tournament_credit_id,
    stage_credit_entitlement_id, related_entry_id, event_type,
    amount_delta_minor, currency, reason, idempotency_key,
    actor_user_id, actor_role, provenance, created_at
  ) values (
    grant_entry.owner_profile_id, grant_entry.operational_team_id,
    grant_entry.registration_id, grant_entry.tournament_id,
    grant_entry.stage_id, grant_entry.lobby_id, grant_entry.source_payment_id,
    grant_entry.legacy_tournament_credit_id,
    grant_entry.stage_credit_entitlement_id, grant_entry.id,
    case when normalized_status = 'used' then 'apply' else 'cash_refund' end,
    -available_minor, grant_entry.currency,
    case when normalized_status = 'used'
      then 'Credit marked used by its source entitlement'
      else 'Credit marked refunded by its source entitlement' end,
    stable_key, p_actor_user_id, selected_actor_role,
    jsonb_build_object('source_status', normalized_status),
    coalesce(p_occurred_at, now())
  )
  on conflict (idempotency_key) do nothing
  returning * into ledger_entry;

  if ledger_entry.id is null then
    select entries.* into ledger_entry
    from public.levelledup_credit_ledger_entries as entries
    where entries.idempotency_key = stable_key;
  end if;

  return ledger_entry;
end;
$$;

alter function public.levelledup_record_legacy_credit_grant(uuid) owner to postgres;
alter function public.levelledup_record_stage_credit_grant(uuid) owner to postgres;
alter function public.levelledup_record_credit_terminal_event(uuid, uuid, text, uuid, timestamptz) owner to postgres;
revoke all on function public.levelledup_record_legacy_credit_grant(uuid) from public, anon, authenticated;
revoke all on function public.levelledup_record_stage_credit_grant(uuid) from public, anon, authenticated;
revoke all on function public.levelledup_record_credit_terminal_event(uuid, uuid, text, uuid, timestamptz) from public, anon, authenticated;

create function public.levelledup_sync_legacy_credit_ledger()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if tg_op = 'INSERT' then
    perform public.levelledup_record_legacy_credit_grant(new.id);
  elsif new.status is distinct from old.status and new.status in ('used', 'refunded') then
    perform public.levelledup_record_credit_terminal_event(
      new.id, null, new.status, new.status_updated_by, new.status_updated_at
    );
  end if;
  return new;
end;
$$;

create function public.levelledup_sync_stage_credit_ledger()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if tg_op = 'INSERT' then
    perform public.levelledup_record_stage_credit_grant(new.id);
  elsif new.status is distinct from old.status and new.status in ('used', 'refunded') then
    perform public.levelledup_record_credit_terminal_event(
      null, new.id, new.status, new.status_updated_by, new.status_updated_at
    );
  end if;
  return new;
end;
$$;

alter function public.levelledup_sync_legacy_credit_ledger() owner to postgres;
alter function public.levelledup_sync_stage_credit_ledger() owner to postgres;
revoke all on function public.levelledup_sync_legacy_credit_ledger() from public, anon, authenticated;
revoke all on function public.levelledup_sync_stage_credit_ledger() from public, anon, authenticated;

create trigger tournament_team_credits_sync_ledger
after insert or update of status on public.tournament_team_credits
for each row execute function public.levelledup_sync_legacy_credit_ledger();

create trigger tournament_stage_credit_entitlements_sync_ledger
after insert or update of status on public.tournament_stage_credit_entitlements
for each row execute function public.levelledup_sync_stage_credit_ledger();

-- Adopt all existing entitlements without changing them. The deterministic
-- idempotency keys make the backfill safe if its statements are retried.
do $$
declare
  existing_credit record;
begin
  for existing_credit in
    select credits.id, credits.status, credits.status_updated_by, credits.status_updated_at
    from public.tournament_team_credits as credits
    order by credits.created_at, credits.id
  loop
    perform public.levelledup_record_legacy_credit_grant(existing_credit.id);
    if existing_credit.status in ('used', 'refunded') then
      perform public.levelledup_record_credit_terminal_event(
        existing_credit.id, null, existing_credit.status,
        existing_credit.status_updated_by, existing_credit.status_updated_at
      );
    end if;
  end loop;

  for existing_credit in
    select credits.id, credits.status, credits.status_updated_by, credits.status_updated_at
    from public.tournament_stage_credit_entitlements as credits
    order by credits.created_at, credits.id
  loop
    perform public.levelledup_record_stage_credit_grant(existing_credit.id);
    if existing_credit.status in ('used', 'refunded') then
      perform public.levelledup_record_credit_terminal_event(
        null, existing_credit.id, existing_credit.status,
        existing_credit.status_updated_by, existing_credit.status_updated_at
      );
    end if;
  end loop;
end;
$$;

create function public.levelledup_admin_record_credit_debit(
  p_grant_entry_id uuid,
  p_action text,
  p_amount_minor bigint,
  p_reason text,
  p_idempotency_key text
)
returns public.levelledup_credit_ledger_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  grant_entry public.levelledup_credit_ledger_entries;
  existing_entry public.levelledup_credit_ledger_entries;
  created_entry public.levelledup_credit_ledger_entries;
  normalized_action text := lower(btrim(coalesce(p_action, '')));
  normalized_reason text := btrim(coalesce(p_reason, ''));
  normalized_key text := lower(btrim(coalesce(p_idempotency_key, '')));
  available_minor bigint;
  current_admin_role text;
begin
  perform public.levelledup_require_admin('admin');

  if normalized_action not in ('apply', 'cash_refund') then
    raise exception 'Credit action must be apply or cash_refund.' using errcode = '22023';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'Credit action amount must be positive.' using errcode = '22023';
  end if;
  if char_length(normalized_reason) not between 3 and 500 then
    raise exception 'Credit action requires a reason between 3 and 500 characters.' using errcode = '22023';
  end if;
  if normalized_key !~ '^[a-z0-9:_-]{8,200}$' then
    raise exception 'Provide a stable credit action idempotency key.' using errcode = '22023';
  end if;

  select entries.* into existing_entry
  from public.levelledup_credit_ledger_entries as entries
  where entries.idempotency_key = normalized_key;
  if existing_entry.id is not null then
    if existing_entry.related_entry_id <> p_grant_entry_id
      or existing_entry.event_type <> normalized_action
      or existing_entry.amount_delta_minor <> -p_amount_minor
      or existing_entry.reason <> normalized_reason then
      raise exception 'Idempotency key is already used by a different credit action.' using errcode = '23505';
    end if;
    return existing_entry;
  end if;

  select entries.* into grant_entry
  from public.levelledup_credit_ledger_entries as entries
  where entries.id = p_grant_entry_id and entries.event_type = 'grant';
  if grant_entry.id is null then
    raise exception 'Credit grant not found.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('credit-grant:' || grant_entry.id::text, 0)
  );

  select entries.* into existing_entry
  from public.levelledup_credit_ledger_entries as entries
  where entries.idempotency_key = normalized_key;
  if existing_entry.id is not null then
    if existing_entry.related_entry_id <> p_grant_entry_id
      or existing_entry.event_type <> normalized_action
      or existing_entry.amount_delta_minor <> -p_amount_minor
      or existing_entry.reason <> normalized_reason then
      raise exception 'Idempotency key is already used by a different credit action.' using errcode = '23505';
    end if;
    return existing_entry;
  end if;

  select coalesce(sum(entries.amount_delta_minor), 0) into available_minor
  from public.levelledup_credit_ledger_entries as entries
  where entries.id = grant_entry.id
    or entries.related_entry_id = grant_entry.id
    or entries.related_entry_id in (
      select debits.id
      from public.levelledup_credit_ledger_entries as debits
      where debits.related_entry_id = grant_entry.id
    );

  if available_minor < p_amount_minor then
    raise exception 'Credit grant has insufficient available value.' using errcode = '22023';
  end if;

  current_admin_role := public.levelledup_current_admin_role();
  insert into public.levelledup_credit_ledger_entries (
    owner_profile_id, operational_team_id, registration_id, tournament_id,
    stage_id, lobby_id, source_payment_id, legacy_tournament_credit_id,
    stage_credit_entitlement_id, related_entry_id, event_type,
    amount_delta_minor, currency, reason, idempotency_key,
    actor_user_id, actor_role, provenance
  ) values (
    grant_entry.owner_profile_id, grant_entry.operational_team_id,
    grant_entry.registration_id, grant_entry.tournament_id,
    grant_entry.stage_id, grant_entry.lobby_id, grant_entry.source_payment_id,
    grant_entry.legacy_tournament_credit_id,
    grant_entry.stage_credit_entitlement_id, grant_entry.id,
    normalized_action, -p_amount_minor, grant_entry.currency,
    normalized_reason, normalized_key, auth.uid(), current_admin_role,
    jsonb_build_object('grant_entry_id', grant_entry.id)
  ) returning * into created_entry;

  return created_entry;
end;
$$;

create function public.levelledup_admin_reverse_credit_entry(
  p_entry_id uuid,
  p_reason text,
  p_idempotency_key text
)
returns public.levelledup_credit_ledger_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_entry public.levelledup_credit_ledger_entries;
  existing_entry public.levelledup_credit_ledger_entries;
  created_entry public.levelledup_credit_ledger_entries;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  normalized_key text := lower(btrim(coalesce(p_idempotency_key, '')));
  current_admin_role text;
begin
  perform public.levelledup_require_admin('admin');
  if char_length(normalized_reason) not between 3 and 500 then
    raise exception 'Credit reversal requires a reason between 3 and 500 characters.' using errcode = '22023';
  end if;
  if normalized_key !~ '^[a-z0-9:_-]{8,200}$' then
    raise exception 'Provide a stable reversal idempotency key.' using errcode = '22023';
  end if;

  select entries.* into existing_entry
  from public.levelledup_credit_ledger_entries as entries
  where entries.idempotency_key = normalized_key;
  if existing_entry.id is not null then
    if existing_entry.event_type <> 'reversal'
      or existing_entry.related_entry_id <> p_entry_id
      or existing_entry.reason <> normalized_reason then
      raise exception 'Idempotency key is already used by a different credit action.' using errcode = '23505';
    end if;
    return existing_entry;
  end if;

  select entries.* into target_entry
  from public.levelledup_credit_ledger_entries as entries
  where entries.id = p_entry_id
    and entries.event_type in ('apply', 'cash_refund');
  if target_entry.id is null then
    raise exception 'Only an applied or refunded credit entry can be reversed.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('credit-grant:' || target_entry.related_entry_id::text, 0)
  );

  select entries.* into existing_entry
  from public.levelledup_credit_ledger_entries as entries
  where entries.idempotency_key = normalized_key;
  if existing_entry.id is not null then
    if existing_entry.event_type <> 'reversal'
      or existing_entry.related_entry_id <> p_entry_id
      or existing_entry.reason <> normalized_reason then
      raise exception 'Idempotency key is already used by a different credit action.' using errcode = '23505';
    end if;
    return existing_entry;
  end if;

  if exists (
    select 1 from public.levelledup_credit_ledger_entries as reversals
    where reversals.event_type = 'reversal'
      and reversals.related_entry_id = target_entry.id
  ) then
    raise exception 'This credit action has already been reversed.' using errcode = '22023';
  end if;

  current_admin_role := public.levelledup_current_admin_role();
  insert into public.levelledup_credit_ledger_entries (
    owner_profile_id, operational_team_id, registration_id, tournament_id,
    stage_id, lobby_id, source_payment_id, legacy_tournament_credit_id,
    stage_credit_entitlement_id, related_entry_id, event_type,
    amount_delta_minor, currency, reason, idempotency_key,
    actor_user_id, actor_role, provenance
  ) values (
    target_entry.owner_profile_id, target_entry.operational_team_id,
    target_entry.registration_id, target_entry.tournament_id,
    target_entry.stage_id, target_entry.lobby_id, target_entry.source_payment_id,
    target_entry.legacy_tournament_credit_id,
    target_entry.stage_credit_entitlement_id, target_entry.id,
    'reversal', -target_entry.amount_delta_minor, target_entry.currency,
    normalized_reason, normalized_key, auth.uid(), current_admin_role,
    jsonb_build_object('reversed_entry_id', target_entry.id)
  ) returning * into created_entry;

  return created_entry;
end;
$$;

alter function public.levelledup_admin_record_credit_debit(uuid, text, bigint, text, text) owner to postgres;
alter function public.levelledup_admin_reverse_credit_entry(uuid, text, text) owner to postgres;
revoke all on function public.levelledup_admin_record_credit_debit(uuid, text, bigint, text, text) from public, anon, authenticated;
revoke all on function public.levelledup_admin_reverse_credit_entry(uuid, text, text) from public, anon, authenticated;
grant execute on function public.levelledup_admin_record_credit_debit(uuid, text, bigint, text, text) to authenticated;
grant execute on function public.levelledup_admin_reverse_credit_entry(uuid, text, text) to authenticated;

create function public.levelledup_get_my_credit_balances()
returns table (currency text, balance_minor bigint)
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select entries.currency, sum(entries.amount_delta_minor)::bigint
  from public.levelledup_credit_ledger_entries as entries
  where entries.owner_profile_id = auth.uid()
  group by entries.currency
  having sum(entries.amount_delta_minor) <> 0
  order by entries.currency;
$$;

create function public.levelledup_get_team_credit_balances(p_team_id uuid)
returns table (currency text, balance_minor bigint)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
begin
  if auth.uid() is null or not public.levelledup_is_active_team_member(p_team_id) then
    raise exception 'Active team membership is required to view team credit.'
      using errcode = '42501';
  end if;

  return query
  select entries.currency, sum(entries.amount_delta_minor)::bigint
  from public.levelledup_credit_ledger_entries as entries
  join public.teams as teams on teams.id = entries.operational_team_id
  where entries.operational_team_id = p_team_id
    and teams.status = 'active'
  group by entries.currency
  having sum(entries.amount_delta_minor) <> 0
  order by entries.currency;
end;
$$;

alter function public.levelledup_get_my_credit_balances() owner to postgres;
alter function public.levelledup_get_team_credit_balances(uuid) owner to postgres;
revoke all on function public.levelledup_get_my_credit_balances() from public, anon, authenticated;
revoke all on function public.levelledup_get_team_credit_balances(uuid) from public, anon, authenticated;
grant execute on function public.levelledup_get_my_credit_balances() to authenticated;
grant execute on function public.levelledup_get_team_credit_balances(uuid) to authenticated;

alter table public.levelledup_credit_ledger_entries enable row level security;
revoke all on table public.levelledup_credit_ledger_entries from public, anon, authenticated;
grant select on table public.levelledup_credit_ledger_entries to authenticated;

create policy levelledup_credit_ledger_admin_read
on public.levelledup_credit_ledger_entries for select to authenticated
using (public.levelledup_has_admin_role('admin'));

-- Ownership is profile-based from the first grant. There is deliberately no
-- captaincy-driven or team-disband ownership mutation, and no general-purpose
-- owner-to-owner transfer RPC. A future transfer product must add a narrowly
-- scoped, paired ledger operation rather than updating these entries.

commit;
