begin;

alter table public.tournament_stages
  add column matches_per_lobby integer,
  add column stage_fee_minor bigint,
  add column fee_currency text,
  add column retry_allowed boolean not null default false,
  add column knockout_enabled boolean,
  add column advancement_count integer,
  add column rules_locked_at timestamptz,
  add column configuration_version bigint not null default 0;

-- Stage 1 is the legacy tournament's entry block. Mirror its existing settings
-- as configuration only: this does not charge, allocate or change any payment.
-- Advancement defaults to zero because no advancement workflow existed.
-- Unknown later-stage counts/fees/advancement remain NULL (incomplete).
alter table public.tournament_stages disable trigger tournament_stages_set_updated_at;
update public.tournament_stages as stage
set matches_per_lobby = case when stage.stage_number = 1
      then (tournament.matches_per_day::bigint * tournament.number_of_days)::integer end,
    stage_fee_minor = case when stage.stage_number = 1 then tournament.entry_fee_minor end,
    fee_currency = case when stage.stage_number = 1 then tournament.currency end,
    advancement_count = case when stage.stage_number = 1 then 0 end,
    knockout_enabled = stage.name_preset in ('quarterfinal', 'semifinal', 'grand_final'),
    rules_locked_at = case when stage.status in ('active', 'completed') or exists (
      select 1 from public.tournament_matches as match
      where match.stage_id = stage.id and match.status in ('live', 'completed')
    ) then transaction_timestamp() end
from public.tournaments as tournament
where tournament.id = stage.tournament_id;
alter table public.tournament_stages enable trigger tournament_stages_set_updated_at;

alter table public.tournament_stages
  alter column knockout_enabled set not null,
  add constraint tournament_stages_matches_per_lobby_valid check (matches_per_lobby > 0),
  add constraint tournament_stages_stage_fee_valid check (stage_fee_minor >= 0),
  add constraint tournament_stages_fee_currency_valid check (fee_currency ~ '^[A-Z]{3}$'),
  add constraint tournament_stages_advancement_valid check (advancement_count >= 0),
  add constraint tournament_stages_knockout_no_retry check (not knockout_enabled or not retry_allowed),
  add constraint tournament_stages_configuration_version_valid check (configuration_version >= 0),
  add column configuration_ready boolean generated always as (
    matches_per_lobby is not null and stage_fee_minor is not null
    and fee_currency is not null and advancement_count is not null
  ) stored;

comment on column public.tournament_stages.matches_per_lobby is
  'Configured number of matches in EACH lobby, not a tournament-wide total. NULL means incomplete; no scheduling is performed.';
comment on column public.tournament_stages.stage_fee_minor is
  'Configured stage price in fee_currency minor units; NULL is incomplete and zero explicitly means free. Existing payment/credit amounts are not rewritten.';
comment on column public.tournament_stages.advancement_count is
  'Number of teams intended to advance from each lobby; zero explicitly means no advancement. Capacity/ranking/progression validation belongs to the future advancement workflow.';
comment on column public.tournament_stages.rules_locked_at is
  'Permanent rules-lock marker set on activation or first live match. Backfill time is a migration lock marker, not an invented historical match-start time.';
comment on column public.tournament_stages.retry_allowed is
  'Permission for future repeat participation, never progression automation. Knockout always implies false; pre-start administrative slot corrections are not retries.';

create table public.tournament_stage_configuration_events (
  id uuid primary key default gen_random_uuid(),
  stage_id uuid not null,
  tournament_id uuid not null,
  event_type text not null check (event_type in ('baseline', 'configured', 'rules_locked', 'admin_override')),
  version_before bigint not null,
  version_after bigint not null,
  before_config jsonb not null,
  after_config jsonb not null,
  reason text not null check (char_length(btrim(reason)) between 10 and 1000),
  actor_user_id uuid references auth.users(id) on delete restrict,
  database_role text not null default session_user,
  transaction_id bigint not null default txid_current(),
  created_at timestamptz not null default clock_timestamp(),
  foreign key (stage_id, tournament_id)
    references public.tournament_stages(id, tournament_id) on delete restrict,
  check (event_type <> 'admin_override' or actor_user_id is not null),
  check (jsonb_typeof(before_config) = 'object' and jsonb_typeof(after_config) = 'object')
);
create index tournament_stage_configuration_events_history_idx
  on public.tournament_stage_configuration_events(stage_id, created_at);
