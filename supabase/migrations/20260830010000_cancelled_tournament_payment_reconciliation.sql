begin;

alter table public.tournament_registration_payments
  add column cancelled_reconciled_at timestamptz,
  add column cancelled_reconciled_by uuid
    references auth.users (id) on delete restrict,
  add constraint tournament_registration_payments_cancelled_reconciliation_valid
    check (
      (
        cancelled_reconciled_at is null
        and cancelled_reconciled_by is null
      )
      or (
        status = 'verified'
        and cancelled_reconciled_at is not null
        and cancelled_reconciled_by is not null
      )
    );

comment on column public.tournament_registration_payments.cancelled_reconciled_at is
  'Set only when an Admin confirms a preserved pending payment after the tournament was cancelled.';
comment on column public.tournament_registration_payments.cancelled_reconciled_by is
  'Admin who reconciled a genuine pending payment after cancellation. Normal payment verification leaves this null.';

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

alter function public.levelledup_keep_tournament_payment_attempt()
  owner to postgres;
revoke all on function public.levelledup_keep_tournament_payment_attempt()
  from public, anon, authenticated;

create or replace function public.levelledup_guard_cancelled_tournament_payments()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  tournament_status text;
  must_validate boolean := false;
  is_admin_reconciliation boolean := false;
begin
  if tg_op = 'INSERT' then
    must_validate := true;
  elsif tg_op = 'UPDATE' then
    must_validate := new.status = 'verified'
      and old.status is distinct from 'verified';
  end if;

  if must_validate then
    select tournaments.status
    into tournament_status
    from public.tournaments as tournaments
    where tournaments.id = new.tournament_id
    for share;

    if tournament_status = 'cancelled' then
      is_admin_reconciliation :=
        tg_op = 'UPDATE'
        and old.status = 'pending'
        and new.status = 'verified'
        and old.cancelled_reconciled_at is null
        and old.cancelled_reconciled_by is null
        and new.cancelled_reconciled_at is not null
        and new.cancelled_reconciled_by = auth.uid()
        and public.levelledup_has_admin_role('admin');

      if not is_admin_reconciliation then
        raise exception 'Payments cannot be submitted or normally verified for a cancelled tournament.'
          using errcode = 'P4517';
      end if;
    end if;
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_cancelled_tournament_payments()
  owner to postgres;
revoke all on function public.levelledup_guard_cancelled_tournament_payments()
  from public, anon, authenticated;

create function public.levelledup_admin_reconcile_cancelled_tournament_payment(
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
  existing_credit public.tournament_team_credits;
begin
  perform public.levelledup_require_admin('admin');

  if normalized_decision not in ('confirm', 'reject') then
    raise exception 'Unsupported cancelled-payment reconciliation decision.'
      using errcode = 'P4518';
  end if;

  select payments.*
  into selected_payment
  from public.tournament_registration_payments as payments
  where payments.id = p_payment_id
  for update;

  if selected_payment.id is null
    or selected_payment.payment_method <> 'manual' then
    raise exception 'Cancelled tournament payment submission not found.'
      using errcode = 'P4507';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_payment.tournament_id
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
    select credits.*
    into existing_credit
    from public.tournament_team_credits as credits
    where credits.registration_id = selected_payment.registration_id
    for share;

    if normalized_decision = 'confirm'
      and selected_payment.cancelled_reconciled_at is not null
      and existing_credit.id is not null
      and existing_credit.source_payment_id = selected_payment.id
      and existing_credit.amount_minor = selected_payment.expected_amount_minor
      and existing_credit.currency = selected_payment.currency then
      return selected_payment;
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

  if selected_tournament.entry_fee_minor <= 0
    or selected_payment.expected_amount_minor <> selected_tournament.entry_fee_minor
    or selected_payment.currency <> selected_tournament.currency then
    raise exception 'The preserved payment does not match the cancelled tournament entry fee.'
      using errcode = 'P4519';
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

  insert into public.tournament_team_credits (
    tournament_id,
    registration_id,
    team_id,
    source_payment_id,
    source_reference_id,
    amount_minor,
    currency,
    status,
    created_by,
    status_updated_by
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

  select credits.*
  into existing_credit
  from public.tournament_team_credits as credits
  where credits.registration_id = selected_payment.registration_id
  for share;

  if existing_credit.id is null
    or existing_credit.source_payment_id <> selected_payment.id
    or existing_credit.amount_minor <> selected_payment.expected_amount_minor
    or existing_credit.currency <> selected_payment.currency
    or existing_credit.source_reference_id <> selected_payment.reference_id then
    raise exception 'A conflicting cancellation credit already exists for this registration.'
      using errcode = 'P4519';
  end if;

  return selected_payment;
end;
$$;

alter function public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_reconcile_cancelled_tournament_payment(uuid, text) is
  'Admin-only reconciliation for a payment that remained pending when its tournament was cancelled. Confirmation verifies the payment and creates its cancellation credit atomically; rejection preserves the attempt.';

commit;
