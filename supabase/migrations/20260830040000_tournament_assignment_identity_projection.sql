begin;

-- Slot-board consumers must identify an assignment by its tournament
-- registration, never by a reusable team code or a broad current-team flag.
-- The existing assignment rows remain untouched; only the authorized
-- projection gains stable identities.
drop function if exists public.levelledup_get_tournament_slot_board(text);

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
  team_code text
)
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select
    tournaments.name,
    tournaments.tournament_id,
    stages.id,
    stages.display_name,
    stages.tier_label,
    stages.stage_number,
    lobbies.id,
    lobbies.display_label,
    lobbies.lobby_code,
    lobbies.lobby_order,
    lobbies.capacity,
    slots.slot_number,
    case
      when public.levelledup_has_admin_role('admin') or exists (
        select 1
        from public.team_roster_members as authorized_membership
        where authorized_membership.team_id = registrations.team_id
          and authorized_membership.profile_id = auth.uid()
          and authorized_membership.status = 'active'
      ) then assignments.id
      else null
    end,
    case
      when public.levelledup_has_admin_role('admin') or exists (
        select 1
        from public.team_roster_members as authorized_membership
        where authorized_membership.team_id = registrations.team_id
          and authorized_membership.profile_id = auth.uid()
          and authorized_membership.status = 'active'
      ) then registrations.id
      else null
    end,
    teams.name,
    teams.team_id
  from public.tournaments as tournaments
  join public.tournament_stages as stages
    on stages.tournament_id = tournaments.id
  join public.tournament_lobbies as lobbies
    on lobbies.stage_id = stages.id
  cross join lateral generate_series(1, lobbies.capacity) as slots(slot_number)
  left join public.tournament_stage_assignments as assignments
    on assignments.lobby_id = lobbies.id
    and assignments.slot_number = slots.slot_number
    and assignments.status = 'assigned'
  left join public.tournament_registrations as registrations
    on registrations.id = assignments.registration_id
  left join public.teams as teams
    on teams.id = registrations.team_id
  where tournaments.tournament_id = upper(btrim(p_tournament_code))
    and (
      (
        tournaments.status not in ('draft', 'cancelled')
        and tournaments.archived_at is null
      )
      or public.levelledup_has_admin_role('admin')
    )
  order by stages.stage_number, lobbies.lobby_order, slots.slot_number;
$$;

alter function public.levelledup_get_tournament_slot_board(text)
  owner to postgres;
revoke all on function public.levelledup_get_tournament_slot_board(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_get_tournament_slot_board(text)
  to authenticated;

comment on function public.levelledup_get_tournament_slot_board(text) is
  'Authorized tournament slot projection. Stage/lobby identities describe the board; assignment and registration identities are exposed only to admins or active members of the assigned team.';

commit;
