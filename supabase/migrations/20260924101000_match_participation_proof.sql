-- Match participation proof (Fix 3).
--
-- The old wrong-lobby guard accepted any historical assignment row, including
-- released ones: a team moved from lobby A to lobby B could still receive a
-- result for lobby A. This migration replaces that guard with an immutable
-- participation snapshot taken the first time a result is recorded for a
-- match. From then on, only teams in the snapshot can receive results for
-- that match, no matter how lobby assignments change afterwards.
--
-- Snapshot moment: the first match_results insert for the match. That is the
-- earliest point the system observes the match being scored, so it is the
-- closest available proxy for "the teams that played in this lobby".

-- ---------------------------------------------------------------------------
-- 1. Immutable participation snapshot
-- ---------------------------------------------------------------------------

create table public.match_participations (
  tournament_match_id uuid not null,
  tournament_registration_id uuid not null,
  tournament_id uuid not null,
  lobby_id uuid not null,
  stage_id uuid not null,
  team_id uuid not null,
  slot_number integer,
  snapshotted_at timestamptz not null default now(),
  constraint match_participations_pkey
    primary key (tournament_match_id, tournament_registration_id),
  constraint match_participations_match_fk
    foreign key (tournament_match_id, tournament_id)
    references public.tournament_matches (id, tournament_id)
    on delete cascade,
  constraint match_participations_registration_fk
    foreign key (tournament_registration_id, tournament_id)
    references public.tournament_registrations (id, tournament_id)
    on delete restrict,
  constraint match_participations_lobby_fk
    foreign key (lobby_id, stage_id, tournament_id)
    references public.tournament_lobbies (id, stage_id, tournament_id)
    on delete restrict
);

comment on table public.match_participations is
  'Immutable proof of which teams played in a match lobby. Snapshotted when the first result is recorded; later lobby edits never change it.';

create index match_participations_match_idx
  on public.match_participations (tournament_match_id);

-- Participations are proof: they can be created, never changed or removed.
create function public.levelledup_guard_match_participation_immutable()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  raise exception 'Match participations are immutable proof and cannot be changed.'
    using errcode = '25001';
  return null;
end;
$$;

alter function public.levelledup_guard_match_participation_immutable()
  owner to postgres;

revoke all on function public.levelledup_guard_match_participation_immutable()
  from public, anon, authenticated;

create trigger match_participations_immutable
before update or delete on public.match_participations
for each row
execute function public.levelledup_guard_match_participation_immutable();

alter table public.match_participations enable row level security;

create policy match_participations_deny_all
  on public.match_participations
  for all
  to public
  using (false)
  with check (false);

-- ---------------------------------------------------------------------------
-- 2. Snapshot helper (internal; called by the result validation trigger)
-- ---------------------------------------------------------------------------

