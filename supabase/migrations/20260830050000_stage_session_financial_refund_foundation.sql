begin;

-- Financial behavior is database-owned and versioned. Manual review is the
-- deliberately safe bootstrap mode; changing the current mode never rewrites
-- the history row that governed an existing refund case.
create table public.levelledup_financial_settings (
  singleton boolean primary key default true,
  refund_mode text not null default 'manual',
  updated_by uuid references auth.users (id) on delete restrict,
  updated_at timestamptz not null default now(),
  constraint levelledup_financial_settings_singleton check (singleton),
  constraint levelledup_financial_settings_refund_mode check (
    refund_mode in ('automatic', 'manual')
  )
);

create table public.levelledup_refund_mode_history (
  id uuid primary key default gen_random_uuid(),
  refund_mode text not null,
  changed_by uuid references auth.users (id) on delete restrict,
  changed_at timestamptz not null default now(),
  constraint levelledup_refund_mode_history_mode check (
    refund_mode in ('automatic', 'manual')
  )
);

insert into public.levelledup_financial_settings (singleton, refund_mode)
values (true, 'manual');

insert into public.levelledup_refund_mode_history (refund_mode)
values ('manual');

comment on table public.levelledup_financial_settings is
  'Singleton database-owned financial configuration. V1 defaults refund processing to manual review.';
comment on table public.levelledup_refund_mode_history is
  'Append-only history of refund-mode changes. Existing refund cases retain their own processing-mode snapshot.';

create table public.tournament_registration_paid_entries (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null,
  tournament_id uuid not null,
  team_id uuid not null,
  stage_id uuid not null,
  lobby_id uuid,
  entry_scope text not null,
  source_payment_id uuid not null
    references public.tournament_registration_payments (id) on delete restrict,
  amount_minor integer not null,
  currency text not null,
  status text not null default 'paid',
  consumed_match_id uuid references public.tournament_matches (id) on delete restrict,
  consumed_at timestamptz,
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_registration_paid_entries_registration_fk
    foreign key (registration_id, tournament_id, team_id)
    references public.tournament_registrations (id, tournament_id, team_id)
    on delete restrict,
  constraint tournament_registration_paid_entries_stage_fk
    foreign key (stage_id, tournament_id)
    references public.tournament_stages (id, tournament_id)
    on delete restrict,
  constraint tournament_registration_paid_entries_lobby_fk
    foreign key (lobby_id, stage_id, tournament_id)
    references public.tournament_lobbies (id, stage_id, tournament_id)
    on delete restrict,
  constraint tournament_registration_paid_entries_scope_valid check (
    (entry_scope = 'stage' and lobby_id is null)
    or (entry_scope = 'session' and lobby_id is not null)
  ),
  constraint tournament_registration_paid_entries_amount_valid check (amount_minor > 0),
  constraint tournament_registration_paid_entries_currency_valid check (
    currency = upper(currency) and currency ~ '^[A-Z]{3}$'
  ),
  constraint tournament_registration_paid_entries_status_valid check (
    status in ('paid', 'refund_pending', 'consumed', 'credited', 'refunded')
  ),
  constraint tournament_registration_paid_entries_consumption_state check (
    (status = 'consumed' and consumed_match_id is not null and consumed_at is not null)
    or (status <> 'consumed' and consumed_match_id is null and consumed_at is null)
  )
);

create unique index tournament_paid_entries_stage_scope_unique
  on public.tournament_registration_paid_entries (registration_id, stage_id)
  where entry_scope = 'stage';
create unique index tournament_paid_entries_session_scope_unique
  on public.tournament_registration_paid_entries (registration_id, lobby_id)
  where entry_scope = 'session';
create index tournament_paid_entries_source_payment_idx
  on public.tournament_registration_paid_entries (source_payment_id);
create index tournament_paid_entries_stage_status_idx
  on public.tournament_registration_paid_entries (stage_id, lobby_id, status);

comment on table public.tournament_registration_paid_entries is
  'Paid access entitlement for one registration and one stage or lobby/session. The first live match consumes it irreversibly.';
comment on column public.tournament_registration_paid_entries.entry_scope is
  'stage consumes on the first live match anywhere in the stage; session consumes on the first live match in the selected lobby.';

