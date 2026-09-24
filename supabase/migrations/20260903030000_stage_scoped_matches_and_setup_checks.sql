begin;

-- Preserve the deployed storage/API spelling; expose the requested canonical
-- read name without a second editable value or rewriting audit history.
alter table public.tournament_stages
  add column max_concurrent_lobbies integer
    generated always as (concurrent_lobby_capacity) stored;
comment on column public.tournament_stages.max_concurrent_lobbies is
  'Stage-local concurrent lobby limit, derived from the existing single stored concurrent_lobby_capacity. Configure either spelling through the Admin RPC. Not teams per lobby and not scheduler automation.';
comment on column public.tournaments.matches_per_day is
  'Legacy tournament presentation/default field. It no longer caps stage/lobby match numbers; tournament_stages.matches_per_lobby is authoritative.';
comment on column public.tournaments.number_of_days is
  'Tournament duration/presentation field, not a multiplier enforcing a tournament-wide match limit. Each stage/lobby has its own match sequence.';

create or replace function public.levelledup_admin_configure_stage(
  p_stage_id uuid, p_patch jsonb, p_override_reason text default null
)
returns public.tournament_stages
language plpgsql security definer set search_path = '' set row_security = off as $$
declare
  previous public.tournament_stages;
  proposed public.tournament_stages;
  parent_id uuid;
  parent_status text;
  reason text := nullif(btrim(p_override_reason), '');
begin
  perform public.levelledup_require_admin('admin');
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Stage configuration must be an object.' using errcode = '22023';
  end if;
  -- One setting, two compatible API spellings; never store independent limits.
  if p_patch ? 'max_concurrent_lobbies' then
    if p_patch ? 'concurrent_lobby_capacity'
      and p_patch->'max_concurrent_lobbies' is distinct from p_patch->'concurrent_lobby_capacity' then
      raise exception 'Conflicting concurrent lobby limits.' using errcode = '22023';
    end if;
    p_patch := (p_patch - 'max_concurrent_lobbies') ||
      jsonb_build_object('concurrent_lobby_capacity', p_patch->'max_concurrent_lobbies');
  end if;
  if exists (select 1 from jsonb_object_keys(p_patch) as key(name) where key.name not in (
    'name_preset', 'custom_name', 'stage_number', 'matches_per_lobby', 'stage_fee_minor',
    'fee_currency', 'retry_allowed', 'knockout_enabled', 'advancement_count',
    'planned_lobby_count', 'concurrent_lobby_capacity', 'advancement_rule'
  )) then
    raise exception 'Unsupported stage configuration field.' using errcode = '22023';
  end if;
  select stage.tournament_id into parent_id from public.tournament_stages as stage where stage.id = p_stage_id;
  select tournament.status into parent_status from public.tournaments as tournament
  where tournament.id = parent_id for update;
  select stage.* into previous from public.tournament_stages as stage where stage.id = p_stage_id for update;
  if previous.id is null then raise exception 'Stage not found.' using errcode = '22023'; end if;
  if previous.rules_locked_at is null and (previous.status = 'cancelled' or parent_status in ('cancelled', 'completed')) then
    raise exception 'Retired stage configuration cannot be edited normally.' using errcode = '22023';
  end if;
  proposed := jsonb_populate_record(previous, p_patch);
  proposed.custom_name := nullif(btrim(proposed.custom_name), '');
  proposed.fee_currency := nullif(upper(btrim(proposed.fee_currency)), '');
  if proposed.knockout_enabled and not (p_patch ? 'retry_allowed') then
    proposed.retry_allowed := false;
  end if;
  if public.levelledup_stage_core_configuration(previous) = public.levelledup_stage_core_configuration(proposed) then
    return previous;
  end if;
  if previous.rules_locked_at is not null then
    if reason is null or char_length(reason) not between 10 and 1000 then
      raise exception 'Admin Override requires a reason between 10 and 1000 characters.' using errcode = '22023';
    end if;
    if cardinality(public.levelledup_stage_missing_configuration(proposed)) > 0 then
      raise exception 'Admin Override must leave started-stage configuration complete.' using errcode = '22023';
    end if;
    insert into public.tournament_stage_configuration_events (
      stage_id, tournament_id, event_type, version_before, version_after,
      before_config, after_config, reason, actor_user_id
    ) values (previous.id, previous.tournament_id, 'admin_override',
      previous.configuration_version, previous.configuration_version + 1,
      public.levelledup_stage_core_configuration(previous), public.levelledup_stage_core_configuration(proposed),
      reason, auth.uid());
  end if;
  update public.tournament_stages set name_preset = proposed.name_preset, custom_name = proposed.custom_name,
    stage_number = proposed.stage_number, matches_per_lobby = proposed.matches_per_lobby,
    stage_fee_minor = proposed.stage_fee_minor, fee_currency = proposed.fee_currency,
    retry_allowed = proposed.retry_allowed, knockout_enabled = proposed.knockout_enabled,
    advancement_count = proposed.advancement_count, planned_lobby_count = proposed.planned_lobby_count,
    concurrent_lobby_capacity = proposed.concurrent_lobby_capacity, advancement_rule = proposed.advancement_rule
  where id = previous.id returning * into proposed;
  return proposed;