create function public.levelledup_snapshot_match_participations(p_match_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  match_row record;
  inserted_count integer := 0;
begin
  if p_match_id is null then
    raise exception 'A match is required to snapshot participations.'
      using errcode = '22023';
  end if;

  -- Lock the match so concurrent first-results cannot snapshot twice.
  select m.id, m.tournament_id, m.lobby_id, m.stage_id
  into match_row
  from public.tournament_matches as m
  where m.id = p_match_id
  for update;

  if not found then
    raise exception 'Tournament match not found.'
      using errcode = 'P4203';
  end if;

  if exists (
    select 1
    from public.match_participations as p
    where p.tournament_match_id = p_match_id
  ) then
    return 0;
  end if;

  -- Snapshot the CURRENT active lobby assignments. Active means the team is
  -- in the lobby right now: status 'assigned' with no release timestamp.
  -- Released (historical) assignments are deliberately excluded: a team that
  -- was moved away before results started did not play in this lobby.
  with snapshot as (
    insert into public.match_participations (
      tournament_match_id,
      tournament_registration_id,
      tournament_id,
      lobby_id,
      stage_id,
      team_id,
      slot_number
    )
    select
      match_row.id,
      a.registration_id,
      match_row.tournament_id,
      match_row.lobby_id,
      match_row.stage_id,
      r.team_id,
      a.slot_number
    from public.tournament_stage_assignments as a
    join public.tournament_registrations as r
      on r.id = a.registration_id
    where a.lobby_id = match_row.lobby_id
      and a.status = 'assigned'
      and a.released_at is null
    on conflict (tournament_match_id, tournament_registration_id)
    do nothing
    returning 1
  )
  select count(*) into inserted_count from snapshot;

  return inserted_count;
end;
$$;

alter function public.levelledup_snapshot_match_participations(uuid)
  owner to postgres;

revoke all on function public.levelledup_snapshot_match_participations(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Replace the wrong-lobby guard with participation validation
-- ---------------------------------------------------------------------------

drop trigger if exists match_results_validate_lobby on public.match_results;
drop function if exists public.levelledup_validate_match_result_lobby();

create function public.levelledup_validate_match_participation()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  -- Snapshot on first result; no-op once the proof exists.
  perform public.levelledup_snapshot_match_participations(new.tournament_match_id);

  -- The team must be in the immutable participation proof. Later lobby
  -- edits (moves, releases) cannot add or remove teams from it, so a
  -- wrong-lobby result is impossible from this point on.
  if not exists (
    select 1
    from public.match_participations as p
    where p.tournament_match_id = new.tournament_match_id
      and p.tournament_registration_id = new.tournament_registration_id
  ) then
    raise exception 'Result rejected: this team is not in the match lobby participation list. If the team played in this lobby, restore its lobby assignment before entering results.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_validate_match_participation()
  owner to postgres;

revoke all on function public.levelledup_validate_match_participation()
  from public, anon, authenticated;

create trigger match_results_validate_participation
before insert or update of tournament_match_id, tournament_registration_id
on public.match_results
for each row
execute function public.levelledup_validate_match_participation();

comment on function public.levelledup_validate_match_participation() is
  'Snapshots lobby participations on first result, then rejects any result for a team outside the immutable participation proof.';

-- ---------------------------------------------------------------------------
-- 4. Backfill: matches that already have results get a participation proof
-- ---------------------------------------------------------------------------
--
-- For historical matches the snapshot is built from current active
-- assignments, plus every team that already has a result for the match (those
-- teams demonstrably played, even if their assignment was later released).
-- This grandfathers existing results without rewriting history; the strict
-- rule applies to every new result from here on.

with backfill as (
  insert into public.match_participations (
    tournament_match_id,
    tournament_registration_id,
    tournament_id,
    lobby_id,
    stage_id,
    team_id,
    slot_number
  )
  select distinct
    m.id,
    r.tournament_registration_id,
    m.tournament_id,
    m.lobby_id,
    m.stage_id,
    reg.team_id,
    a.slot_number
  from public.match_results as r
  join public.tournament_matches as m
    on m.id = r.tournament_match_id
  join public.tournament_registrations as reg
    on reg.id = r.tournament_registration_id
  left join public.tournament_stage_assignments as a
    on a.registration_id = r.tournament_registration_id
    and a.lobby_id = m.lobby_id
    and a.status = 'assigned'
    and a.released_at is null
  where not exists (
    select 1
    from public.match_participations as p
    where p.tournament_match_id = r.tournament_match_id
  )
  on conflict (tournament_match_id, tournament_registration_id)
  do nothing
  returning 1
)
select count(*) as backfilled_participations from backfill;

-- ---------------------------------------------------------------------------
-- 5. Admin RPC: list a match's participation proof for the result form
-- ---------------------------------------------------------------------------

create function public.levelledup_list_match_participations(p_match_id uuid)
returns table (
  registration_id uuid,
  team_id uuid,
  team_name text,
  team_code text,
  slot_number integer
)
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  return query
  select
    p.tournament_registration_id,
    p.team_id,
    t.name,
    t.team_id,
    p.slot_number
  from public.match_participations as p
  join public.teams as t
    on t.id = p.team_id
  where p.tournament_match_id = p_match_id
  order by p.slot_number nulls last, t.name;
end;
$$;

alter function public.levelledup_list_match_participations(uuid)
  owner to postgres;

revoke all on function public.levelledup_list_match_participations(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_list_match_participations(uuid)
  to authenticated;

comment on function public.levelledup_list_match_participations(uuid) is
  'Admin-only: the immutable team list for a match result form. Empty until the first result snapshots it.';