create table public.tournament_stage_refund_cases (
  id uuid primary key default gen_random_uuid(),
  paid_entry_id uuid not null
    references public.tournament_registration_paid_entries (id) on delete restrict,
  registration_id uuid not null,
  tournament_id uuid not null,
  team_id uuid not null,
  stage_id uuid not null,
  lobby_id uuid,
  source_payment_id uuid not null
    references public.tournament_registration_payments (id) on delete restrict,
  amount_minor integer not null,
  currency text not null,
  processing_mode text not null,
  status text not null,
  reason text not null,
  created_by uuid not null references auth.users (id) on delete restrict,
  reviewed_by uuid references auth.users (id) on delete restrict,
  reviewed_at timestamptz,
  credit_issued_at timestamptz,
  refunded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_stage_refund_cases_registration_fk
    foreign key (registration_id, tournament_id, team_id)
    references public.tournament_registrations (id, tournament_id, team_id)
    on delete restrict,
  constraint tournament_stage_refund_cases_stage_fk
    foreign key (stage_id, tournament_id)
    references public.tournament_stages (id, tournament_id)
    on delete restrict,
  constraint tournament_stage_refund_cases_lobby_fk
    foreign key (lobby_id, stage_id, tournament_id)
    references public.tournament_lobbies (id, stage_id, tournament_id)
    on delete restrict,
  constraint tournament_stage_refund_cases_amount_valid check (amount_minor > 0),
  constraint tournament_stage_refund_cases_currency_valid check (
    currency = upper(currency) and currency ~ '^[A-Z]{3}$'
  ),
  constraint tournament_stage_refund_cases_mode_valid check (
    processing_mode in ('automatic', 'manual')
  ),
  constraint tournament_stage_refund_cases_status_valid check (
    status in ('pending_review', 'approved', 'credited', 'rejected', 'refunded')
  ),
  constraint tournament_stage_refund_cases_reason_valid check (
    reason = btrim(reason) and char_length(reason) between 3 and 500
  ),
  constraint tournament_stage_refund_cases_review_state check (
    (status = 'pending_review' and reviewed_by is null and reviewed_at is null)
    or (status in ('approved', 'credited', 'rejected', 'refunded')
      and reviewed_by is not null and reviewed_at is not null)
  ),
  constraint tournament_stage_refund_cases_credit_state check (
    (status = 'credited' and credit_issued_at is not null and refunded_at is null)
    or (status = 'refunded' and refunded_at is not null and credit_issued_at is null)
    or (status not in ('credited', 'refunded')
      and credit_issued_at is null and refunded_at is null)
  )
);

create unique index tournament_stage_refund_cases_one_active_idx
  on public.tournament_stage_refund_cases (paid_entry_id)
  where status <> 'rejected';
create index tournament_stage_refund_cases_queue_idx
  on public.tournament_stage_refund_cases (status, created_at);
create index tournament_stage_refund_cases_tournament_idx
  on public.tournament_stage_refund_cases (tournament_id, created_at desc);

create table public.tournament_stage_credit_entitlements (
  id uuid primary key default gen_random_uuid(),
  refund_case_id uuid not null unique
    references public.tournament_stage_refund_cases (id) on delete restrict,
  paid_entry_id uuid not null unique
    references public.tournament_registration_paid_entries (id) on delete restrict,
  registration_id uuid not null,
  tournament_id uuid not null,
  team_id uuid not null,
  source_payment_id uuid not null
    references public.tournament_registration_payments (id) on delete restrict,
  amount_minor integer not null,
  currency text not null,
  status text not null default 'available',
  created_by uuid not null references auth.users (id) on delete restrict,
  status_updated_by uuid not null references auth.users (id) on delete restrict,
  status_updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_stage_credit_entitlements_registration_fk
    foreign key (registration_id, tournament_id, team_id)
    references public.tournament_registrations (id, tournament_id, team_id)
    on delete restrict,
  constraint tournament_stage_credit_entitlements_amount_valid check (amount_minor > 0),
  constraint tournament_stage_credit_entitlements_currency_valid check (
    currency = upper(currency) and currency ~ '^[A-Z]{3}$'
  ),
  constraint tournament_stage_credit_entitlements_status_valid check (
    status in ('available', 'used', 'refunded')
  )
);

create index tournament_stage_credit_entitlements_team_idx
  on public.tournament_stage_credit_entitlements (team_id, created_at desc);
