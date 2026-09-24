begin;

-- A persistent team roster is a pool of at most six players. The roster number
-- is stable for the lifetime of a membership row and is unique among the
-- team's active members. Historical inactive rows retain their number; a
-- vacated number may later be reused by a new membership row.
do $$
begin
  if exists (
    select 1
    from public.team_roster_members
    where status = 'active'
    group by team_id
    having count(*) > 6
  ) then
    raise exception 'Existing team data exceeds the maximum of 6 active roster members.';
  end if;
end;
$$;

alter table public.team_roster_members
  add column roster_number integer;

with numbered_active_members as (
  select
    id,
    row_number() over (
      partition by team_id
      order by created_at, id
    )::integer as assigned_number
  from public.team_roster_members
  where status = 'active'
)
update public.team_roster_members as members
set roster_number = numbered_active_members.assigned_number
from numbered_active_members
where numbered_active_members.id = members.id;

with numbered_historical_members as (
  select
    id,
    (
      (row_number() over (
        partition by team_id
        order by created_at, id
      ) - 1) % 6 + 1
    )::integer as assigned_number
  from public.team_roster_members
  where status <> 'active'
)
update public.team_roster_members as members
set roster_number = numbered_historical_members.assigned_number
from numbered_historical_members
where numbered_historical_members.id = members.id;

alter table public.team_roster_members
  alter column roster_number set not null,
  add constraint team_roster_members_roster_number_valid check (
    roster_number between 1 and 6
  );

create unique index team_roster_members_active_team_roster_number_unique
  on public.team_roster_members (team_id, roster_number)
  where status = 'active';

comment on column public.team_roster_members.roster_number is
  'Stable 1-6 number for this membership row. Unique among active members of the same team and retained when the membership becomes historical.';

create function public.levelledup_assign_and_guard_team_roster_number()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  active_member_count integer;
  first_available_number integer;
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.team_id::text || ':active-roster', 0)
  );

  if tg_op = 'INSERT' and new.roster_number is null then
    select available.number
    into first_available_number
    from generate_series(1, 6) as available(number)
    where not exists (
      select 1
      from public.team_roster_members as occupied
      where occupied.team_id = new.team_id
        and occupied.status = 'active'
        and occupied.roster_number = available.number
    )
    order by available.number
    limit 1;

    -- Inactive rows are historical, but still receive a valid stable number.
    new.roster_number := coalesce(first_available_number, 1);
  end if;

  if new.roster_number is null or new.roster_number not between 1 and 6 then
    raise exception 'Team roster number must be between 1 and 6.'
      using errcode = 'P3021';
  end if;

  if new.status <> 'active' then
    return new;
  end if;

  select count(*)::integer
  into active_member_count
  from public.team_roster_members as members
  where members.team_id = new.team_id
    and members.status = 'active'
    and members.id <> new.id;

  if active_member_count >= 6 then
    raise exception 'A team may have a maximum of 6 active players.'
      using errcode = 'P3022';
  end if;

  if exists (
    select 1
    from public.team_roster_members as occupied
    where occupied.team_id = new.team_id
      and occupied.status = 'active'
      and occupied.roster_number = new.roster_number
      and occupied.id <> new.id
  ) then
    raise exception 'That team roster number is already occupied.'
      using errcode = 'P3023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_assign_and_guard_team_roster_number()
  owner to postgres;
revoke all on function public.levelledup_assign_and_guard_team_roster_number()
  from public, anon, authenticated;

create trigger team_roster_members_00_assign_and_guard_roster_number
before insert or update of team_id, roster_number, status
on public.team_roster_members
for each row
execute function public.levelledup_assign_and_guard_team_roster_number();

create function public.levelledup_keep_team_roster_number()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.roster_number is distinct from old.roster_number then
    raise exception 'A team roster number cannot be changed on an existing membership.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_team_roster_number()
  owner to postgres;
revoke all on function public.levelledup_keep_team_roster_number()
  from public, anon, authenticated;

create trigger team_roster_members_keep_roster_number
before update of roster_number on public.team_roster_members
for each row
execute function public.levelledup_keep_team_roster_number();

-- Tournament rosters are always a 1-6 player snapshot. Game mode governs the
-- later per-match lineup, not registration or roster finalization.
alter table public.tournaments
  drop constraint tournaments_roster_size_valid;

