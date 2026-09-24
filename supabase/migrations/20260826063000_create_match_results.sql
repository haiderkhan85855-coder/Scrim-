begin;

-- These parent keys let match_results enforce tournament consistency with
-- declarative composite foreign keys rather than trusting application input.
alter table public.tournament_matches
  add constraint tournament_matches_id_tournament_unique
  unique (id, tournament_id);

alter table public.tournament_registrations
  add constraint tournament_registrations_id_tournament_unique
  unique (id, tournament_id);

create table public.match_results (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null,
  tournament_match_id uuid not null,
  tournament_registration_id uuid not null,
  placement integer not null,
  kills integer not null,
  placement_points integer not null,
  kill_points integer not null,
  total_points integer not null,
  status text not null default 'draft',
  entered_by uuid not null
    references auth.users (id) on delete restrict,
  finalized_by uuid
    references auth.users (id) on delete restrict,
  finalized_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint match_results_match_tournament_fk
    foreign key (tournament_match_id, tournament_id)
    references public.tournament_matches (id, tournament_id)
    on delete restrict,
  constraint match_results_registration_tournament_fk
    foreign key (tournament_registration_id, tournament_id)
    references public.tournament_registrations (id, tournament_id)
    on delete restrict,
  constraint match_results_match_registration_unique unique (
    tournament_match_id,
    tournament_registration_id
  ),
  constraint match_results_placement_positive check (
    placement >= 1
  ),
  constraint match_results_kills_nonnegative check (
    kills >= 0
  ),
  constraint match_results_points_nonnegative check (
    placement_points >= 0
    and kill_points >= 0
    and total_points >= 0
  ),
  constraint match_results_points_sum_valid check (
    total_points = placement_points + kill_points
  ),
  constraint match_results_status_valid check (
    status in ('draft', 'final')
  ),
  constraint match_results_finalization_state_valid check (
    (
      status = 'draft'
      and finalized_by is null
      and finalized_at is null
    )
    or (
      status = 'final'
      and finalized_by is not null
      and finalized_at is not null
      and finalized_at >= created_at
    )
  )
);

comment on table public.match_results is
  'One team registration result for one tournament match. Leaderboard points are calculated from the tournament scoring contract.';

comment on column public.match_results.tournament_id is
  'Denormalized only to enforce that the match and registration belong to the same tournament through composite foreign keys.';

comment on column public.match_results.placement_points is
  'Database-calculated leaderboard placement points; clients never supply this value.';

comment on column public.match_results.kill_points is
  'Database-calculated leaderboard kill points. This is unrelated to any per-kill cash reward.';

comment on column public.match_results.total_points is
  'Database-calculated placement_points plus kill_points.';

create unique index match_results_final_placement_per_match_idx
  on public.match_results (tournament_match_id, placement)
  where status = 'final';

create index match_results_registration_history_idx
  on public.match_results (
    tournament_registration_id,
    tournament_match_id
  );

create index match_results_match_status_idx
  on public.match_results (tournament_match_id, status);

create function public.levelledup_set_match_result_updated_at()
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

alter function public.levelledup_set_match_result_updated_at()
  owner to postgres;

revoke all on function public.levelledup_set_match_result_updated_at()
  from public, anon, authenticated;

create trigger match_results_set_updated_at
before update on public.match_results
for each row
execute function public.levelledup_set_match_result_updated_at();

create function public.levelledup_calculate_match_result()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  match_tournament_id uuid;
  selected_match public.tournament_matches;
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
  calculated_placement_points numeric;
  points_per_kill numeric;
  calculated_kill_points numeric;
  calculated_total_points numeric;
