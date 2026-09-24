begin;

-- Forward-only reconciliation for durable protections that were not deployed
-- from 20260902010000 and 20260903030000. Runtime participation and Match
-- limits remain owned by Session Entry, Lobby and Session respectively.

do $$
begin
  if to_regclass('public.team_roster_members') is null
    or to_regclass('public.teams') is null
    or to_regclass('public.tournaments') is null
    or to_regclass('public.tournament_registration_roster') is null
    or to_regclass('public.tournament_registrations') is null
    or to_regclass('public.tournament_registration_payments') is null
    or to_regclass('public.tournament_registration_paid_entries') is null
    or to_regclass('public.tournament_stage_assignments') is null
    or to_regclass('public.tournament_session_entries') is null
    or to_regclass('public.tournament_stage_sessions') is null
    or to_regclass('public.tournament_stages') is null
    or to_regclass('public.tournament_lobbies') is null
    or to_regclass('public.tournament_matches') is null then
    raise exception 'Forward reconciliation prerequisites are incomplete.';
  end if;
end;
$$;

-- Players in the current finalized/locked Tournament Squad cannot voluntarily
-- self-leave while the registration is operational. Captain-controlled removal
-- remains valid, and preserved historical Squad rows are not rewritten.
create or replace function public.levelledup_block_active_tournament_squad_self_leave()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status = 'active'
    and new.status = 'left'
    and exists (
      select 1
      from public.tournament_registration_roster as squad_member
      join public.tournament_registrations as registration
        on registration.id = squad_member.registration_id
        and registration.roster_revision = squad_member.revision_number
      join public.tournaments as tournament
        on tournament.id = registration.tournament_id
      where squad_member.source_roster_member_id = old.id
        and registration.status in ('pending', 'confirmed')
        and registration.roster_status in ('finalized', 'locked')
        and tournament.status in (
          'registration_open',
          'registration_closed',
          'live'
        )
    ) then
    raise exception 'Players in an active tournament Squad cannot leave the team. Ask the Captain to remove you.'
      using errcode = 'P3032';
  end if;

  return new;
end;
$$;

alter function public.levelledup_block_active_tournament_squad_self_leave()
  owner to postgres;
revoke all on function public.levelledup_block_active_tournament_squad_self_leave()
  from public, anon, authenticated;

drop trigger if exists team_roster_members_block_active_tournament_squad_self_leave
  on public.team_roster_members;
create trigger team_roster_members_block_active_tournament_squad_self_leave
before update of status on public.team_roster_members
for each row
execute function public.levelledup_block_active_tournament_squad_self_leave();

-- Preserve historical payments while preventing any new payment attempt for a
-- disbanded team. Exact Session identity and price remain enforced by the
-- newer initial-Session and authoritative Session-price triggers.
create or replace function public.levelledup_require_active_team_for_new_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if not exists (
    select 1
    from public.teams as team
    where team.id = new.team_id
      and team.status = 'active'
  ) then
    raise exception 'A disbanded team cannot make new tournament payments.'
      using errcode = 'P4521';
  end if;

  return new;
end;
$$;

alter function public.levelledup_require_active_team_for_new_payment()
  owner to postgres;
revoke all on function public.levelledup_require_active_team_for_new_payment()
  from public, anon, authenticated;

drop trigger if exists tournament_registration_payments_require_active_team
  on public.tournament_registration_payments;
create trigger tournament_registration_payments_require_active_team
before insert on public.tournament_registration_payments
for each row
execute function public.levelledup_require_active_team_for_new_payment();

