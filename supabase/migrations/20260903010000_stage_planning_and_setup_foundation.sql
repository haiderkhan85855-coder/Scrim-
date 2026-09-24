begin;

-- Extend permanent stages; do not replace any stage/lobby/match identity.
-- NULL planning values mean not configured, not an invented historical plan.
alter table public.tournament_stages
  add column planned_lobby_count integer,
  add column concurrent_lobby_capacity integer,
  add column advancement_rule jsonb,
  add constraint tournament_stages_planned_lobbies_valid check (planned_lobby_count > 0),
  add constraint tournament_stages_concurrent_lobbies_valid check (concurrent_lobby_capacity > 0),
  add constraint tournament_stages_concurrency_within_plan check (
    planned_lobby_count is null or concurrent_lobby_capacity <= planned_lobby_count
  ),
  add constraint tournament_stages_advancement_rule_placeholder check (
    advancement_rule is null or advancement_rule = '{}'::jsonb
  );

comment on column public.tournament_stages.planned_lobby_count is
  'Planned lobby count for this stage, independent of teams per lobby and tournament registration capacity. NULL means unconfigured. Existing lobbies are not recreated or renumbered.';
comment on column public.tournament_stages.concurrent_lobby_capacity is
  'Positive number of lobbies intended to run concurrently, up to planned_lobby_count. NULL means unconfigured. This is planning metadata, not a scheduler or a player-slot limit.';
comment on column public.tournament_stages.advancement_rule is
  'Reserved structured advancement rule; only NULL or an empty object is accepted until a validated advancement workflow exists. advancement_count remains the existing per-lobby count.';

-- Include planning in the SAME configuration version / immutable audit system.
-- Existing events retain their original JSON; no historical event is rewritten.
create or replace function public.levelledup_stage_core_configuration(p_stage public.tournament_stages)
returns jsonb language sql immutable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'name_preset', p_stage.name_preset, 'custom_name', p_stage.custom_name,
    'stage_number', p_stage.stage_number, 'tier_label', p_stage.tier_label,
    'matches_per_lobby', p_stage.matches_per_lobby,
    'stage_fee_minor', p_stage.stage_fee_minor, 'fee_currency', p_stage.fee_currency,
    'retry_allowed', p_stage.retry_allowed, 'knockout_enabled', p_stage.knockout_enabled,
    'advancement_count', p_stage.advancement_count,
    'planned_lobby_count', p_stage.planned_lobby_count,
    'concurrent_lobby_capacity', p_stage.concurrent_lobby_capacity,
    'advancement_rule', p_stage.advancement_rule
  );
$$;

-- Same signature and authorization as the deployed configuration RPC.
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

create function public.levelledup_admin_create_tournament_stage(
  p_tournament_id uuid, p_stage_number integer, p_name_preset text,
  p_custom_name text default null, p_configuration jsonb default '{}'::jsonb
)
returns public.tournament_stages
language plpgsql security definer set search_path = '' set row_security = off as $$
declare
  parent public.tournaments;
  created public.tournament_stages;
begin
  perform public.levelledup_require_admin('admin');
  select * into parent from public.tournaments where id = p_tournament_id for update;
  if parent.id is null then raise exception 'Tournament not found.' using errcode = '22023'; end if;
  if parent.status in ('completed', 'cancelled') or parent.archived_at is not null then
    raise exception 'Stages cannot be added to a retired tournament.' using errcode = '22023';
  end if;
  if p_configuration is null or jsonb_typeof(p_configuration) <> 'object'
    or p_configuration ?| array['name_preset', 'custom_name', 'stage_number'] then
    raise exception 'Supply stage identity separately from configuration.' using errcode = '22023';
  end if;
  -- No sequence of presets is mandatory. A Grand Final can be Stage 1.
  -- Unique (tournament_id, stage_number) prevents duplicate orders atomically.
  insert into public.tournament_stages(tournament_id, stage_number, name_preset, custom_name)
  values(p_tournament_id, p_stage_number, p_name_preset, nullif(btrim(p_custom_name), ''))
  returning * into created;
  select * into created from public.levelledup_admin_configure_stage(created.id, p_configuration);
  return created;
end;
$$;