create index tournament_stage_credit_entitlements_tournament_idx
  on public.tournament_stage_credit_entitlements (tournament_id, status);

comment on table public.tournament_stage_refund_cases is
  'Permanent review and outcome record for one unused paid stage/session entry. processing_mode is captured at creation.';
comment on table public.tournament_stage_credit_entitlements is
  'Stage/session credit entitlements. Existing tournament_team_credits remain untouched legacy full-tournament credits.';

create function public.levelledup_financial_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

alter function public.levelledup_financial_updated_at() owner to postgres;
revoke all on function public.levelledup_financial_updated_at() from public, anon, authenticated;

create trigger tournament_paid_entries_updated_at
before update on public.tournament_registration_paid_entries
for each row execute function public.levelledup_financial_updated_at();
create trigger tournament_stage_refund_cases_updated_at
before update on public.tournament_stage_refund_cases
for each row execute function public.levelledup_financial_updated_at();
create trigger tournament_stage_credit_entitlements_updated_at
before update on public.tournament_stage_credit_entitlements
for each row execute function public.levelledup_financial_updated_at();

create function public.levelledup_guard_refund_mode_history()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'Refund-mode history is append-only.' using errcode = '22023';
end;
$$;

alter function public.levelledup_guard_refund_mode_history() owner to postgres;
revoke all on function public.levelledup_guard_refund_mode_history() from public, anon, authenticated;

create trigger levelledup_refund_mode_history_append_only
before update or delete on public.levelledup_refund_mode_history
for each row execute function public.levelledup_guard_refund_mode_history();

create function public.levelledup_guard_paid_entry_history()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Paid-entry history cannot be deleted.' using errcode = '22023';
  end if;

  if new.registration_id is distinct from old.registration_id
    or new.tournament_id is distinct from old.tournament_id
    or new.team_id is distinct from old.team_id
    or new.stage_id is distinct from old.stage_id
    or new.lobby_id is distinct from old.lobby_id
    or new.entry_scope is distinct from old.entry_scope
    or new.source_payment_id is distinct from old.source_payment_id
    or new.amount_minor is distinct from old.amount_minor
    or new.currency is distinct from old.currency
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at then
    raise exception 'Paid-entry identity and value are immutable.' using errcode = '22023';
  end if;

  if new.status is distinct from old.status and not (
    (old.status = 'paid' and new.status in ('refund_pending', 'consumed'))
    or (old.status = 'refund_pending' and new.status in ('paid', 'credited', 'refunded'))
  ) then
    raise exception 'Invalid paid-entry status transition.' using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_paid_entry_history() owner to postgres;
revoke all on function public.levelledup_guard_paid_entry_history() from public, anon, authenticated;

create trigger tournament_paid_entries_guard_history
before update or delete on public.tournament_registration_paid_entries
for each row execute function public.levelledup_guard_paid_entry_history();

create function public.levelledup_guard_refund_case_history()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Refund-case history cannot be deleted.' using errcode = '22023';
  end if;

  if new.paid_entry_id is distinct from old.paid_entry_id
    or new.registration_id is distinct from old.registration_id
    or new.tournament_id is distinct from old.tournament_id
    or new.team_id is distinct from old.team_id
    or new.stage_id is distinct from old.stage_id
    or new.lobby_id is distinct from old.lobby_id
    or new.source_payment_id is distinct from old.source_payment_id
    or new.amount_minor is distinct from old.amount_minor
    or new.currency is distinct from old.currency
    or new.processing_mode is distinct from old.processing_mode
    or new.reason is distinct from old.reason
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at then
    raise exception 'Refund-case source, value and mode are immutable.' using errcode = '22023';
  end if;

  if new.status is distinct from old.status and not (
    (old.status = 'pending_review' and new.status in ('approved', 'rejected'))
    or (old.status = 'approved' and new.status in ('credited', 'refunded'))
  ) then
    raise exception 'Invalid refund-case status transition.' using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_refund_case_history() owner to postgres;
revoke all on function public.levelledup_guard_refund_case_history() from public, anon, authenticated;

create trigger tournament_stage_refund_cases_guard_history
before update or delete on public.tournament_stage_refund_cases
for each row execute function public.levelledup_guard_refund_case_history();

