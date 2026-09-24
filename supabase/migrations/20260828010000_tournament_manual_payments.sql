begin;

create table public.tournament_registration_payments (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null,
  tournament_id uuid not null,
  team_id uuid not null,
  payment_method text not null,
  status text not null default 'pending',
  expected_amount_minor integer not null,
  currency text not null,
  reference_id text,
  provider text,
  provider_transaction_id text,
  verification_source text,
  submitted_by uuid not null references auth.users (id) on delete restrict,
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_registration_payments_registration_fk
    foreign key (registration_id, tournament_id, team_id)
    references public.tournament_registrations (id, tournament_id, team_id)
    on delete restrict,
  constraint tournament_registration_payments_method_valid check (
    payment_method in ('manual', 'gateway')
  ),
  constraint tournament_registration_payments_status_valid check (
    status in ('pending', 'verified', 'rejected')
  ),
  constraint tournament_registration_payments_amount_valid check (
    expected_amount_minor > 0
  ),
  constraint tournament_registration_payments_currency_valid check (
    currency = upper(currency)
    and currency ~ '^[A-Z]{3}$'
  ),
  constraint tournament_registration_payments_reference_valid check (
    reference_id is null
    or (
      reference_id = btrim(reference_id)
      and char_length(reference_id) between 3 and 120
    )
  ),
  constraint tournament_registration_payments_provider_valid check (
    provider is null
    or (
      provider = lower(btrim(provider))
      and char_length(provider) between 2 and 40
      and provider ~ '^[a-z0-9_-]+$'
    )
  ),
  constraint tournament_registration_payments_provider_transaction_valid check (
    provider_transaction_id is null
    or (
      provider_transaction_id = btrim(provider_transaction_id)
      and char_length(provider_transaction_id) between 3 and 160
    )
  ),
  constraint tournament_registration_payments_manual_fields_valid check (
    (
      payment_method = 'manual'
      and reference_id is not null
      and provider is null
      and provider_transaction_id is null
    )
    or payment_method = 'gateway'
  ),
  constraint tournament_registration_payments_review_state_valid check (
    (
      status = 'pending'
      and verification_source is null
      and reviewed_by is null
      and reviewed_at is null
    )
    or (
      status in ('verified', 'rejected')
      and verification_source in ('admin', 'provider_callback')
      and reviewed_at is not null
      and (
        (verification_source = 'admin' and reviewed_by is not null)
        or (
          verification_source = 'provider_callback'
          and payment_method = 'gateway'
          and provider is not null
          and provider_transaction_id is not null
        )
      )
    )
  )
);

comment on table public.tournament_registration_payments is
  'Append-only payment attempts for tournament registrations. Rejected attempts remain historical; resubmission creates another row.';
comment on column public.tournament_registration_payments.expected_amount_minor is
  'Tournament entry fee copied by the trusted submission function. Clients never provide this amount.';
comment on column public.tournament_registration_payments.provider_transaction_id is
  'Reserved for a future trusted gateway callback. It must never contain wallet credentials, PINs, passwords or OTPs.';

create unique index tournament_registration_payments_one_open_attempt_idx
  on public.tournament_registration_payments (registration_id)
  where status in ('pending', 'verified');

create unique index tournament_registration_payments_provider_transaction_idx
  on public.tournament_registration_payments (provider, provider_transaction_id)
  where provider is not null and provider_transaction_id is not null;

create index tournament_registration_payments_tournament_history_idx
  on public.tournament_registration_payments (tournament_id, submitted_at desc);
create index tournament_registration_payments_registration_history_idx
  on public.tournament_registration_payments (registration_id, submitted_at desc);
create index tournament_registration_payments_team_history_idx
  on public.tournament_registration_payments (team_id, submitted_at desc);

create function public.levelledup_set_tournament_payment_updated_at()
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

alter function public.levelledup_set_tournament_payment_updated_at()
  owner to postgres;
revoke all on function public.levelledup_set_tournament_payment_updated_at()
  from public, anon, authenticated;

create trigger tournament_registration_payments_set_updated_at
before update on public.tournament_registration_payments
for each row
execute function public.levelledup_set_tournament_payment_updated_at();

create function public.levelledup_keep_tournament_payment_attempt()
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
    or new.payment_method is distinct from old.payment_method
    or new.expected_amount_minor is distinct from old.expected_amount_minor
    or new.currency is distinct from old.currency
    or new.reference_id is distinct from old.reference_id
    or new.provider is distinct from old.provider
    or new.provider_transaction_id is distinct from old.provider_transaction_id
    or new.submitted_by is distinct from old.submitted_by
    or new.submitted_at is distinct from old.submitted_at
    or new.created_at is distinct from old.created_at then
    raise exception 'A submitted tournament payment attempt is immutable.'
      using errcode = '22023';
  end if;

  if old.status <> 'pending' and new.status is distinct from old.status then
    raise exception 'A reviewed tournament payment cannot change status.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_tournament_payment_attempt()
  owner to postgres;