-- A historical verified Session payment may still be materialized solely for
-- the audited cancellation/refund path after its team has disbanded. Normal
-- future allocations remain blocked; exact scope, price and provenance also
-- remain enforced by the newer finance contract.
create or replace function public.levelledup_require_active_team_for_new_paid_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if exists (
    select 1
    from public.teams as team
    where team.id = new.team_id
      and team.status = 'active'
  ) then
    return new;
  end if;

  if new.entry_scope = 'session'
    and exists (
      select 1
      from public.tournament_registration_payments as payment
      join public.tournament_registrations as registration
        on registration.id = payment.registration_id
        and registration.tournament_id = payment.tournament_id
        and registration.team_id = payment.team_id
      join public.tournaments as tournament
        on tournament.id = payment.tournament_id
      where payment.id = new.source_payment_id
        and payment.status = 'verified'
        and payment.registration_id = new.registration_id
        and payment.tournament_id = new.tournament_id
        and payment.team_id = new.team_id
        and payment.session_id = new.session_id
        and payment.expected_amount_minor::bigint = new.amount_minor::bigint
        and payment.currency = new.currency
        and (
          (
            registration.status = 'withdrawn'
            and tournament.status in (
              'draft', 'registration_open', 'registration_closed'
            )
          )
          or (
            tournament.status = 'cancelled'
            and payment.cancelled_reconciled_at is not null
          )
        )
    ) then
    return new;
  end if;

  raise exception 'A disbanded team cannot receive a new paid stage or session entry.'
    using errcode = 'P4521';
end;
$$;

alter function public.levelledup_require_active_team_for_new_paid_entry()
  owner to postgres;
revoke all on function public.levelledup_require_active_team_for_new_paid_entry()
  from public, anon, authenticated;

drop trigger if exists tournament_paid_entries_require_active_team
  on public.tournament_registration_paid_entries;
create trigger tournament_paid_entries_require_active_team
before insert on public.tournament_registration_paid_entries
for each row
execute function public.levelledup_require_active_team_for_new_paid_entry();

-- Future assignment routing still requires an active team. Do not recheck
-- every snapshotted player's current live-team status: the latest approved
-- short-handed rule preserves the finalized Squad history, while the existing
-- 01_session_entry_scope trigger requires an active exact Session Entry.
create or replace function public.levelledup_guard_future_assignment_eligibility()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_registration public.tournament_registrations;
  requires_eligibility_check boolean;
begin
  if tg_op = 'INSERT' then
    requires_eligibility_check := new.status = 'assigned';
  else
    requires_eligibility_check := new.status = 'assigned'
      and (
        old.status is distinct from new.status
        or old.registration_id is distinct from new.registration_id
        or old.stage_id is distinct from new.stage_id
        or old.lobby_id is distinct from new.lobby_id
        or old.slot_number is distinct from new.slot_number
        or old.session_id is distinct from new.session_id
        or old.session_entry_id is distinct from new.session_entry_id
      );
  end if;

  if not requires_eligibility_check then
    return new;
  end if;

  select registration.*
  into selected_registration
  from public.tournament_registrations as registration
  where registration.id = new.registration_id
  for share;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4413';
  end if;

  if not exists (
    select 1
    from public.teams as team
    where team.id = selected_registration.team_id
      and team.status = 'active'
  ) then
    raise exception 'A disbanded team cannot receive or change future Lobby assignments.'
      using errcode = 'P4417';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_future_assignment_eligibility()
  owner to postgres;
revoke all on function public.levelledup_guard_future_assignment_eligibility()
  from public, anon, authenticated;

drop trigger if exists tournament_stage_assignments_00_guard_future_eligibility
  on public.tournament_stage_assignments;
create trigger tournament_stage_assignments_00_guard_future_eligibility
before insert or update of registration_id, stage_id, lobby_id, slot_number,
  status, session_id, session_entry_id
on public.tournament_stage_assignments
for each row
execute function public.levelledup_guard_future_assignment_eligibility();

-- Stage concurrency is only a template for creating Sessions. Remove the old
-- generated compatibility alias on fresh/full chains; it has no independent
-- stored history and must not look like a second runtime authority.
do $$
declare
  generated_kind "char";
