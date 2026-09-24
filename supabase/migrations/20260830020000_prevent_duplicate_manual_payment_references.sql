begin;

create function public.levelledup_normalize_manual_payment_reference(
  p_reference_id text
)
returns text
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select case
    when pg_catalog.regexp_replace(
      pg_catalog.upper(pg_catalog.btrim(p_reference_id)),
      '[^A-Z0-9]+',
      '',
      'g'
    ) <> '' then pg_catalog.regexp_replace(
      pg_catalog.upper(pg_catalog.btrim(p_reference_id)),
      '[^A-Z0-9]+',
      '',
      'g'
    )
    else pg_catalog.upper(pg_catalog.btrim(p_reference_id))
  end;
$$;

alter function public.levelledup_normalize_manual_payment_reference(text)
  owner to postgres;
revoke all on function public.levelledup_normalize_manual_payment_reference(text)
  from public, anon, authenticated;

alter table public.tournament_registration_payments
  add column manual_reference_normalized text
  generated always as (
    case
      when payment_method = 'manual' then
        public.levelledup_normalize_manual_payment_reference(reference_id)
      else null
    end
  ) stored;

alter table public.tournament_registration_payments
  add constraint tournament_registration_payments_manual_reference_normalized_valid
  check (
    (
      payment_method = 'manual'
      and manual_reference_normalized is not null
    )
    or (
      payment_method = 'gateway'
      and manual_reference_normalized is null
    )
  );

comment on column public.tournament_registration_payments.manual_reference_normalized is
  'Comparison-only key for manual payment references. Gateway/provider transaction identifiers remain independently provider-scoped.';

create index tournament_registration_payments_manual_reference_lookup_idx
  on public.tournament_registration_payments (manual_reference_normalized, status)
  where payment_method = 'manual';

create function public.levelledup_guard_manual_payment_reference()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_reference text;
begin
  if new.payment_method <> 'manual' then
    return new;
  end if;

  normalized_reference :=
    public.levelledup_normalize_manual_payment_reference(new.reference_id);

  if pg_catalog.char_length(normalized_reference) not between 3 and 120 then
    raise exception 'Enter a valid transaction or reference ID.'
      using errcode = 'P4501';
  end if;

  if new.status in ('pending', 'verified') then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'manual-payment-reference:' || normalized_reference,
        0
      )
    );

    if exists (
      select 1
      from public.tournament_registration_payments as payments
      where payments.payment_method = 'manual'
        and payments.manual_reference_normalized = normalized_reference
        and payments.status in ('pending', 'verified')
        and payments.id <> new.id
    ) then
      raise exception 'This transaction/reference ID is already used by another pending or verified payment.'
        using errcode = 'P4520';
    end if;
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_manual_payment_reference()
  owner to postgres;
revoke all on function public.levelledup_guard_manual_payment_reference()
  from public, anon, authenticated;

create trigger tournament_registration_payments_guard_manual_reference
before insert or update of status, payment_method, reference_id
on public.tournament_registration_payments
for each row
execute function public.levelledup_guard_manual_payment_reference();

comment on function public.levelledup_guard_manual_payment_reference() is
  'Serializes manual-reference writes and prevents one normalized reference from backing multiple pending or verified payment attempts. Historical rejected attempts remain preserved.';

commit;