create unique index tournament_stage_configuration_events_version_idx
  on public.tournament_stage_configuration_events(stage_id, version_after)
  where event_type in ('configured', 'admin_override');

create function public.levelledup_stage_core_configuration(p_stage public.tournament_stages)
returns jsonb language sql immutable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'name_preset', p_stage.name_preset, 'custom_name', p_stage.custom_name,
    'stage_number', p_stage.stage_number, 'tier_label', p_stage.tier_label,
    'matches_per_lobby', p_stage.matches_per_lobby,
    'stage_fee_minor', p_stage.stage_fee_minor, 'fee_currency', p_stage.fee_currency,
    'retry_allowed', p_stage.retry_allowed, 'knockout_enabled', p_stage.knockout_enabled,
    'advancement_count', p_stage.advancement_count
  );
$$;

create function public.levelledup_stage_missing_configuration(p_stage public.tournament_stages)
returns text[] language sql immutable security invoker set search_path = '' as $$
  select array_remove(array[
    case when p_stage.matches_per_lobby is null then 'Match count per lobby' end,
    case when p_stage.stage_fee_minor is null then 'Stage fee' end,
    case when p_stage.fee_currency is null then 'Fee currency' end,
    case when p_stage.advancement_count is null then 'Advancement count' end
  ], null);
$$;

insert into public.tournament_stage_configuration_events (
  stage_id, tournament_id, event_type, version_before, version_after,
  before_config, after_config, reason
)
select stage.id, stage.tournament_id, 'baseline', 0, 0,
  public.levelledup_stage_core_configuration(stage), public.levelledup_stage_core_configuration(stage),
  'Configuration baseline; Stage 1 mirrors legacy tournament settings, later unknown settings remain incomplete.'
from public.tournament_stages as stage;

create function public.levelledup_guard_stage_configuration_history()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'Stage configuration history is append-only.' using errcode = '22023';
end;
$$;
create trigger tournament_stage_configuration_events_append_only
before update or delete on public.tournament_stage_configuration_events
for each row execute function public.levelledup_guard_stage_configuration_history();

create function public.levelledup_guard_stage_configuration()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
declare
  parent_status text;
  previous_core jsonb;
  proposed_core jsonb;
begin
  if tg_op = 'INSERT' then
    new.knockout_enabled := coalesce(new.knockout_enabled,
      new.name_preset in ('quarterfinal', 'semifinal', 'grand_final'));
    new.configuration_version := 0;
  else
    if new.configuration_version is distinct from old.configuration_version then
      raise exception 'Stage configuration version is database-owned.' using errcode = '22023';
    end if;
    if old.rules_locked_at is not null and new.rules_locked_at is distinct from old.rules_locked_at then
      raise exception 'Started-stage rules cannot be unlocked or re-dated.' using errcode = '22023';
    end if;
  end if;

  new.fee_currency := nullif(upper(btrim(new.fee_currency)), '');
  select tournament.status into parent_status from public.tournaments as tournament
  where tournament.id = new.tournament_id;

  -- Do not turn the already-published entry stage back into an incomplete stage.
  if parent_status in ('registration_open', 'registration_closed', 'live') then
    if tg_op = 'UPDATE' then
      if old.stage_number = 1 and new.stage_number <> 1 then
        raise exception 'Published Stage 1 cannot be moved out of the entry position.' using errcode = '22023';
      end if;
    end if;
    if new.stage_number = 1 and cardinality(public.levelledup_stage_missing_configuration(new)) > 0 then
      raise exception 'Published Stage 1 must remain fully configured.' using errcode = '22023';
    end if;
  end if;

  if new.status in ('active', 'completed') and new.rules_locked_at is null then
    new.rules_locked_at := clock_timestamp();
  end if;
  -- Allow an existing incomplete historical stage to stay untouched, but never
  -- newly start incomplete rules. A legacy lock requires a deliberate override.
  if tg_op = 'INSERT' then
    if new.rules_locked_at is not null and cardinality(public.levelledup_stage_missing_configuration(new)) > 0 then
      raise exception 'Complete stage configuration before starting the stage.' using errcode = '22023';
    end if;
  elsif old.rules_locked_at is null and new.rules_locked_at is not null
    and cardinality(public.levelledup_stage_missing_configuration(new)) > 0 then
    raise exception 'Complete stage configuration before starting the stage.' using errcode = '22023';
  end if;

  if tg_op = 'UPDATE' then
    previous_core := public.levelledup_stage_core_configuration(old);
    proposed_core := public.levelledup_stage_core_configuration(new);
    if previous_core is distinct from proposed_core then
      new.configuration_version := old.configuration_version + 1;
      if old.rules_locked_at is not null then
        perform public.levelledup_require_admin('admin');
        if not exists (
          select 1 from public.tournament_stage_configuration_events as event
          where event.stage_id = old.id and event.event_type = 'admin_override'
            and event.transaction_id = txid_current()
            and event.actor_user_id = auth.uid()
            and event.version_before = old.configuration_version
            and event.version_after = new.configuration_version
            and event.before_config = previous_core and event.after_config = proposed_core
        ) then
          raise exception 'Started-stage rules require an explicit Admin Override with a reason.' using errcode = '22023';
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger tournament_stages_10_configuration_guard
before insert or update on public.tournament_stages
for each row execute function public.levelledup_guard_stage_configuration();