create function public.levelledup_guard_stage_credit_history()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Stage credit history cannot be deleted.' using errcode = '22023';
  end if;

  if new.refund_case_id is distinct from old.refund_case_id
    or new.paid_entry_id is distinct from old.paid_entry_id
    or new.registration_id is distinct from old.registration_id
    or new.tournament_id is distinct from old.tournament_id
    or new.team_id is distinct from old.team_id
    or new.source_payment_id is distinct from old.source_payment_id
    or new.amount_minor is distinct from old.amount_minor
    or new.currency is distinct from old.currency
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at then
    raise exception 'Stage credit source and value are immutable.' using errcode = '22023';
  end if;

  if new.status is distinct from old.status and not (
    old.status = 'available' and new.status in ('used', 'refunded')
  ) then
    raise exception 'Invalid stage-credit status transition.' using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_stage_credit_history() owner to postgres;
revoke all on function public.levelledup_guard_stage_credit_history() from public, anon, authenticated;

create trigger tournament_stage_credit_entitlements_guard_history
before update or delete on public.tournament_stage_credit_entitlements
for each row execute function public.levelledup_guard_stage_credit_history();

create function public.levelledup_admin_get_refund_mode()
returns text
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_mode text;
begin
  perform public.levelledup_require_admin('admin');
  select settings.refund_mode into selected_mode
  from public.levelledup_financial_settings as settings
  where settings.singleton;
  return selected_mode;
end;
$$;

create function public.levelledup_admin_set_refund_mode(p_refund_mode text)
returns text
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_mode text := lower(btrim(coalesce(p_refund_mode, '')));
begin
  perform public.levelledup_require_admin('super_admin');

  if normalized_mode not in ('automatic', 'manual') then
    raise exception 'Refund mode must be automatic or manual.' using errcode = '22023';
  end if;

  update public.levelledup_financial_settings
  set refund_mode = normalized_mode, updated_by = auth.uid(), updated_at = now()
  where singleton;

  insert into public.levelledup_refund_mode_history (refund_mode, changed_by)
  values (normalized_mode, auth.uid());

  return normalized_mode;
end;
$$;

create function public.levelledup_admin_create_stage_paid_entry(
  p_registration_id uuid,
  p_stage_id uuid,
  p_entry_scope text,
  p_source_payment_id uuid,
  p_amount_minor integer,
  p_lobby_id uuid default null
)
returns public.tournament_registration_paid_entries
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_registration public.tournament_registrations;
  selected_stage public.tournament_stages;
  selected_payment public.tournament_registration_payments;
  normalized_scope text := lower(btrim(coalesce(p_entry_scope, '')));
  allocated_amount bigint;
  created_entry public.tournament_registration_paid_entries;
begin
  perform public.levelledup_require_admin('admin');

  if normalized_scope not in ('stage', 'session')
    or (normalized_scope = 'stage' and p_lobby_id is not null)
    or (normalized_scope = 'session' and p_lobby_id is null) then
    raise exception 'Select a valid stage or session paid-entry scope.' using errcode = '22023';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'Paid-entry amount must be positive.' using errcode = '22023';
  end if;

  select registrations.* into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id for update;
  select stages.* into selected_stage
  from public.tournament_stages as stages
  where stages.id = p_stage_id for share;
  select payments.* into selected_payment
  from public.tournament_registration_payments as payments
  where payments.id = p_source_payment_id for update;

  if selected_registration.id is null or selected_stage.id is null
    or selected_stage.tournament_id <> selected_registration.tournament_id then
    raise exception 'Registration and stage must belong to the same tournament.' using errcode = '22023';
  end if;
  if selected_payment.id is null or selected_payment.status <> 'verified'
    or selected_payment.registration_id <> selected_registration.id
    or selected_payment.tournament_id <> selected_registration.tournament_id
    or selected_payment.team_id <> selected_registration.team_id then
    raise exception 'Paid entry requires the matching verified source payment.' using errcode = '22023';
  end if;
  if normalized_scope = 'session' and not exists (
    select 1 from public.tournament_lobbies as lobbies
    where lobbies.id = p_lobby_id
      and lobbies.stage_id = selected_stage.id
      and lobbies.tournament_id = selected_registration.tournament_id
  ) then
    raise exception 'Session lobby does not belong to the selected stage.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('financial-stage:' || selected_stage.id::text, 0));
  if normalized_scope = 'session' then
    perform pg_advisory_xact_lock(hashtextextended('financial-session:' || p_lobby_id::text, 0));
  end if;

  if exists (
    select 1 from public.tournament_matches as matches
    where matches.stage_id = selected_stage.id
      and (normalized_scope = 'stage' or matches.lobby_id = p_lobby_id)
      and matches.status in ('live', 'completed')
  ) then
    raise exception 'A paid entry cannot be added after its stage/session has begun.' using errcode = '22023';
  end if;

  select coalesce(sum(entries.amount_minor), 0) into allocated_amount
  from public.tournament_registration_paid_entries as entries
  where entries.source_payment_id = selected_payment.id;
  if allocated_amount + p_amount_minor > selected_payment.expected_amount_minor then
    raise exception 'Paid-entry allocations exceed the verified source payment.' using errcode = '22023';
  end if;

  insert into public.tournament_registration_paid_entries (
    registration_id, tournament_id, team_id, stage_id, lobby_id, entry_scope,
    source_payment_id, amount_minor, currency, created_by
  ) values (
    selected_registration.id, selected_registration.tournament_id, selected_registration.team_id,
    selected_stage.id, p_lobby_id, normalized_scope, selected_payment.id,
    p_amount_minor, selected_payment.currency, auth.uid()
  ) returning * into created_entry;

  return created_entry;