end;
$$;

-- Keep every existing lifecycle, map, schedule and completed-history check;
-- only replace tournament-wide match limits and protect permanent match scope.
create or replace function public.levelledup_validate_tournament_match()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
  selected_stage public.tournament_stages;
  configured_match_count bigint;
begin
  if tg_op = 'UPDATE'
    and (new.id is distinct from old.id or new.tournament_id is distinct from old.tournament_id
      or new.stage_id is distinct from old.stage_id or new.lobby_id is distinct from old.lobby_id) then
    raise exception 'Match identity and owning tournament, stage and lobby cannot change.'
      using errcode = '22023';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = new.tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4101';
  end if;

  if selected_tournament.status = 'completed' then
    raise exception 'Matches cannot be changed after tournament completion.'
      using errcode = 'P4102';
  end if;

  if tg_op = 'INSERT'
    and selected_tournament.status = 'cancelled' then
    raise exception 'Matches cannot be added to a cancelled tournament.'
      using errcode = 'P4102';
  end if;

  select s.* into selected_stage from public.tournament_stages s
  where s.id = new.stage_id and s.tournament_id = new.tournament_id for share;
  if selected_stage.id is null or not exists(
    select 1 from public.tournament_lobbies l
    where l.id = new.lobby_id and l.stage_id = new.stage_id and l.tournament_id = new.tournament_id
  ) then
    raise exception 'Match must belong to a lobby and stage in the same tournament.' using errcode = '23503';
  end if;
  if selected_stage.status in ('completed', 'cancelled')
    and (tg_op = 'INSERT' or new.status <> 'cancelled') then
    raise exception 'Matches cannot be added or played in a retired stage.' using errcode = 'P4102';
  end if;
  configured_match_count := selected_stage.matches_per_lobby;
  -- Cancellation of a legacy row remains possible even if its old stage
  -- configuration is incomplete. Never rewrite/renumber that history.
  if tg_op = 'INSERT' or new.status <> 'cancelled' or new.match_number is distinct from old.match_number then
    if configured_match_count is null then
      raise exception 'Configure this stage match count per lobby before scheduling matches.' using errcode = 'P4103';
    end if;
    if new.match_number::bigint > configured_match_count then
      raise exception 'Match number exceeds this stage match count per lobby.' using errcode = 'P4103';
    end if;
  end if;

  if new.scheduled_start_at < selected_tournament.scheduled_start_at
    or (
      selected_tournament.scheduled_end_at is not null
      and new.scheduled_start_at > selected_tournament.scheduled_end_at
    ) then
    raise exception 'Match schedule falls outside the tournament schedule.'
      using errcode = 'P4104';
  end if;

  if tg_op = 'INSERT'
    or new.map_code is distinct from old.map_code then
    if not exists (
      select 1
      from public.pubg_maps
      where pubg_maps.code = new.map_code
        and pubg_maps.is_active
    ) then
      raise exception 'Select an active canonical PUBG map.'
        using errcode = 'P4105';
    end if;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'scheduled' then
      raise exception 'A new match must begin as scheduled.'
        using errcode = 'P4106';
    end if;
  elsif old.status in ('completed', 'cancelled') then
    raise exception 'Completed and cancelled matches are historically immutable.'
      using errcode = 'P4102';
  elsif new.status is distinct from old.status
    and not (
      (old.status = 'scheduled' and new.status in ('live', 'cancelled'))
      or (old.status = 'live' and new.status in ('completed', 'cancelled'))
    ) then
    raise exception 'Invalid match status transition.'
      using errcode = 'P4106';
  end if;

  if tg_op = 'UPDATE'
    and old.status = 'live'
    and (
      new.match_number is distinct from old.match_number
      or new.map_code is distinct from old.map_code
      or new.scheduled_start_at is distinct from old.scheduled_start_at
    ) then
    raise exception 'Live match identity and schedule cannot be changed.'
      using errcode = '22023';
  end if;

  if new.status = 'live'
    and selected_tournament.status <> 'live' then
    raise exception 'A match can go live only while its tournament is live.'
      using errcode = 'P4107';
  end if;

  if new.status = 'completed'
    and selected_tournament.status <> 'live' then
    raise exception 'A match can be completed only while its tournament is live.'
      using errcode = 'P4107';
  end if;

  if selected_tournament.status = 'cancelled'
    and new.status <> 'cancelled' then
    raise exception 'Matches in a cancelled tournament must be cancelled.'
      using errcode = 'P4107';
  end if;

  if new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  else
    new.completed_at := null;
  end if;

  return new;
