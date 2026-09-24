begin;

-- Disbanding is a team-lifecycle event, not a deletion of competition history.
-- Preserve a confirmed registration and its occupied slot when that exact
-- assignment is backed by an unused or consumed paid stage/session entry.
-- Other pre-start registrations continue through the existing withdrawal path.
create or replace function public.levelledup_withdraw_registrations_for_inactive_team()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status = 'active' and new.status <> 'active' then
    update public.tournament_registrations as registration
    set status = 'withdrawn'
    from public.tournaments as tournament
    where registration.team_id = new.id
      and registration.status in ('pending', 'confirmed')
      and tournament.id = registration.tournament_id
      and tournament.status in ('draft', 'registration_open', 'registration_closed')
      and (
        registration.status = 'pending'
        or now() < tournament.scheduled_start_at
      )
      and not exists (
        select 1
        from public.tournament_stage_assignments as assignment
        join public.tournament_registration_paid_entries as paid_entry
          on paid_entry.registration_id = registration.id
          and paid_entry.stage_id = assignment.stage_id
          and (
            paid_entry.entry_scope = 'stage'
            or paid_entry.lobby_id = assignment.lobby_id
          )
          and paid_entry.status in ('paid', 'consumed')
        where assignment.registration_id = registration.id
          and assignment.status = 'assigned'
      );
  end if;

  return new;
end;
$$;

alter function public.levelledup_withdraw_registrations_for_inactive_team()
  owner to postgres;
revoke all on function public.levelledup_withdraw_registrations_for_inactive_team()
  from public, anon, authenticated;

-- A player cannot voluntarily leave while they are part of the currently
-- submitted Squad revision for an active registration. Captain removal remains
-- a separate trusted status transition to `removed` and is intentionally valid.
create function public.levelledup_block_active_tournament_squad_self_leave()
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

create trigger team_roster_members_block_active_tournament_squad_self_leave
before update of status on public.team_roster_members
for each row
execute function public.levelledup_block_active_tournament_squad_self_leave();

-- Future payment providers and trusted payment writers must obey the same
-- inactive-team rule as today's Captain-only manual-payment RPC.
create function public.levelledup_require_active_team_for_new_payment()
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

create trigger tournament_registration_payments_require_active_team
before insert on public.tournament_registration_payments
for each row
execute function public.levelledup_require_active_team_for_new_payment();

-- A verified historical payment remains immutable, but it cannot be allocated
-- to a new paid block after the team has disbanded.
create function public.levelledup_require_active_team_for_new_paid_entry()
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
    raise exception 'A disbanded team cannot receive a new paid stage or session entry.'
      using errcode = 'P4521';
  end if;

  return new;
end;
$$;

alter function public.levelledup_require_active_team_for_new_paid_entry()
  owner to postgres;
revoke all on function public.levelledup_require_active_team_for_new_paid_entry()
  from public, anon, authenticated;

create trigger tournament_paid_entries_require_active_team
before insert on public.tournament_registration_paid_entries
for each row
execute function public.levelledup_require_active_team_for_new_paid_entry();