create function public.levelledup_audit_stage_configuration()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
begin
  if tg_op = 'INSERT' then
    insert into public.tournament_stage_configuration_events (
      stage_id, tournament_id, event_type, version_before, version_after,
      before_config, after_config, reason, actor_user_id
    ) values (new.id, new.tournament_id, 'configured', 0, 0, '{}'::jsonb,
      public.levelledup_stage_core_configuration(new), 'Initial stage configuration', auth.uid());
  elsif new.configuration_version <> old.configuration_version and old.rules_locked_at is null then
    insert into public.tournament_stage_configuration_events (
      stage_id, tournament_id, event_type, version_before, version_after,
      before_config, after_config, reason, actor_user_id
    ) values (new.id, new.tournament_id, 'configured', old.configuration_version, new.configuration_version,
      public.levelledup_stage_core_configuration(old), public.levelledup_stage_core_configuration(new),
      'Stage configuration updated before rules lock', auth.uid());
  end if;
  if tg_op = 'UPDATE' then
    if old.rules_locked_at is null and new.rules_locked_at is not null then
      insert into public.tournament_stage_configuration_events (
        stage_id, tournament_id, event_type, version_before, version_after,
        before_config, after_config, reason, actor_user_id
      ) values (new.id, new.tournament_id, 'rules_locked', old.configuration_version, new.configuration_version,
        public.levelledup_stage_core_configuration(old), public.levelledup_stage_core_configuration(new),
        'Stage activated or first match entered live play', auth.uid());
    end if;
  end if;
  return new;
end;
$$;
create trigger tournament_stages_audit_configuration
after insert or update on public.tournament_stages
for each row execute function public.levelledup_audit_stage_configuration();