-- Safe lifecycle validation only: this does not start matches, advance teams,
-- cancel payments, release assignments, or expose lifecycle mutation to clients.
create function public.levelledup_guard_stage_lifecycle()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
declare
  parent public.tournaments;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'planned' then
      raise exception 'New stages must begin as planned.' using errcode = '22023';
    end if;
  elsif new.status is not distinct from old.status then
    return new;
  else
    if old.status in ('completed', 'cancelled')
      or (old.status = 'active' and new.status <> 'completed')
      or (old.status = 'planned' and new.status not in ('active', 'cancelled')) then
      raise exception 'Invalid stage lifecycle transition. Terminal stages cannot be reopened.' using errcode = '22023';
    end if;
  end if;
  select * into parent from public.tournaments where id = new.tournament_id for update;
  if parent.status in ('completed', 'cancelled') or parent.archived_at is not null then
    raise exception 'Stage lifecycle cannot change in a retired tournament.' using errcode = '22023';
  end if;
  if new.status = 'active' and parent.status <> 'live' then
    raise exception 'Tournament must be live before activating a stage.' using errcode = '22023';
  end if;
  if new.status = 'completed' and (
    not exists(select 1 from public.tournament_matches m where m.stage_id = new.id and m.status = 'completed')
    or exists(select 1 from public.tournament_matches m where m.stage_id = new.id and m.status in ('scheduled', 'live'))
  ) then
    raise exception 'Finish the stage matches before completing the stage.' using errcode = '22023';
  end if;
  if new.status = 'cancelled' and (
    new.rules_locked_at is not null
    or exists(select 1 from public.tournament_matches m where m.stage_id = new.id and m.status in ('live', 'completed'))
    or exists(select 1 from public.tournament_stage_assignments a where a.stage_id = new.id and a.status = 'assigned')
    or exists(select 1 from public.tournament_registration_paid_entries e where e.stage_id = new.id)
  ) then
    raise exception 'A stage with participation or financial history requires a dedicated retirement workflow.' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger tournament_stages_05_lifecycle_guard
before insert or update of status on public.tournament_stages
for each row execute function public.levelledup_guard_stage_lifecycle();

-- Computed setup state avoids stale mutable "ready" flags when lobbies or
-- matches change. It is deliberately separate from publication readiness.
create function public.levelledup_admin_get_stage_setup(p_tournament_id uuid)
returns table (
  stage_id uuid, stage_name text, stage_number integer, stage_status text,
  planned_lobby_count integer, matches_per_lobby integer, concurrent_lobby_capacity integer,
  advancement_count integer, advancement_rule jsonb, configuration_ready boolean,
  actual_lobby_count bigint, scheduled_lobby_count bigint, setup_state text
)
language plpgsql stable security definer set search_path = '' set row_security = off as $$
begin
  perform public.levelledup_require_admin('admin');
  return query
  select s.id, s.display_name, s.stage_number, s.status,
    s.planned_lobby_count, s.matches_per_lobby, s.concurrent_lobby_capacity,
    s.advancement_count, s.advancement_rule, s.configuration_ready,
    counts.lobbies, counts.scheduled,
    case
      when not s.configuration_ready then 'configuration_incomplete'
      when s.planned_lobby_count is null or s.concurrent_lobby_capacity is null then 'planning_incomplete'
      when counts.lobbies <> s.planned_lobby_count then 'lobbies_incomplete'
      when counts.scheduled <> s.planned_lobby_count then 'matches_incomplete'
      else 'ready'
    end
  from public.tournament_stages s
  cross join lateral (
    select count(*) as lobbies,
      count(*) filter (where schedule.matches = s.matches_per_lobby
        and schedule.last_number = s.matches_per_lobby) as scheduled
    from public.tournament_lobbies l
    cross join lateral (
      select count(*) as matches, max(m.match_number) as last_number
      from public.tournament_matches m
      where m.lobby_id = l.id and m.stage_id = s.id and m.tournament_id = s.tournament_id
        and m.status <> 'cancelled'
    ) schedule
    where l.stage_id = s.id and l.tournament_id = s.tournament_id and l.status <> 'cancelled'
  ) counts
  where s.tournament_id = p_tournament_id
  order by s.stage_number;
end;
$$;

comment on function public.levelledup_admin_get_stage_setup(uuid) is
  'Live setup summary: configuration_incomplete, planning_incomplete, lobbies_incomplete, matches_incomplete, ready. Ready means the planned lobbies have numbered, timestamped matches; it does not validate overlap/duration or schedule concurrency. No scheduling or advancement runs.';

alter function public.levelledup_stage_core_configuration(public.tournament_stages) owner to postgres;
alter function public.levelledup_admin_configure_stage(uuid, jsonb, text) owner to postgres;
alter function public.levelledup_admin_create_tournament_stage(uuid, integer, text, text, jsonb) owner to postgres;
alter function public.levelledup_guard_stage_lifecycle() owner to postgres;
alter function public.levelledup_admin_get_stage_setup(uuid) owner to postgres;
revoke all on function public.levelledup_stage_core_configuration(public.tournament_stages) from public, anon, authenticated;
revoke all on function public.levelledup_admin_configure_stage(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.levelledup_admin_create_tournament_stage(uuid, integer, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.levelledup_guard_stage_lifecycle() from public, anon, authenticated;
revoke all on function public.levelledup_admin_get_stage_setup(uuid) from public, anon, authenticated;
grant execute on function public.levelledup_admin_configure_stage(uuid, jsonb, text) to authenticated;
grant execute on function public.levelledup_admin_create_tournament_stage(uuid, integer, text, text, jsonb) to authenticated;
grant execute on function public.levelledup_admin_get_stage_setup(uuid) to authenticated;

-- Existing scoped FKs, immutable IDs/names, RLS, publication readiness and
-- first-live-match lock remain authoritative. No existing row is backfilled.
commit;
