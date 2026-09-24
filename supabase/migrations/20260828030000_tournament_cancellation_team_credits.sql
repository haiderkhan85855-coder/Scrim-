begin;

create table public.tournament_team_credits (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null
    references public.tournaments (id) on delete restrict,
  registration_id uuid not null
    references public.tournament_registrations (id) on delete restrict,
  team_id uuid not null
    references public.teams (id) on delete restrict,
  source_payment_id uuid not null
    references public.tournament_registration_payments (id) on delete restrict,
  source_reference_id text not null,
  amount_minor integer not null,
  currency text not null,
  status text not null default 'available',
  created_by uuid not null references auth.users (id) on delete restrict,
  status_updated_by uuid not null references auth.users (id) on delete restrict,
  status_updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_team_credits_registration_unique unique (registration_id),
  constraint tournament_team_credits_source_payment_unique unique (source_payment_id),
  constraint tournament_team_credits_amount_valid check (amount_minor > 0),
  constraint tournament_team_credits_currency_valid check (
    currency = upper(currency)
    and currency ~ '^[A-Z]{3}$'
  ),
  constraint tournament_team_credits_reference_valid check (
    source_reference_id = btrim(source_reference_id)
    and char_length(source_reference_id) between 3 and 120
  ),
  constraint tournament_team_credits_status_valid check (
    status in ('available', 'used', 'refunded')
  )
);

comment on table public.tournament_team_credits is
  'Permanent team credit/refund entitlement created from a verified payment when an entire tournament is cancelled.';
comment on column public.tournament_team_credits.source_reference_id is
  'Historical copy of the original transaction/reference ID. The source payment remains the authoritative financial record.';
comment on column public.tournament_team_credits.status is
  'Entitlement lifecycle only. V1 creates available credits; use and cash-refund execution are intentionally deferred.';

create index tournament_team_credits_tournament_status_idx
  on public.tournament_team_credits (tournament_id, status, created_at);
create index tournament_team_credits_team_history_idx
  on public.tournament_team_credits (team_id, created_at desc);

create function public.levelledup_set_tournament_team_credit_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

alter function public.levelledup_set_tournament_team_credit_updated_at()
  owner to postgres;
revoke all on function public.levelledup_set_tournament_team_credit_updated_at()
  from public, anon, authenticated;

create trigger tournament_team_credits_set_updated_at
before update on public.tournament_team_credits
for each row
execute function public.levelledup_set_tournament_team_credit_updated_at();

create function public.levelledup_guard_tournament_team_credit_history()
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

  select payments.*
  into source_payment
  from public.tournament_registration_payments as payments
  where payments.id = new.source_payment_id
  for share;

  select tournaments.*
  into source_tournament
  from public.tournaments as tournaments
  where tournaments.id = new.tournament_id
  for share;

  if source_payment.id is null
    or source_payment.status <> 'verified'
    or source_payment.registration_id <> new.registration_id
    or source_payment.tournament_id <> new.tournament_id
    or source_payment.team_id <> new.team_id
    or source_payment.reference_id <> new.source_reference_id then
    raise exception 'Tournament credit must reference its matching verified payment.'
      using errcode = 'P4516';
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

alter function public.levelledup_guard_tournament_team_credit_history()
  owner to postgres;
revoke all on function public.levelledup_guard_tournament_team_credit_history()
  from public, anon, authenticated;

create trigger tournament_team_credits_guard_history
before insert or update or delete on public.tournament_team_credits
for each row
execute function public.levelledup_guard_tournament_team_credit_history();

create function public.levelledup_guard_cancelled_tournament_payments()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  tournament_status text;
  must_validate boolean := false;
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
      raise exception 'Payments cannot be submitted or verified for a cancelled tournament.'
        using errcode = 'P4517';
    end if;
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_cancelled_tournament_payments()
  owner to postgres;
revoke all on function public.levelledup_guard_cancelled_tournament_payments()
  from public, anon, authenticated;

create trigger tournament_registration_payments_guard_cancelled_tournament
before insert or update of status on public.tournament_registration_payments
for each row
execute function public.levelledup_guard_cancelled_tournament_payments();

create function public.levelledup_admin_cancel_tournament_with_credits(
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
begin
  perform public.levelledup_require_admin('admin');

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4301';
  end if;

  if selected_tournament.status not in (
    'draft',
    'registration_open',
    'registration_closed'
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
    from public.tournament_matches as matches
    where matches.tournament_id = selected_tournament.id
      and matches.status in ('live', 'completed')
  ) or exists (
    select 1
    from public.match_results as results
    where results.tournament_id = selected_tournament.id
  ) then
    raise exception 'This tournament has begun and must remain historical.'
      using errcode = 'P4303';
  end if;

  perform 1
  from public.tournament_registrations as registrations
  where registrations.tournament_id = selected_tournament.id
  for update;

  perform 1
  from public.tournament_registration_payments as payments
  where payments.tournament_id = selected_tournament.id
  for update;

  update public.tournaments
  set status = 'cancelled'
  where id = selected_tournament.id
  returning * into selected_tournament;

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
  )
  select
    selected_tournament.id,
    registrations.id,
    registrations.team_id,
    payments.id,
    payments.reference_id,
    selected_tournament.entry_fee_minor,
    selected_tournament.currency,
    'available',
    authenticated_admin_id,
    authenticated_admin_id
  from public.tournament_registrations as registrations
  join public.tournament_registration_payments as payments
    on payments.registration_id = registrations.id
    and payments.tournament_id = registrations.tournament_id
    and payments.team_id = registrations.team_id
    and payments.status = 'verified'
  where registrations.tournament_id = selected_tournament.id
    and selected_tournament.entry_fee_minor > 0
  on conflict (registration_id) do nothing;

  return selected_tournament;