end;
$$;

-- The tournament window still encloses every match. Legacy presentation counts
-- cannot reject a valid stage/lobby schedule or alter stage configuration.
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
    raise exception 'Live and completed tournament match configuration is immutable.'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.tournament_matches
    where tournament_matches.tournament_id = old.id
      and (
        tournament_matches.scheduled_start_at < new.scheduled_start_at
        or (
          new.scheduled_end_at is not null
          and tournament_matches.scheduled_start_at > new.scheduled_end_at
        )
      )
  ) then
    raise exception 'Tournament match configuration conflicts with an existing match.'
      using errcode = 'P4103';
  end if;

  return new;
end;
$$;

create function public.levelledup_guard_stage_match_count()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
begin
  if new.matches_per_lobby is not distinct from old.matches_per_lobby then return new; end if;
  -- Same tournament lock as match writes/configuration RPCs serializes the
  -- count check against concurrent inserts; the stage row is already locked.
  perform 1 from public.tournaments where id = new.tournament_id for update;
  if exists(select 1 from public.tournament_matches m where m.stage_id = new.id
    and (new.matches_per_lobby is null or m.match_number > new.matches_per_lobby)) then
    raise exception 'Stage match count conflicts with existing match history; it cannot be cleared or reduced below existing match numbers.' using errcode = 'P4103';
  end if;
  return new;
end;
$$;
create trigger tournament_stages_15_guard_match_count before update of matches_per_lobby on public.tournament_stages
for each row execute function public.levelledup_guard_stage_match_count();

-- A detailed Admin diagnostic, not a publication/start/advancement gate.
-- Keep the older setup RPC's return signature intact for existing consumers.
create function public.levelledup_admin_get_stage_setup_checks(p_tournament_id uuid)
returns table (
  stage_id uuid, stage_name text, stage_number integer, max_concurrent_lobbies integer,
  setup_complete boolean, issues text[], lobby_checks jsonb
)
language plpgsql stable security definer set search_path = '' set row_security = off as $$
declare
  s public.tournament_stages; l public.tournament_lobbies;
  problems text[]; details jsonb;
  lobby_count bigint; assigned_count bigint; match_count bigint; last_number integer;
  scheduled_count bigint; lobby_problems text[];