begin
  select attribute.attgenerated
  into generated_kind
  from pg_catalog.pg_attribute as attribute
  where attribute.attrelid = 'public.tournament_stages'::regclass
    and attribute.attname = 'max_concurrent_lobbies'
    and not attribute.attisdropped;

  if generated_kind is not null and generated_kind <> 's' then
    raise exception 'Refusing to remove a non-generated Stage max_concurrent_lobbies column.';
  end if;

  if generated_kind = 's' then
    execute 'alter table public.tournament_stages '
      || 'drop column max_concurrent_lobbies';
  end if;
end;
$$;

comment on column public.tournament_stages.concurrent_lobby_capacity is
  'Template copied into a new Session. Runtime concurrent-Lobby limits are owned by tournament_stage_sessions.max_concurrent_lobbies.';

-- Tournament presentation fields must not cap valid Session/Lobby Match
-- sequences. Keep the current schedule-window and live-history protections;
-- the existing Session-aware Match validator remains untouched.
create or replace function public.levelledup_guard_tournament_match_configuration()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status in ('live', 'completed')
    and (
      new.matches_per_day is distinct from old.matches_per_day
      or new.number_of_days is distinct from old.number_of_days
      or new.scheduled_start_at is distinct from old.scheduled_start_at
      or new.scheduled_end_at is distinct from old.scheduled_end_at
    ) then
    raise exception 'Live and completed tournament Match configuration is immutable.'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.tournament_matches as tournament_match
    where tournament_match.tournament_id = old.id
      and (
        tournament_match.scheduled_start_at < new.scheduled_start_at
        or (
          new.scheduled_end_at is not null
          and tournament_match.scheduled_start_at > new.scheduled_end_at
        )
      )
  ) then
    raise exception 'Tournament Match configuration conflicts with existing Match history.'
      using errcode = 'P4103';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_tournament_match_configuration()
  owner to postgres;
revoke all on function public.levelledup_guard_tournament_match_configuration()
  from public, anon, authenticated;

comment on column public.tournaments.matches_per_day is
  'Legacy tournament presentation/default field. Runtime Match limits use the Lobby override or Session default.';
comment on column public.tournaments.number_of_days is
  'Tournament duration/presentation field, not a tournament-wide Match-count multiplier.';

-- Deployment assertions: internal guards stay private, the obsolete Stage
-- alias stays absent, and all newer Session contracts remain available.
do $$
begin
  if has_function_privilege(
      'anon',
      'public.levelledup_block_active_tournament_squad_self_leave()'::regprocedure,
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.levelledup_block_active_tournament_squad_self_leave()'::regprocedure,
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.levelledup_require_active_team_for_new_payment()'::regprocedure,
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.levelledup_require_active_team_for_new_payment()'::regprocedure,
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.levelledup_require_active_team_for_new_paid_entry()'::regprocedure,
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.levelledup_require_active_team_for_new_paid_entry()'::regprocedure,
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.levelledup_guard_future_assignment_eligibility()'::regprocedure,
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.levelledup_guard_future_assignment_eligibility()'::regprocedure,
      'EXECUTE'
    ) then
    raise exception 'Forward reconciliation internal functions must not be browser-executable.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = 'public.tournament_stages'::regclass
      and attribute.attname = 'max_concurrent_lobbies'
      and not attribute.attisdropped
  ) then
    raise exception 'Stage max_concurrent_lobbies must not remain a runtime authority.';
  end if;

  if to_regprocedure(
      'public.levelledup_validate_assignment_session_entry()'
    ) is null
    or to_regprocedure(
      'public.levelledup_admin_set_session_price(uuid,bigint,text,text,uuid)'
    ) is null
    or to_regprocedure(
      'public.levelledup_select_registration_initial_session(uuid,uuid)'
    ) is null then
    raise exception 'A required newer Session, pricing, or initial-registration contract is missing.';
  end if;
end;
$$;

commit;