-- Existing assignments remain untouched. Only a new assignment or an attempt
-- to move/reactivate an assignment rechecks future eligibility.
create function public.levelledup_guard_future_assignment_eligibility()
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
    requires_eligibility_check := true;
  else
    requires_eligibility_check := new.status = 'assigned'
      and (
        old.status is distinct from new.status
        or old.registration_id is distinct from new.registration_id
        or old.stage_id is distinct from new.stage_id
        or old.lobby_id is distinct from new.lobby_id
        or old.slot_number is distinct from new.slot_number
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
    raise exception 'Tournament registration not found.' using errcode = 'P4413';
  end if;

  if not exists (
    select 1
    from public.teams as team
    where team.id = selected_registration.team_id
      and team.status = 'active'
  ) then
    raise exception 'A disbanded team cannot receive or change future lobby assignments.'
      using errcode = 'P4417';
  end if;

  if exists (
    select 1
    from public.tournament_registration_roster as squad_member
    left join public.team_roster_members as current_member
      on current_member.id = squad_member.source_roster_member_id
    where squad_member.registration_id = selected_registration.id
      and squad_member.revision_number = selected_registration.roster_revision
      and (
        current_member.id is null
        or current_member.status <> 'active'
      )
  ) then
    raise exception 'The current tournament Squad contains a player who is no longer eligible for a future assignment.'
      using errcode = 'P4418';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_future_assignment_eligibility()
  owner to postgres;
revoke all on function public.levelledup_guard_future_assignment_eligibility()
  from public, anon, authenticated;

create trigger tournament_stage_assignments_00_guard_future_eligibility
before insert or update of registration_id, stage_id, lobby_id, slot_number, status
on public.tournament_stage_assignments
for each row
execute function public.levelledup_guard_future_assignment_eligibility();

-- Slot-board consumers need only the team's lifecycle label. Assignment and
-- registration identities retain their existing authorization rules.
drop function public.levelledup_get_tournament_slot_board(text);

create function public.levelledup_get_tournament_slot_board(
  p_tournament_code text
)
returns table (
  tournament_name text,
  tournament_code text,
  stage_id uuid,
  stage_name text,
  tier_label text,
  stage_number integer,
  lobby_id uuid,
  lobby_label text,
  lobby_code text,
  lobby_order integer,
  lobby_capacity integer,
  slot_number integer,
  assignment_id uuid,
  registration_id uuid,
  team_name text,
  team_code text,
  team_status text
)
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select
    tournament.name,
    tournament.tournament_id,
    stage.id,
    stage.display_name,
    stage.tier_label,
    stage.stage_number,
    lobby.id,
    lobby.display_label,
    lobby.lobby_code,
    lobby.lobby_order,
    lobby.capacity,
    slot.slot_number,
    case
      when public.levelledup_has_admin_role('admin') or exists (
        select 1
        from public.team_roster_members as authorized_membership
        where authorized_membership.team_id = registration.team_id
          and authorized_membership.profile_id = auth.uid()
          and authorized_membership.status = 'active'
      ) then assignment.id
      else null
    end,
    case
      when public.levelledup_has_admin_role('admin') or exists (
        select 1
        from public.team_roster_members as authorized_membership
        where authorized_membership.team_id = registration.team_id
          and authorized_membership.profile_id = auth.uid()
          and authorized_membership.status = 'active'
      ) then registration.id
      else null
    end,
    team.name,
    team.team_id,
    team.status
  from public.tournaments as tournament
  join public.tournament_stages as stage
    on stage.tournament_id = tournament.id
  join public.tournament_lobbies as lobby
    on lobby.stage_id = stage.id
  cross join lateral generate_series(1, lobby.capacity) as slot(slot_number)
  left join public.tournament_stage_assignments as assignment
    on assignment.lobby_id = lobby.id
    and assignment.slot_number = slot.slot_number
    and assignment.status = 'assigned'
  left join public.tournament_registrations as registration
    on registration.id = assignment.registration_id
  left join public.teams as team
    on team.id = registration.team_id
  where tournament.tournament_id = upper(btrim(p_tournament_code))
    and (
      (
        tournament.status not in ('draft', 'cancelled')
        and tournament.archived_at is null
      )
      or public.levelledup_has_admin_role('admin')
    )
  order by stage.stage_number, lobby.lobby_order, slot.slot_number;
$$;

alter function public.levelledup_get_tournament_slot_board(text)
  owner to postgres;
revoke all on function public.levelledup_get_tournament_slot_board(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_get_tournament_slot_board(text)
  to authenticated;

comment on function public.levelledup_get_tournament_slot_board(text) is
  'Authorized slot projection keyed by exact registration; disbanded teams keep paid-block assignments and expose only their lifecycle label.';

commit;