begin
  perform public.levelledup_require_admin('admin');
  for s in select st.* from public.tournament_stages st where st.tournament_id = p_tournament_id order by st.stage_number loop
    problems := '{}'::text[]; details := '[]'::jsonb;
    if not s.configuration_ready then problems := array_append(problems,'configuration_incomplete'); end if;
    if s.planned_lobby_count is null then problems := array_append(problems,'planned_lobby_count_missing'); end if;
    if s.max_concurrent_lobbies is null then problems := array_append(problems,'max_concurrent_lobbies_missing'); end if;
    if s.advancement_count is null or (s.advancement_count > 0 and coalesce(s.advancement_rule,'{}'::jsonb) = '{}'::jsonb) then
      problems := array_append(problems,'advancement_configuration_missing');
    end if;
    select count(*) into lobby_count from public.tournament_lobbies lb where lb.stage_id = s.id and lb.status <> 'cancelled';
    if lobby_count = 0 then problems := array_append(problems,'lobbies_missing'); end if;
    if s.planned_lobby_count is not null and lobby_count <> s.planned_lobby_count then
      problems := array_append(problems,'lobby_count_mismatch');
    end if;
    for l in select lb.* from public.tournament_lobbies lb where lb.stage_id = s.id and lb.status <> 'cancelled' order by lb.lobby_order loop
      lobby_problems := '{}'::text[];
      select count(*),max(m.match_number),count(m.scheduled_start_at)
      into match_count,last_number,scheduled_count
      from public.tournament_matches m where m.lobby_id = l.id and m.stage_id = s.id and m.status <> 'cancelled';
      select count(*) into assigned_count from public.tournament_stage_assignments a
      join public.tournament_registrations r on r.id = a.registration_id and r.tournament_id = a.tournament_id
      where a.stage_id = s.id and a.lobby_id = l.id and a.status = 'assigned' and r.status = 'confirmed';
      if s.matches_per_lobby is null or match_count <> s.matches_per_lobby or last_number is distinct from s.matches_per_lobby then
        lobby_problems := array_append(lobby_problems,'matches_incomplete');
      end if;
      if s.matches_per_lobby is null or scheduled_count < s.matches_per_lobby then
        lobby_problems := array_append(lobby_problems,'schedule_incomplete');
      end if;
      if exists(select 1 from public.tournament_matches m where m.lobby_id = l.id and m.status <> 'cancelled'
        group by m.scheduled_start_at having count(*) > 1) then
        lobby_problems := array_append(lobby_problems,'same_lobby_start_conflict');
      end if;
      if assigned_count = 0 then lobby_problems := array_append(lobby_problems,'assignments_missing'); end if;
      problems := problems || lobby_problems;
      details := details || jsonb_build_array(jsonb_build_object(
        'lobby_id',l.id,'lobby_label',l.display_label,'match_count',match_count,
        'scheduled_match_count',scheduled_count,'assigned_team_count',assigned_count,'issues',lobby_problems
      ));
    end loop;
    -- Detect provable simultaneous-start overflow only. Without match durations
    -- no honest overlap/concurrency scheduler validation can be performed.
    if s.max_concurrent_lobbies is not null and exists(
      select 1 from public.tournament_matches m join public.tournament_lobbies lb on lb.id=m.lobby_id
      where m.stage_id=s.id and m.status <> 'cancelled' and lb.status <> 'cancelled'
      group by m.scheduled_start_at having count(distinct m.lobby_id) > s.max_concurrent_lobbies
    ) then problems := array_append(problems,'concurrent_lobby_starts_exceed_limit'); end if;
    select coalesce(array_agg(distinct issue order by issue),'{}'::text[]) into problems from unnest(problems) as issue;
    return query select s.id,s.display_name,s.stage_number,s.max_concurrent_lobbies,
      cardinality(problems)=0,problems,details;
  end loop;
end;
$$;
comment on function public.levelledup_admin_get_stage_setup_checks(uuid) is
  'Admin-only computed setup diagnostics. Assignments require at least one confirmed team per non-cancelled lobby, not a full lobby or inferred future qualifiers. Missing schedule includes missing expected matches. Positive advancement_count requires a future validated rule; zero explicitly means no advancement. Checks simultaneous starts, not duration overlaps. Does not execute progression or change publication readiness.';

alter function public.levelledup_admin_configure_stage(uuid,jsonb,text) owner to postgres;
alter function public.levelledup_validate_tournament_match() owner to postgres;
alter function public.levelledup_guard_tournament_match_configuration() owner to postgres;
alter function public.levelledup_guard_stage_match_count() owner to postgres;
alter function public.levelledup_admin_get_stage_setup_checks(uuid) owner to postgres;
revoke all on function public.levelledup_admin_configure_stage(uuid,jsonb,text),
  public.levelledup_validate_tournament_match(),public.levelledup_guard_tournament_match_configuration(),
  public.levelledup_guard_stage_match_count(),public.levelledup_admin_get_stage_setup_checks(uuid)
  from public,anon,authenticated;
grant execute on function public.levelledup_admin_configure_stage(uuid,jsonb,text),
  public.levelledup_admin_get_stage_setup_checks(uuid) to authenticated;

-- No IDs, assignments, matches, results, payment records or audit rows are
-- updated. Existing composite FKs and (lobby_id,match_number) uniqueness remain.
commit;