begin
  if tg_op = 'UPDATE' then
    if old.status = 'final' then
      raise exception 'Finalized match results are immutable.'
        using errcode = 'P4201';
    end if;

    if new.tournament_id is distinct from old.tournament_id
      or new.tournament_match_id is distinct from old.tournament_match_id
      or new.tournament_registration_id is distinct from old.tournament_registration_id
      or new.entered_by is distinct from old.entered_by
      or new.created_at is distinct from old.created_at then
      raise exception 'Match result identity and entry provenance cannot be changed.'
        using errcode = '22023';
    end if;

    if new.status not in ('draft', 'final') then
      raise exception 'Invalid match result status transition.'
        using errcode = 'P4202';
    end if;
  elsif new.status <> 'draft' then
    raise exception 'A new match result must begin as a draft.'
      using errcode = 'P4202';
  end if;

  if new.placement is null or new.placement < 1 then
    raise exception 'Placement must be a positive integer.'
      using errcode = '22023';
  end if;

  if new.kills is null or new.kills < 0 then
    raise exception 'Kills cannot be negative.'
      using errcode = '22023';
  end if;

  -- Read the parent identity first, then lock the tournament before its
  -- children. This matches the lock order used by tournament lifecycle work.
  select tournament_matches.tournament_id
  into match_tournament_id
  from public.tournament_matches
  where tournament_matches.id = new.tournament_match_id;

  if match_tournament_id is null then
    raise exception 'Tournament match not found.'
      using errcode = 'P4203';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = match_tournament_id
  for share;

  select tournament_matches.*
  into selected_match
  from public.tournament_matches
  where tournament_matches.id = new.tournament_match_id
  for share;

  select tournament_registrations.*
  into selected_registration
  from public.tournament_registrations
  where tournament_registrations.id = new.tournament_registration_id
  for share;

  if selected_match.id is null
    or selected_tournament.id is null
    or selected_match.tournament_id <> selected_tournament.id then
    raise exception 'Tournament match not found.'
      using errcode = 'P4203';
  end if;

  if selected_registration.id is null
    or selected_registration.tournament_id <> selected_tournament.id
    or new.tournament_id <> selected_tournament.id then
    raise exception 'The match and registration must belong to the same tournament.'
      using errcode = 'P4204';
  end if;

  if selected_registration.status <> 'confirmed' then
    raise exception 'Only a confirmed tournament registration can receive a result.'
      using errcode = 'P4205';
  end if;

  if selected_tournament.status <> 'live' then
    raise exception 'Results can be changed only while the tournament is live.'
      using errcode = 'P4206';
  end if;

  if selected_match.status not in ('live', 'completed') then
    if selected_match.status = 'cancelled' then
      raise exception 'Cancelled matches cannot receive results.'
        using errcode = 'P4206';
    end if;

    raise exception 'Results can be entered only after a match is live.'
      using errcode = 'P4206';
  end if;

  if new.status = 'final'
    and (
      new.finalized_by is null
      or new.finalized_at is null
    ) then
    raise exception 'Finalized results require finalization provenance.'
      using errcode = 'P4207';
  elsif new.status = 'draft' then
    new.finalized_by := null;
    new.finalized_at := null;
  end if;

  calculated_placement_points := coalesce(
    (
      selected_tournament.scoring_config
        -> 'placement_points'
        ->> new.placement::text
    )::numeric,
    0
  );

  points_per_kill := (
    selected_tournament.scoring_config
      ->> 'kill_points_per_kill'
  )::numeric;

  calculated_kill_points := new.kills::numeric * points_per_kill;
  calculated_total_points :=
    calculated_placement_points + calculated_kill_points;

  if calculated_placement_points < 0
    or calculated_placement_points <> trunc(calculated_placement_points)
    or points_per_kill < 0
    or points_per_kill <> trunc(points_per_kill)
    or calculated_kill_points > 2147483647
    or calculated_total_points > 2147483647 then
    raise exception 'Tournament scoring configuration must produce nonnegative integer points.'
      using errcode = 'P4208';
  end if;

  new.placement_points := calculated_placement_points::integer;
  new.kill_points := calculated_kill_points::integer;
  new.total_points := calculated_total_points::integer;

  return new;
end;
$$;

alter function public.levelledup_calculate_match_result()
  owner to postgres;

revoke all on function public.levelledup_calculate_match_result()
  from public, anon, authenticated;

create trigger match_results_calculate
before insert or update on public.match_results
for each row
execute function public.levelledup_calculate_match_result();

create function public.levelledup_guard_match_result_delete()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.status = 'final' then
    raise exception 'Finalized match results are immutable.'
      using errcode = 'P4201';
  end if;

  return old;
end;
$$;

alter function public.levelledup_guard_match_result_delete()
  owner to postgres;

revoke all on function public.levelledup_guard_match_result_delete()
  from public, anon, authenticated;

create trigger match_results_guard_delete
before delete on public.match_results
for each row
execute function public.levelledup_guard_match_result_delete();