update public.tournaments
set
  roster_min_players = 1,
  roster_max_players = 6;

alter table public.tournaments
  add constraint tournaments_roster_size_valid check (
    roster_min_players = 1
    and roster_max_players = 6
  );

create or replace function public.levelledup_default_tournament_roster_configuration()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
    and new.scheduled_start_at is distinct from old.scheduled_start_at
    and new.roster_lock_at is not distinct from old.roster_lock_at
    and old.roster_lock_at = old.scheduled_start_at then
    new.roster_lock_at := new.scheduled_start_at;
  end if;

  new.roster_lock_at := coalesce(new.roster_lock_at, new.scheduled_start_at);
  new.roster_min_players := coalesce(new.roster_min_players, 1);
  new.roster_max_players := coalesce(new.roster_max_players, 6);

  return new;
end;
$$;

alter function public.levelledup_default_tournament_roster_configuration()
  owner to postgres;
revoke all on function public.levelledup_default_tournament_roster_configuration()
  from public, anon, authenticated;

comment on column public.tournaments.roster_min_players is
  'Tournament roster minimum. LevelledUp V1 requires at least one selected player regardless of game mode.';
comment on column public.tournaments.roster_max_players is
  'Tournament roster maximum. LevelledUp V1 permits up to six selected players; per-match lineup limits are separate.';

-- Preserve the stable team roster number in every immutable tournament
-- snapshot. Existing snapshots receive deterministic registration-local
-- numbers because no roster numbers existed when they were finalized.
do $$
begin
  if exists (
    select 1
    from public.tournament_registration_roster
    group by registration_id
    having count(*) > 6
  ) then
    raise exception 'Existing tournament history contains a roster larger than 6 players and requires manual review.';
  end if;
end;
$$;

alter table public.tournament_registration_roster
  add column roster_number integer;

with numbered_snapshots as (
  select
    id,
    row_number() over (
      partition by registration_id
      order by created_at, id
    )::integer as assigned_number
  from public.tournament_registration_roster
)
update public.tournament_registration_roster as snapshots
set roster_number = numbered_snapshots.assigned_number
from numbered_snapshots
where numbered_snapshots.id = snapshots.id;

alter table public.tournament_registration_roster
  alter column roster_number set not null,
  add constraint tournament_registration_roster_number_valid check (
    roster_number between 1 and 6
  ),
  add constraint tournament_registration_roster_number_per_registration_unique
    unique (registration_id, roster_number);

comment on column public.tournament_registration_roster.roster_number is
  'Immutable snapshot of the player membership roster number for tournament and future match-history attribution.';

create function public.levelledup_assign_tournament_snapshot_roster_number()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  source_number integer;
begin
  select members.roster_number
  into source_number
  from public.team_roster_members as members
  where members.id = new.source_roster_member_id
    and members.team_id = new.team_id
    and members.status = 'active'
  for share;

  if source_number is null then
    raise exception 'Tournament roster source member is not an eligible active team member.'
      using errcode = 'P4010';
  end if;

  if new.roster_number is null then
    new.roster_number := source_number;
  elsif new.roster_number <> source_number then
    raise exception 'Tournament roster number must match the selected team roster member.'
      using errcode = 'P4010';
  end if;

  return new;
end;
$$;

alter function public.levelledup_assign_tournament_snapshot_roster_number()
  owner to postgres;
revoke all on function public.levelledup_assign_tournament_snapshot_roster_number()
  from public, anon, authenticated;

create trigger tournament_registration_roster_01_assign_roster_number
before insert on public.tournament_registration_roster
for each row
execute function public.levelledup_assign_tournament_snapshot_roster_number();

create function public.levelledup_keep_tournament_snapshot_roster_number()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.roster_number is distinct from old.roster_number then
    raise exception 'Tournament roster snapshots are immutable.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_tournament_snapshot_roster_number()
  owner to postgres;
revoke all on function public.levelledup_keep_tournament_snapshot_roster_number()
  from public, anon, authenticated;

create trigger tournament_registration_roster_keep_roster_number
before update of roster_number on public.tournament_registration_roster
for each row
execute function public.levelledup_keep_tournament_snapshot_roster_number();

commit;