revoke all on function public.levelledup_keep_tournament_payment_attempt()
  from public, anon, authenticated;

create trigger tournament_registration_payments_keep_attempt
before update or delete on public.tournament_registration_payments
for each row
execute function public.levelledup_keep_tournament_payment_attempt();

create function public.levelledup_submit_manual_tournament_payment(
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
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
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

  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id
  for update;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4502';
  end if;

  if not public.levelledup_is_active_team_captain(selected_registration.team_id) then
    raise exception 'Only the active team Captain can submit payment.'
      using errcode = '42501';
  end if;

  if selected_registration.status <> 'pending'
    or selected_registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the pending tournament roster before submitting payment.'
      using errcode = 'P4503';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_registration.tournament_id
  for share;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4502';
  end if;

  if selected_tournament.entry_fee_minor <= 0 then
    raise exception 'This tournament does not require payment.'
      using errcode = 'P4504';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      selected_registration.id::text || ':payment',
      0
    )
  );

  if exists (
    select 1
    from public.tournament_registration_payments as payments
    where payments.registration_id = selected_registration.id
      and payments.status in ('pending', 'verified')
  ) then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
  end if;

  insert into public.tournament_registration_payments (
    registration_id,
    tournament_id,
    team_id,
    payment_method,
    status,
    expected_amount_minor,
    currency,
    reference_id,
    submitted_by
  ) values (
    selected_registration.id,
    selected_registration.tournament_id,
    selected_registration.team_id,
    'manual',
    'pending',
    selected_tournament.entry_fee_minor,
    selected_tournament.currency,
    normalized_reference,
    authenticated_user_id
  )
  returning * into created_payment;

  return created_payment;
exception
  when unique_violation then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
end;
$$;

alter function public.levelledup_submit_manual_tournament_payment(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_submit_manual_tournament_payment(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_submit_manual_tournament_payment(uuid, text)
  to authenticated;

create function public.levelledup_admin_review_tournament_payment(
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
  normalized_decision text := lower(btrim(coalesce(p_decision, '')));
  selected_payment public.tournament_registration_payments;
  registration_status text;
begin
  perform public.levelledup_require_admin('admin');

  if normalized_decision not in ('verify', 'reject') then
    raise exception 'Unsupported payment review decision.'
      using errcode = 'P4506';
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

  select registrations.status
  into registration_status
  from public.tournament_registrations as registrations
  where registrations.id = selected_payment.registration_id
  for share;

  if normalized_decision = 'verify' and registration_status <> 'pending' then
    raise exception 'Only a pending tournament registration can receive verified payment.'
      using errcode = 'P4503';
  end if;

  update public.tournament_registration_payments
  set
    status = case normalized_decision
      when 'verify' then 'verified'
      else 'rejected'
    end,
    verification_source = 'admin',
    reviewed_by = auth.uid(),
    reviewed_at = now()
  where id = selected_payment.id
  returning * into selected_payment;

  return selected_payment;
end;
$$;

alter function public.levelledup_admin_review_tournament_payment(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_admin_review_tournament_payment(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_review_tournament_payment(uuid, text)
  to authenticated;

create function public.levelledup_require_verified_payment_for_confirmation()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  required_entry_fee integer;
  required_currency text;
begin
  if new.status = 'confirmed'
    and old.status is distinct from 'confirmed' then
    select tournaments.entry_fee_minor, tournaments.currency
    into required_entry_fee, required_currency
    from public.tournaments as tournaments
    where tournaments.id = new.tournament_id
    for share;

    if required_entry_fee > 0
      and not exists (
        select 1
        from public.tournament_registration_payments as payments
        where payments.registration_id = new.id
          and payments.status = 'verified'
          and payments.expected_amount_minor = required_entry_fee
          and payments.currency = required_currency
      ) then
      raise exception 'Verify tournament payment before approving this registration.'
        using errcode = 'P4508';
    end if;
  end if;

  return new;
end;
$$;

alter function public.levelledup_require_verified_payment_for_confirmation()
  owner to postgres;
revoke all on function public.levelledup_require_verified_payment_for_confirmation()
  from public, anon, authenticated;

create trigger tournament_registrations_01_require_verified_payment
before update of status on public.tournament_registrations
for each row
execute function public.levelledup_require_verified_payment_for_confirmation();

alter table public.tournament_registration_payments enable row level security;

revoke all on table public.tournament_registration_payments
  from public, anon, authenticated;
grant select on table public.tournament_registration_payments
  to authenticated;

create policy "Captains can read their tournament payment history"
  on public.tournament_registration_payments
  for select
  to authenticated
  using (public.levelledup_is_active_team_captain(team_id));

create policy "Admins can read tournament payment history"
  on public.tournament_registration_payments
  for select
  to authenticated
  using (public.levelledup_has_admin_role('admin'));

commit;