create function public.levelledup_guard_tournament_scoring_config()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.scoring_config is distinct from old.scoring_config
    and (
      old.status in ('live', 'completed')
      or exists (
        select 1
        from public.match_results
        where match_results.tournament_id = old.id
      )
    ) then
    raise exception 'Tournament scoring is locked once play or result entry begins.'
      using errcode = 'P4209';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_tournament_scoring_config()
  owner to postgres;

revoke all on function public.levelledup_guard_tournament_scoring_config()
  from public, anon, authenticated;

create trigger tournaments_guard_scoring_config
before update of scoring_config on public.tournaments
for each row
execute function public.levelledup_guard_tournament_scoring_config();

create function public.levelledup_guard_match_completion_results()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.status = 'completed'
    and old.status <> 'completed'
    and exists (
      select 1
      from public.match_results
      where match_results.tournament_match_id = new.id
        and match_results.status = 'draft'
    ) then
    raise exception 'Draft results must be finalized or removed before completing the match.'
      using errcode = 'P4210';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_match_completion_results()
  owner to postgres;

revoke all on function public.levelledup_guard_match_completion_results()
  from public, anon, authenticated;

create trigger tournament_matches_guard_completion_results
before update of status on public.tournament_matches
for each row
execute function public.levelledup_guard_match_completion_results();

create function public.levelledup_upsert_match_result(
  p_tournament_match_id uuid,
  p_tournament_registration_id uuid,
  p_placement integer,
  p_kills integer
)
returns public.match_results
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_tournament_id uuid;
  saved_result public.match_results;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to enter match results.'
      using errcode = '42501';
  end if;

  select tournament_matches.tournament_id
  into selected_tournament_id
  from public.tournament_matches
  where tournament_matches.id = p_tournament_match_id;

  if selected_tournament_id is null then
    raise exception 'Tournament match not found.'
      using errcode = 'P4203';
  end if;

  insert into public.match_results (
    tournament_id,
    tournament_match_id,
    tournament_registration_id,
    placement,
    kills,
    placement_points,
    kill_points,
    total_points,
    status,
    entered_by
  )
  values (
    selected_tournament_id,
    p_tournament_match_id,
    p_tournament_registration_id,
    p_placement,
    p_kills,
    0,
    0,
    0,
    'draft',
    authenticated_user_id
  )
  on conflict (tournament_match_id, tournament_registration_id)
  do update set
    placement = excluded.placement,
    kills = excluded.kills
  returning * into saved_result;

  return saved_result;
end;
$$;

alter function public.levelledup_upsert_match_result(uuid, uuid, integer, integer)
  owner to postgres;

revoke all on function public.levelledup_upsert_match_result(uuid, uuid, integer, integer)
  from public, anon, authenticated;

comment on function public.levelledup_upsert_match_result(uuid, uuid, integer, integer) is
  'Trusted draft result entry point. Intentionally not executable by authenticated clients until admin authorization is implemented.';

create function public.levelledup_finalize_match_result(
  p_match_result_id uuid
)
returns public.match_results
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_result public.match_results;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to finalize match results.'
      using errcode = '42501';
  end if;

  select match_results.*
  into selected_result
  from public.match_results
  where match_results.id = p_match_result_id
  for update;

  if selected_result.id is null then
    raise exception 'Draft match result not found.'
      using errcode = 'P4211';
  end if;

  if selected_result.status <> 'draft' then
    raise exception 'Only a draft match result can be finalized.'
      using errcode = 'P4211';
  end if;

  update public.match_results
  set
    status = 'final',
    finalized_by = authenticated_user_id,
    finalized_at = now()
  where id = selected_result.id
  returning * into selected_result;

  return selected_result;
end;
$$;

alter function public.levelledup_finalize_match_result(uuid)
  owner to postgres;

revoke all on function public.levelledup_finalize_match_result(uuid)
  from public, anon, authenticated;

comment on function public.levelledup_finalize_match_result(uuid) is
  'Trusted finalization point. Intentionally not executable by authenticated clients until admin authorization is implemented.';

alter table public.match_results enable row level security;

revoke all on table public.match_results
  from public, anon, authenticated;

grant select on table public.match_results
  to authenticated;

create policy "Active team members can read their match results"
  on public.match_results
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.tournament_registrations
      where tournament_registrations.id =
        match_results.tournament_registration_id
        and public.levelledup_is_active_team_member(
          tournament_registrations.team_id
        )
    )
  );

commit;