end;
$$;

create function public.levelledup_issue_stage_refund_credit(p_refund_case_id uuid)
returns public.tournament_stage_credit_entitlements
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_case public.tournament_stage_refund_cases;
  selected_entry public.tournament_registration_paid_entries;
  created_credit public.tournament_stage_credit_entitlements;
begin
  perform public.levelledup_require_admin('admin');

  select cases.* into selected_case
  from public.tournament_stage_refund_cases as cases
  where cases.id = p_refund_case_id for update;
  if selected_case.id is null then
    raise exception 'Refund case not found.' using errcode = '22023';
  end if;

  select entries.* into selected_entry
  from public.tournament_registration_paid_entries as entries
  where entries.id = selected_case.paid_entry_id for update;

  select credits.* into created_credit
  from public.tournament_stage_credit_entitlements as credits
  where credits.refund_case_id = selected_case.id;
  if created_credit.id is not null then
    return created_credit;
  end if;

  if selected_case.status <> 'approved' or selected_entry.status <> 'refund_pending' then
    raise exception 'Only an approved unused paid entry can be credited.' using errcode = '22023';
  end if;

  insert into public.tournament_stage_credit_entitlements (
    refund_case_id, paid_entry_id, registration_id, tournament_id, team_id,
    source_payment_id, amount_minor, currency, created_by, status_updated_by
  ) values (
    selected_case.id, selected_case.paid_entry_id, selected_case.registration_id,
    selected_case.tournament_id, selected_case.team_id, selected_case.source_payment_id,
    selected_case.amount_minor, selected_case.currency, auth.uid(), auth.uid()
  ) returning * into created_credit;

  update public.tournament_registration_paid_entries
  set status = 'credited', updated_at = now()
  where id = selected_entry.id;
  update public.tournament_stage_refund_cases
  set status = 'credited', credit_issued_at = now(), updated_at = now()
  where id = selected_case.id;

  return created_credit;
end;
$$;

create function public.levelledup_admin_create_stage_refund_case(
  p_paid_entry_id uuid,
  p_reason text
)
returns public.tournament_stage_refund_cases
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_entry public.tournament_registration_paid_entries;
  selected_mode text;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  created_case public.tournament_stage_refund_cases;