-- JSON is a patch, not arbitrary row access. UUID, tournament, lifecycle,
-- readiness, timestamps and version are not accepted mutation fields.
create function public.levelledup_admin_configure_stage(
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
    'fee_currency', 'retry_allowed', 'knockout_enabled', 'advancement_count'
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
    -- The trigger verifies this private audit authorization against the exact
    -- row version, actor, transaction and before/after values. No spoofable GUC.
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
    advancement_count = proposed.advancement_count
  where id = previous.id returning * into proposed;
  return proposed;
end;
$$;

create function public.levelledup_guard_tournament_publish_readiness()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
begin
  if new.status in ('registration_open', 'live') then
    if tg_op = 'UPDATE' then
      if new.status is not distinct from old.status then return new; end if;
    end if;
    perform 1 from public.tournament_stages as stage
    where stage.tournament_id = new.id and stage.stage_number = 1
      and stage.configuration_ready and stage.status <> 'cancelled' for share;
    if not found then
      raise exception 'Complete Stage 1 configuration before publishing this tournament. Later stages may remain incomplete.'
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger tournaments_guard_stage_publish_readiness
before insert or update of status on public.tournaments
for each row execute function public.levelledup_guard_tournament_publish_readiness();

-- Lock configuration only. Existing match lifecycle and financial-consumption
-- triggers still run and roll this marker/audit back if starting play fails.
create function public.levelledup_lock_stage_rules_before_match_live()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
begin
  if new.status in ('live', 'completed') then
    perform 1 from public.tournaments where id = new.tournament_id for update;
    update public.tournament_stages set rules_locked_at = clock_timestamp()
    where id = new.stage_id and tournament_id = new.tournament_id and rules_locked_at is null;
  end if;
  return new;
end;
$$;
create trigger tournament_matches_00_lock_stage_rules
before insert or update of status, stage_id, tournament_id on public.tournament_matches
for each row execute function public.levelledup_lock_stage_rules_before_match_live();

create function public.levelledup_admin_get_stage_readiness(p_tournament_id uuid)
returns table (stage_id uuid, stage_name text, stage_number integer, stage_status text,
  configuration_ready boolean, rules_locked_at timestamptz, missing_fields text[], warning text)
language plpgsql stable security definer set search_path = '' set row_security = off as $$
begin
  perform public.levelledup_require_admin('admin');
  return query select stage.id, stage.display_name, stage.stage_number, stage.status,
    stage.configuration_ready, stage.rules_locked_at, public.levelledup_stage_missing_configuration(stage),
    case when not stage.configuration_ready and stage.status <> 'cancelled' then
      'Stage configuration incomplete: ' || array_to_string(public.levelledup_stage_missing_configuration(stage), ', ')
    end
  from public.tournament_stages as stage where stage.tournament_id = p_tournament_id
  order by stage.stage_number;
  if exists (select 1 from public.tournaments as tournament where tournament.id = p_tournament_id)
    and not exists (select 1 from public.tournament_stages as stage
      where stage.tournament_id = p_tournament_id and stage.stage_number = 1) then
    return query select null::uuid, 'Entry stage'::text, 1, 'missing'::text, false,
      null::timestamptz, array['Stage 1 configuration']::text[],
      'Stage 1 must be created and configured before publishing.'::text;
  end if;
end;
$$;

-- Persistent warnings are computed from database state, not dismissible UI
-- flags. This foundation does not add a dashboard widget or notifications.
comment on function public.levelledup_admin_get_stage_readiness(uuid) is
  'Authoritative per-stage readiness and persistent warnings for Admin consumers. Upcoming incomplete stages remain editable after publishing the parent tournament.';

create function public.levelledup_stage_visible_to_player(p_stage_id uuid)
returns boolean language sql stable security definer set search_path = '' set row_security = off as $$
  select public.levelledup_has_admin_role('admin') or exists (
    select 1 from public.tournament_stages as stage
    join public.tournaments as tournament on tournament.id = stage.tournament_id
    where stage.id = p_stage_id
      and (stage.configuration_ready or stage.rules_locked_at is not null)
      and tournament.status <> 'draft' and tournament.archived_at is null
  );
$$;

-- Restrictive policies compose with existing membership/public-read policies;
-- adding a permissive policy alone would not hide incomplete stage data.
create policy stage_readiness_visibility on public.tournament_stages
as restrictive for select to authenticated using (public.levelledup_stage_visible_to_player(id));
create policy lobby_stage_readiness_visibility on public.tournament_lobbies
as restrictive for select to authenticated using (public.levelledup_stage_visible_to_player(stage_id));
create policy match_stage_readiness_visibility on public.tournament_matches
as restrictive for select to authenticated using (public.levelledup_stage_visible_to_player(stage_id));
create policy assignment_stage_readiness_visibility on public.tournament_stage_assignments
as restrictive for select to authenticated using (public.levelledup_stage_visible_to_player(stage_id));
create policy stage_admin_configuration_read on public.tournament_stages
for select to authenticated using (public.levelledup_has_admin_role('admin'));
create policy lobby_admin_configuration_read on public.tournament_lobbies
for select to authenticated using (public.levelledup_has_admin_role('admin'));
create policy match_admin_configuration_read on public.tournament_matches
for select to authenticated using (public.levelledup_has_admin_role('admin'));

-- Stage-level repeat-entry gate only; no payment amounts/statuses, refunds,
-- Squad revisions or slot-allocation functions are changed.
create function public.levelledup_guard_stage_repeat_paid_entry()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
declare stage public.tournament_stages;
begin
  select s.* into stage from public.tournament_stages as s where s.id = new.stage_id for share;
  if stage.knockout_enabled then
    perform pg_advisory_xact_lock(hashtextextended('stage-entry:' || new.team_id::text || ':' || new.stage_id::text, 0));
    if exists (select 1 from public.tournament_registration_paid_entries as entry
      where entry.team_id = new.team_id and entry.stage_id = new.stage_id) then
      raise exception 'Knockout stages do not allow another paid entry or buying another slot.' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger tournament_paid_entries_knockout_repeat_guard
before insert on public.tournament_registration_paid_entries
for each row execute function public.levelledup_guard_stage_repeat_paid_entry();

create function public.levelledup_guard_stage_repeat_assignment()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
declare
  stage public.tournament_stages;
  participant_team_id uuid;
begin
  if new.status <> 'assigned' then return new; end if;
  if tg_op = 'UPDATE' then
    if old.status = 'assigned' and old.stage_id = new.stage_id
      and old.registration_id = new.registration_id then return new; end if;
  end if;
  select s.* into stage from public.tournament_stages as s where s.id = new.stage_id for share;
  select registration.team_id into participant_team_id from public.tournament_registrations as registration
  where registration.id = new.registration_id;
  if not stage.retry_allowed then
    perform pg_advisory_xact_lock(hashtextextended('stage-entry:' || participant_team_id::text || ':' || new.stage_id::text, 0));
    if exists (select 1 from public.tournament_stage_assignments as assignment
      join public.tournament_registrations as registration on registration.id = assignment.registration_id
      where registration.team_id = participant_team_id and assignment.stage_id = new.stage_id
        and (stage.rules_locked_at is not null or assignment.registration_id <> new.registration_id)) then
      raise exception 'This stage does not allow retry or resubmission. Only pre-start corrections to the same registration are allowed.' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger tournament_stage_assignments_repeat_guard
before insert or update of status, stage_id, registration_id on public.tournament_stage_assignments
for each row execute function public.levelledup_guard_stage_repeat_assignment();

alter table public.tournament_stage_configuration_events enable row level security;
revoke all on table public.tournament_stage_configuration_events from public, anon, authenticated;
grant select on table public.tournament_stage_configuration_events to authenticated;
create policy stage_configuration_events_admin_read on public.tournament_stage_configuration_events
for select to authenticated using (public.levelledup_has_admin_role('admin'));

alter function public.levelledup_stage_core_configuration(public.tournament_stages) owner to postgres;
alter function public.levelledup_stage_missing_configuration(public.tournament_stages) owner to postgres;
alter function public.levelledup_guard_stage_configuration_history() owner to postgres;
alter function public.levelledup_guard_stage_configuration() owner to postgres;
alter function public.levelledup_audit_stage_configuration() owner to postgres;
alter function public.levelledup_admin_configure_stage(uuid, jsonb, text) owner to postgres;
alter function public.levelledup_guard_tournament_publish_readiness() owner to postgres;
alter function public.levelledup_lock_stage_rules_before_match_live() owner to postgres;
alter function public.levelledup_admin_get_stage_readiness(uuid) owner to postgres;
alter function public.levelledup_stage_visible_to_player(uuid) owner to postgres;
alter function public.levelledup_guard_stage_repeat_paid_entry() owner to postgres;
alter function public.levelledup_guard_stage_repeat_assignment() owner to postgres;
revoke all on function public.levelledup_stage_core_configuration(public.tournament_stages) from public, anon, authenticated;
revoke all on function public.levelledup_stage_missing_configuration(public.tournament_stages) from public, anon, authenticated;
revoke all on function public.levelledup_guard_stage_configuration_history() from public, anon, authenticated;
revoke all on function public.levelledup_guard_stage_configuration() from public, anon, authenticated;
revoke all on function public.levelledup_audit_stage_configuration() from public, anon, authenticated;
revoke all on function public.levelledup_admin_configure_stage(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.levelledup_guard_tournament_publish_readiness() from public, anon, authenticated;
revoke all on function public.levelledup_lock_stage_rules_before_match_live() from public, anon, authenticated;
revoke all on function public.levelledup_admin_get_stage_readiness(uuid) from public, anon, authenticated;
revoke all on function public.levelledup_stage_visible_to_player(uuid) from public, anon, authenticated;
revoke all on function public.levelledup_guard_stage_repeat_paid_entry() from public, anon, authenticated;
revoke all on function public.levelledup_guard_stage_repeat_assignment() from public, anon, authenticated;
grant execute on function public.levelledup_admin_configure_stage(uuid, jsonb, text) to authenticated;
grant execute on function public.levelledup_admin_get_stage_readiness(uuid) to authenticated;
grant execute on function public.levelledup_stage_visible_to_player(uuid) to authenticated;

-- The SECURITY DEFINER slot projection bypasses table RLS, so filter it too.
-- Deployed versions may have an older RETURNS TABLE shape. PostgreSQL cannot
-- replace that shape in place. Recreate this exact signature transactionally,
-- without CASCADE so unexpected dependent objects fail safely rather than drop.
drop function if exists public.levelledup_get_tournament_slot_board(text);

create function public.levelledup_get_tournament_slot_board(p_tournament_code text)
returns table (
  tournament_name text, tournament_code text, stage_id uuid, stage_name text,
  tier_label text, stage_number integer, lobby_id uuid, lobby_label text,
  lobby_code text, lobby_order integer, lobby_capacity integer, slot_number integer,
  assignment_id uuid, registration_id uuid, team_name text, team_code text, team_status text
)
language sql stable security definer set search_path = '' set row_security = off as $$
  select tournament.name, tournament.tournament_id, stage.id, stage.display_name,
    stage.tier_label, stage.stage_number, lobby.id, lobby.display_label,
    lobby.lobby_code, lobby.lobby_order, lobby.capacity, slot.slot_number,
    case when public.levelledup_has_admin_role('admin') or exists (
      select 1 from public.team_roster_members as member
      where member.team_id = registration.team_id and member.profile_id = auth.uid() and member.status = 'active'
    ) then assignment.id end,
    case when public.levelledup_has_admin_role('admin') or exists (
      select 1 from public.team_roster_members as member
      where member.team_id = registration.team_id and member.profile_id = auth.uid() and member.status = 'active'
    ) then registration.id end,
    team.name, team.team_id, team.status
  from public.tournaments as tournament
  join public.tournament_stages as stage on stage.tournament_id = tournament.id
  join public.tournament_lobbies as lobby on lobby.stage_id = stage.id
  cross join lateral generate_series(1, lobby.capacity) as slot(slot_number)
  left join public.tournament_stage_assignments as assignment
    on assignment.lobby_id = lobby.id and assignment.slot_number = slot.slot_number and assignment.status = 'assigned'
  left join public.tournament_registrations as registration on registration.id = assignment.registration_id
  left join public.teams as team on team.id = registration.team_id
  where tournament.tournament_id = upper(btrim(p_tournament_code))
    and public.levelledup_stage_visible_to_player(stage.id)
    and ((tournament.status not in ('draft', 'cancelled') and tournament.archived_at is null)
      or public.levelledup_has_admin_role('admin'))
  order by stage.stage_number, lobby.lobby_order, slot.slot_number;
$$;
alter function public.levelledup_get_tournament_slot_board(text) owner to postgres;
revoke all on function public.levelledup_get_tournament_slot_board(text) from public, anon, authenticated;
grant execute on function public.levelledup_get_tournament_slot_board(text) to authenticated;
comment on function public.levelledup_get_tournament_slot_board(text) is
  'Authorized slot projection keyed by exact registration; disbanded teams keep paid-block assignments and expose only their lifecycle label. Incomplete unstarted stages are hidden from players.';

commit;