end;
$$;

alter function public.levelledup_admin_cancel_tournament_with_credits(uuid)
  owner to postgres;
revoke all on function public.levelledup_admin_cancel_tournament_with_credits(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_cancel_tournament_with_credits(uuid)
  to authenticated;

comment on function public.levelledup_admin_cancel_tournament_with_credits(uuid) is
  'Admin-only whole-tournament cancellation before competition begins. Preserves all history and atomically creates one available team credit per verified paid registration.';

create or replace function public.levelledup_admin_transition_tournament(
  p_tournament_id uuid,
  p_action text
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
  normalized_action text := lower(btrim(p_action));
begin
  perform public.levelledup_require_admin('admin');

  if normalized_action = 'cancel' then
    return public.levelledup_admin_cancel_tournament_with_credits(
      p_tournament_id
    );
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4301';
  end if;

  if normalized_action = 'open_registration' then
    if selected_tournament.status <> 'draft' then
      raise exception 'Only a draft tournament can open registration.'
        using errcode = 'P4303';
    end if;

    if now() < selected_tournament.registration_opens_at then
      raise exception 'Registration has not reached its configured opening time.'
        using errcode = 'P4304';
    end if;

    if now() > selected_tournament.registration_closes_at then
      raise exception 'The configured registration window has closed.'
        using errcode = 'P4304';
    end if;

    if now() >= selected_tournament.scheduled_start_at then
      raise exception 'Registration cannot open after the tournament starts.'
        using errcode = 'P4304';
    end if;

    update public.tournaments
    set status = 'registration_open'
    where id = selected_tournament.id
    returning * into selected_tournament;
  elsif normalized_action = 'close_registration' then
    if selected_tournament.status <> 'registration_open' then
      raise exception 'Only an open registration can be closed.'
        using errcode = 'P4303';
    end if;

    update public.tournaments
    set status = 'registration_closed'
    where id = selected_tournament.id
    returning * into selected_tournament;
  else
    raise exception 'Unsupported tournament lifecycle action.'
      using errcode = 'P4303';
  end if;

  return selected_tournament;
end;
$$;

alter function public.levelledup_admin_transition_tournament(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_admin_transition_tournament(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_transition_tournament(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_transition_tournament(uuid, text) is
  'Admin tournament lifecycle control. Cancellation always delegates to the atomic cancellation-credit workflow.';

create or replace function public.levelledup_admin_retire_tournament(
  p_tournament_id uuid,
  p_public_tournament_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_admin_id uuid := auth.uid();
  selected_tournament public.tournaments;
  has_history boolean;
begin
  perform public.levelledup_require_admin('admin');

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4301';
  end if;

  if upper(btrim(coalesce(p_public_tournament_id, '')))
    <> selected_tournament.tournament_id then
    raise exception 'Enter the permanent Tournament ID to confirm this action.'
      using errcode = 'P4312';
  end if;

  select
    exists (
      select 1
      from public.tournament_registrations as registrations
      where registrations.tournament_id = selected_tournament.id
    )
    or exists (
      select 1
      from public.tournament_matches as matches
      where matches.tournament_id = selected_tournament.id
    )
    or exists (
      select 1
      from public.tournament_registration_payments as payments
      where payments.tournament_id = selected_tournament.id
    )
  into has_history;

  if selected_tournament.status = 'draft' and not has_history then
    delete from public.tournaments
    where tournaments.id = selected_tournament.id;

    return jsonb_build_object(
      'outcome', 'deleted',
      'tournament_id', selected_tournament.tournament_id
    );
  end if;

  if selected_tournament.archived_at is not null then
    raise exception 'This tournament is already archived.'
      using errcode = 'P4313';
  end if;

  if selected_tournament.status not in ('completed', 'cancelled') then
    perform public.levelledup_admin_cancel_tournament_with_credits(
      selected_tournament.id
    );
  end if;

  update public.tournaments
  set
    archived_at = now(),
    archived_by = authenticated_admin_id
  where id = selected_tournament.id;

  return jsonb_build_object(
    'outcome', 'archived',
    'tournament_id', selected_tournament.tournament_id
  );
end;
$$;

alter function public.levelledup_admin_retire_tournament(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_admin_retire_tournament(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_retire_tournament(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_retire_tournament(uuid, text) is
  'Admin-only retirement. Deletes only dependency-free drafts; otherwise preserves history, creates required cancellation credits before competition begins, and archives the tournament.';

alter table public.tournament_team_credits enable row level security;

revoke all on table public.tournament_team_credits
  from public, anon, authenticated;
grant select on table public.tournament_team_credits
  to authenticated;

create policy "Team members can read their tournament credits"
  on public.tournament_team_credits
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.team_roster_members as members
      where members.team_id = tournament_team_credits.team_id
        and members.profile_id = auth.uid()
        and members.status = 'active'
    )
    or exists (
      select 1
      from public.tournament_registration_payments as payments
      where payments.id = tournament_team_credits.source_payment_id
        and payments.submitted_by = auth.uid()
    )
  );

create policy "Admins can read tournament credits"
  on public.tournament_team_credits
  for select
  to authenticated
  using (public.levelledup_has_admin_role('admin'));

commit;