begin
  perform public.levelledup_require_admin('admin');
  if char_length(normalized_reason) not between 3 and 500 then
    raise exception 'Provide a refund reason between 3 and 500 characters.' using errcode = '22023';
  end if;

  select entries.* into selected_entry
  from public.tournament_registration_paid_entries as entries
  where entries.id = p_paid_entry_id;
  if selected_entry.id is null or selected_entry.status <> 'paid' then
    raise exception 'Only an unused paid entry can enter refund processing.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('financial-stage:' || selected_entry.stage_id::text, 0));
  if selected_entry.entry_scope = 'session' then
    perform pg_advisory_xact_lock(hashtextextended('financial-session:' || selected_entry.lobby_id::text, 0));
  end if;

  -- Re-read under a row lock after the scope lock. This ordering matches the
  -- match-live trigger and prevents a row-lock/advisory-lock deadlock.
  select entries.* into selected_entry
  from public.tournament_registration_paid_entries as entries
  where entries.id = p_paid_entry_id for update;
  if selected_entry.id is null or selected_entry.status <> 'paid' then
    raise exception 'Only an unused paid entry can enter refund processing.' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.tournament_matches as matches
    where matches.stage_id = selected_entry.stage_id
      and (selected_entry.entry_scope = 'stage' or matches.lobby_id = selected_entry.lobby_id)
      and matches.status in ('live', 'completed')
  ) then
    raise exception 'Played stage/session entries cannot be refunded or credited.' using errcode = '22023';
  end if;

  select settings.refund_mode into selected_mode
  from public.levelledup_financial_settings as settings
  where settings.singleton for update;

  insert into public.tournament_stage_refund_cases (
    paid_entry_id, registration_id, tournament_id, team_id, stage_id, lobby_id,
    source_payment_id, amount_minor, currency, processing_mode, status, reason,
    created_by, reviewed_by, reviewed_at
  ) values (
    selected_entry.id, selected_entry.registration_id, selected_entry.tournament_id,
    selected_entry.team_id, selected_entry.stage_id, selected_entry.lobby_id,
    selected_entry.source_payment_id, selected_entry.amount_minor, selected_entry.currency,
    selected_mode, case when selected_mode = 'automatic' then 'approved' else 'pending_review' end,
    normalized_reason, auth.uid(),
    case when selected_mode = 'automatic' then auth.uid() else null end,
    case when selected_mode = 'automatic' then now() else null end
  ) returning * into created_case;

  update public.tournament_registration_paid_entries
  set status = 'refund_pending', updated_at = now()
  where id = selected_entry.id;

  if selected_mode = 'automatic' then
    perform public.levelledup_issue_stage_refund_credit(created_case.id);
    select cases.* into created_case
    from public.tournament_stage_refund_cases as cases
    where cases.id = created_case.id;
  end if;

  return created_case;
end;
$$;

create function public.levelledup_admin_review_stage_refund_case(
  p_refund_case_id uuid,
  p_decision text
)
returns public.tournament_stage_refund_cases
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_decision text := lower(btrim(coalesce(p_decision, '')));
  selected_case public.tournament_stage_refund_cases;
begin
  perform public.levelledup_require_admin('admin');
  if normalized_decision not in ('approve', 'reject') then
    raise exception 'Decision must be approve or reject.' using errcode = '22023';
  end if;

  select cases.* into selected_case
  from public.tournament_stage_refund_cases as cases
  where cases.id = p_refund_case_id for update;
  if selected_case.id is null or selected_case.status <> 'pending_review' then
    raise exception 'Refund case is no longer pending review.' using errcode = '22023';
  end if;

  if normalized_decision = 'approve' then
    update public.tournament_stage_refund_cases
    set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
    where id = selected_case.id returning * into selected_case;
  else
    update public.tournament_stage_refund_cases
    set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
    where id = selected_case.id returning * into selected_case;
    update public.tournament_registration_paid_entries
    set status = 'paid', updated_at = now()
    where id = selected_case.paid_entry_id and status = 'refund_pending';
  end if;

  return selected_case;
end;
$$;

-- Serialize the refund decision and match-live transition on the same stage
-- and lobby keys. A pending refund blocks play; a live match consumes every
-- matching unused entry exactly once.
create function public.levelledup_guard_paid_entries_before_match_live()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status is distinct from 'live' and new.status = 'live' then
    perform pg_advisory_xact_lock(hashtextextended('financial-stage:' || new.stage_id::text, 0));
    perform pg_advisory_xact_lock(hashtextextended('financial-session:' || new.lobby_id::text, 0));

    if exists (
      select 1 from public.tournament_registration_paid_entries as entries
      where entries.status = 'refund_pending'
        and entries.stage_id = new.stage_id
        and (entries.entry_scope = 'stage' or entries.lobby_id = new.lobby_id)
    ) then
      raise exception 'Resolve pending stage/session refund cases before starting this match.'
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

create function public.levelledup_consume_paid_entries_after_match_live()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status is distinct from 'live' and new.status = 'live' then
    update public.tournament_registration_paid_entries as entries
    set status = 'consumed', consumed_match_id = new.id,
      consumed_at = now(), updated_at = now()
    where entries.status = 'paid'
      and entries.stage_id = new.stage_id
      and (entries.entry_scope = 'stage' or entries.lobby_id = new.lobby_id);
  end if;
  return new;
end;
$$;

alter function public.levelledup_guard_paid_entries_before_match_live() owner to postgres;
alter function public.levelledup_consume_paid_entries_after_match_live() owner to postgres;
revoke all on function public.levelledup_guard_paid_entries_before_match_live() from public, anon, authenticated;
revoke all on function public.levelledup_consume_paid_entries_after_match_live() from public, anon, authenticated;

create trigger tournament_matches_guard_financial_consumption
before update of status on public.tournament_matches
for each row execute function public.levelledup_guard_paid_entries_before_match_live();
create trigger tournament_matches_consume_paid_entries
after update of status on public.tournament_matches
for each row execute function public.levelledup_consume_paid_entries_after_match_live();

alter function public.levelledup_admin_get_refund_mode() owner to postgres;
alter function public.levelledup_admin_set_refund_mode(text) owner to postgres;
alter function public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, integer, uuid) owner to postgres;
alter function public.levelledup_issue_stage_refund_credit(uuid) owner to postgres;
alter function public.levelledup_admin_create_stage_refund_case(uuid, text) owner to postgres;
alter function public.levelledup_admin_review_stage_refund_case(uuid, text) owner to postgres;

revoke all on function public.levelledup_admin_get_refund_mode() from public, anon, authenticated;
revoke all on function public.levelledup_admin_set_refund_mode(text) from public, anon, authenticated;
revoke all on function public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, integer, uuid) from public, anon, authenticated;
revoke all on function public.levelledup_issue_stage_refund_credit(uuid) from public, anon, authenticated;
revoke all on function public.levelledup_admin_create_stage_refund_case(uuid, text) from public, anon, authenticated;
revoke all on function public.levelledup_admin_review_stage_refund_case(uuid, text) from public, anon, authenticated;

grant execute on function public.levelledup_admin_get_refund_mode() to authenticated;
grant execute on function public.levelledup_admin_set_refund_mode(text) to authenticated;
grant execute on function public.levelledup_admin_create_stage_paid_entry(uuid, uuid, text, uuid, integer, uuid) to authenticated;
grant execute on function public.levelledup_admin_create_stage_refund_case(uuid, text) to authenticated;
grant execute on function public.levelledup_admin_review_stage_refund_case(uuid, text) to authenticated;
grant execute on function public.levelledup_issue_stage_refund_credit(uuid) to authenticated;

alter table public.levelledup_financial_settings enable row level security;
alter table public.levelledup_refund_mode_history enable row level security;
alter table public.tournament_registration_paid_entries enable row level security;
alter table public.tournament_stage_refund_cases enable row level security;
alter table public.tournament_stage_credit_entitlements enable row level security;

revoke all on table public.levelledup_financial_settings from public, anon, authenticated;
revoke all on table public.levelledup_refund_mode_history from public, anon, authenticated;
revoke all on table public.tournament_registration_paid_entries from public, anon, authenticated;
revoke all on table public.tournament_stage_refund_cases from public, anon, authenticated;
revoke all on table public.tournament_stage_credit_entitlements from public, anon, authenticated;

create policy tournament_paid_entries_admin_read
on public.tournament_registration_paid_entries for select to authenticated
using (public.levelledup_has_admin_role('admin'));
create policy tournament_stage_refund_cases_admin_read
on public.tournament_stage_refund_cases for select to authenticated
using (public.levelledup_has_admin_role('admin'));
create policy tournament_stage_credit_entitlements_admin_read
on public.tournament_stage_credit_entitlements for select to authenticated
using (public.levelledup_has_admin_role('admin'));

grant select on table public.tournament_registration_paid_entries to authenticated;
grant select on table public.tournament_stage_refund_cases to authenticated;
grant select on table public.tournament_stage_credit_entitlements to authenticated;

-- Intentionally no changes to public.tournament_team_credits: those rows remain
-- permanent legacy full-tournament cancellation entitlements.

commit;
