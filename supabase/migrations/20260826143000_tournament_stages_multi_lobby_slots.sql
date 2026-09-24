begin;

alter table public.tournaments
  add column default_lobby_capacity integer,
  add column max_lobbies integer,
  add column lobby_overflow_mode text not null default 'automatic';

update public.tournaments
set
  default_lobby_capacity = 16,
  max_lobbies = greatest(1, ceil(max_team_slots / 16.0)::integer);

alter table public.tournaments
  alter column default_lobby_capacity set not null,
  alter column max_lobbies set not null,
  add constraint tournaments_lobby_capacity_valid check (
    default_lobby_capacity between 1 and 100
  ),
  add constraint tournaments_max_lobbies_valid check (
    max_lobbies between 1 and 100
  ),
  add constraint tournaments_lobby_overflow_mode_valid check (
    lobby_overflow_mode in ('automatic', 'manual')
  ),
  add constraint tournaments_lobby_capacity_covers_team_limit check (
    max_team_slots <= default_lobby_capacity * max_lobbies
  );

comment on column public.tournaments.max_team_slots is
  'Tournament-wide maximum confirmed-team count across every stage-one lobby. Lobby-local capacity is configured separately.';
comment on column public.tournaments.default_lobby_capacity is
  'Default capacity used when creating tournament lobbies. V1 defaults to 16 and is never inferred by application code.';
comment on column public.tournaments.max_lobbies is
  'Maximum number of lobbies allowed in a single stage. Tournament-wide max_team_slots remains the overall confirmation ceiling.';
comment on column public.tournaments.lobby_overflow_mode is
  'Automatic fills/creates ordered lobbies up to configured limits; manual requires an administrator-created lobby with space.';

create function public.levelledup_sync_default_lobby_limits()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  old_derived_max integer;
begin
  if tg_op = 'INSERT' then
    new.default_lobby_capacity := coalesce(new.default_lobby_capacity, 16);
    new.max_lobbies := coalesce(
      new.max_lobbies,
      greatest(1, ceil(new.max_team_slots / new.default_lobby_capacity::numeric)::integer)
    );
  else
    old_derived_max := greatest(
      1,
      ceil(old.max_team_slots / old.default_lobby_capacity::numeric)::integer
    );

    if (new.max_team_slots is distinct from old.max_team_slots
        or new.default_lobby_capacity is distinct from old.default_lobby_capacity)
      and new.max_lobbies is not distinct from old.max_lobbies
      and old.max_lobbies = old_derived_max then
      new.max_lobbies := greatest(
        1,
        ceil(new.max_team_slots / new.default_lobby_capacity::numeric)::integer
      );
    end if;
  end if;

  return new;
end;
$$;

alter function public.levelledup_sync_default_lobby_limits() owner to postgres;
revoke all on function public.levelledup_sync_default_lobby_limits()
  from public, anon, authenticated;

create trigger tournaments_sync_default_lobby_limits
before insert or update of max_team_slots, default_lobby_capacity, max_lobbies
on public.tournaments
for each row execute function public.levelledup_sync_default_lobby_limits();

create table public.tournament_stages (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments (id) on delete restrict,
  stage_number integer not null,
  display_name text not null,
  tier_label text,
  status text not null default 'planned',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_stages_number_positive check (stage_number >= 1),
  constraint tournament_stages_name_valid check (
    display_name = btrim(display_name) and char_length(display_name) between 1 and 100
  ),
  constraint tournament_stages_tier_valid check (
    tier_label is null or (tier_label = btrim(tier_label) and char_length(tier_label) between 1 and 80)
  ),
  constraint tournament_stages_status_valid check (
    status in ('planned', 'active', 'completed', 'cancelled')
  ),
  constraint tournament_stages_order_unique unique (tournament_id, stage_number),
  constraint tournament_stages_id_tournament_unique unique (id, tournament_id)
);

create index tournament_stages_tournament_status_idx
  on public.tournament_stages (tournament_id, status, stage_number);

create table public.tournament_lobbies (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null,
  stage_id uuid not null,
  lobby_code text not null,
  display_label text not null,
  lobby_order integer not null,
  capacity integer not null,
  status text not null default 'open',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_lobbies_stage_fk
    foreign key (stage_id, tournament_id)
    references public.tournament_stages (id, tournament_id) on delete restrict,
  constraint tournament_lobbies_order_positive check (lobby_order >= 1),
  constraint tournament_lobbies_capacity_valid check (capacity between 1 and 100),
  constraint tournament_lobbies_code_valid check (
    lobby_code = upper(btrim(lobby_code)) and lobby_code ~ '^[A-Z0-9]{1,12}$'
  ),
  constraint tournament_lobbies_label_valid check (
    display_label = btrim(display_label) and char_length(display_label) between 1 and 80
  ),
  constraint tournament_lobbies_status_valid check (
    status in ('planned', 'open', 'locked', 'completed', 'cancelled')
  ),
  constraint tournament_lobbies_order_unique unique (stage_id, lobby_order),
  constraint tournament_lobbies_code_unique unique (stage_id, lobby_code),
  constraint tournament_lobbies_id_scope_unique unique (id, stage_id, tournament_id)
);

create index tournament_lobbies_stage_status_idx
  on public.tournament_lobbies (stage_id, status, lobby_order);

create table public.tournament_stage_assignments (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null,
  stage_id uuid not null,
  lobby_id uuid not null,
  registration_id uuid not null,
  slot_number integer not null,
  status text not null default 'assigned',
  assigned_at timestamptz not null default now(),
  assigned_by uuid references auth.users (id) on delete restrict,
  released_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_stage_assignments_registration_fk
    foreign key (registration_id, tournament_id)
    references public.tournament_registrations (id, tournament_id) on delete restrict,
  constraint tournament_stage_assignments_lobby_fk
    foreign key (lobby_id, stage_id, tournament_id)
    references public.tournament_lobbies (id, stage_id, tournament_id) on delete restrict,
  constraint tournament_stage_assignments_slot_positive check (slot_number >= 1),
  constraint tournament_stage_assignments_status_valid check (
    status in ('assigned', 'released')
  ),
  constraint tournament_stage_assignments_release_state_valid check (
    (status = 'assigned' and released_at is null)
    or (status = 'released' and released_at is not null)
  )
);

create unique index tournament_stage_assignments_active_lobby_slot_idx
  on public.tournament_stage_assignments (lobby_id, slot_number)
  where status = 'assigned';
create unique index tournament_stage_assignments_active_registration_stage_idx
  on public.tournament_stage_assignments (registration_id, stage_id)
  where status = 'assigned';
create index tournament_stage_assignments_registration_history_idx
  on public.tournament_stage_assignments (registration_id, assigned_at desc);
create index tournament_stage_assignments_stage_lobby_idx
  on public.tournament_stage_assignments (stage_id, lobby_id, slot_number)
  where status = 'assigned';

comment on table public.tournament_stages is
  'First-class ordered tournament phases. Advancement creates a new stage assignment rather than overwriting earlier history.';
comment on table public.tournament_lobbies is
  'Stage-local competition lobbies with explicit capacity and stable identity.';
comment on table public.tournament_stage_assignments is
  'Historical registration assignment to one stage, lobby and lobby-scoped slot. Released rows remain preserved.';

create function public.levelledup_stage_lobby_updated_at()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin new.updated_at := now(); return new; end;
$$;
alter function public.levelledup_stage_lobby_updated_at() owner to postgres;
revoke all on function public.levelledup_stage_lobby_updated_at()
  from public, anon, authenticated;

create trigger tournament_stages_set_updated_at
before update on public.tournament_stages for each row
execute function public.levelledup_stage_lobby_updated_at();
create trigger tournament_lobbies_set_updated_at
before update on public.tournament_lobbies for each row
execute function public.levelledup_stage_lobby_updated_at();
create trigger tournament_stage_assignments_set_updated_at
before update on public.tournament_stage_assignments for each row
execute function public.levelledup_stage_lobby_updated_at();

insert into public.tournament_stages (
  tournament_id, stage_number, display_name, tier_label, status
)
select
  tournaments.id,
  1,
  'Qualifier',
  'Tier 1',
  case when tournaments.status in ('live', 'completed') then 'active' else 'planned' end
from public.tournaments as tournaments;

insert into public.tournament_lobbies (
  tournament_id, stage_id, lobby_code, display_label, lobby_order, capacity, status
)
select
  stages.tournament_id,
  stages.id,
  case when lobby_numbers.lobby_order <= 26
    then chr(64 + lobby_numbers.lobby_order)
    else 'L' || lobby_numbers.lobby_order::text
  end,
  case when lobby_numbers.lobby_order <= 26
    then 'Lobby ' || chr(64 + lobby_numbers.lobby_order)
    else 'Lobby ' || lobby_numbers.lobby_order::text
  end,
  lobby_numbers.lobby_order,
  tournaments.default_lobby_capacity,
  case when tournaments.status in ('live', 'completed') then 'locked' else 'open' end
from public.tournament_stages as stages
join public.tournaments as tournaments on tournaments.id = stages.tournament_id
cross join lateral generate_series(
  1,
  greatest(
    1,
    coalesce((
      select ceil(max(registrations.slot_number) / tournaments.default_lobby_capacity::numeric)::integer
      from public.tournament_registrations as registrations
      where registrations.tournament_id = tournaments.id
        and registrations.status = 'confirmed'
    ), 1)
  )
) as lobby_numbers(lobby_order)
where stages.stage_number = 1;

insert into public.tournament_stage_assignments (
  tournament_id, stage_id, lobby_id, registration_id, slot_number,
  status, assigned_at, assigned_by
)
select
  registrations.tournament_id,
  stages.id,
  lobbies.id,
  registrations.id,
  ((registrations.slot_number - 1) % lobbies.capacity) + 1,
  'assigned',
  coalesce(registrations.confirmed_at, registrations.registered_at),
  registrations.reviewed_by
from public.tournament_registrations as registrations
join public.tournament_stages as stages
  on stages.tournament_id = registrations.tournament_id and stages.stage_number = 1
join public.tournament_lobbies as lobbies
  on lobbies.stage_id = stages.id
  and lobbies.lobby_order = ((registrations.slot_number - 1) / lobbies.capacity) + 1
where registrations.status = 'confirmed'
  and registrations.slot_number is not null;

drop index if exists public.tournament_registrations_confirmed_slot_idx;
alter table public.tournament_registrations
  drop constraint tournament_registrations_slot_state_valid;
comment on column public.tournament_registrations.slot_number is
  'Deprecated legacy tournament-global slot retained only for migration compatibility. Authoritative assignments live in tournament_stage_assignments.';

create or replace function public.levelledup_guard_tournament_slot_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  confirmed_count integer;
begin
  if new.max_team_slots < old.max_team_slots then
    select count(*)::integer into confirmed_count
    from public.tournament_registrations
    where tournament_id = old.id and status = 'confirmed';
    if new.max_team_slots < confirmed_count then
      raise exception 'The tournament team limit cannot be lower than its % confirmed teams.', confirmed_count
        using errcode = 'P4007';
    end if;
  end if;
  return new;
end;
$$;
alter function public.levelledup_guard_tournament_slot_limit() owner to postgres;
revoke all on function public.levelledup_guard_tournament_slot_limit()
  from public, anon, authenticated;

create or replace function public.levelledup_manage_tournament_registration_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
  confirmed_count integer;
begin
  if new.status in ('pending', 'confirmed') then
    perform 1 from public.teams
    where teams.id = new.team_id and teams.status = 'active' for share;
    if not found then
      raise exception 'Only an active team can register for a tournament.' using errcode = 'P4002';
    end if;
  end if;

  select tournaments.* into selected_tournament
  from public.tournaments where tournaments.id = new.tournament_id for update;
  if selected_tournament.id is null then
    raise exception 'Tournament not found.' using errcode = 'P4001';
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      raise exception 'A new tournament registration must begin as pending.' using errcode = 'P4003';
    end if;
  elsif new.status is distinct from old.status and not (
    (old.status = 'pending' and new.status in ('confirmed', 'rejected', 'withdrawn'))
    or (old.status = 'confirmed' and new.status = 'withdrawn')
  ) then
    raise exception 'Invalid tournament registration status transition.' using errcode = 'P4003';
  end if;

  if new.status = 'pending' then
    if selected_tournament.status <> 'registration_open'
      or now() < selected_tournament.registration_opens_at
      or now() > selected_tournament.registration_closes_at then
      raise exception 'Tournament registration is not currently open.' using errcode = 'P4004';
    end if;
  elsif new.status = 'confirmed' then
    if selected_tournament.status not in ('registration_open', 'registration_closed')
      or now() >= selected_tournament.scheduled_start_at then
      raise exception 'This tournament cannot confirm registrations now.' using errcode = 'P4004';
    end if;
    if new.roster_status not in ('finalized', 'locked') then
      raise exception 'Finalize the tournament roster before approval.' using errcode = 'P4409';
    end if;
    if not exists (
      select 1 from public.tournament_stage_assignments as assignments
      where assignments.registration_id = new.id and assignments.status = 'assigned'
    ) then
      raise exception 'A lobby assignment is required before confirmation.' using errcode = 'P4415';
    end if;
    select count(*)::integer into confirmed_count
    from public.tournament_registrations
    where tournament_id = new.tournament_id and status = 'confirmed' and id <> new.id;
    if confirmed_count >= selected_tournament.max_team_slots then
      raise exception 'The tournament has reached its overall team capacity.' using errcode = 'P4005';
    end if;
    if tg_op = 'UPDATE' and old.status <> 'confirmed' then
      new.confirmed_at := now(); new.reviewed_at := now();
      new.reviewed_by := coalesce(new.reviewed_by, auth.uid());
    end if;
  elsif new.status = 'rejected' then
    if tg_op = 'UPDATE' and old.status <> 'rejected' then
      new.rejected_at := now(); new.reviewed_at := now();
      new.reviewed_by := coalesce(new.reviewed_by, auth.uid());
    end if;
  elsif new.status = 'withdrawn' then
    if tg_op = 'UPDATE' and old.status = 'confirmed'
      and (selected_tournament.status not in ('registration_open', 'registration_closed')
        or now() >= selected_tournament.scheduled_start_at) then
      raise exception 'A confirmed registration cannot be withdrawn after the tournament starts.' using errcode = 'P4014';
    end if;
    if tg_op = 'UPDATE' and old.status <> 'withdrawn' then new.withdrawn_at := now(); end if;
  end if;

  new.slot_number := null;
  return new;
end;
$$;

alter function public.levelledup_manage_tournament_registration_lifecycle() owner to postgres;
revoke all on function public.levelledup_manage_tournament_registration_lifecycle()
  from public, anon, authenticated;

create function public.levelledup_guard_stage_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_lobby public.tournament_lobbies;
  selected_registration public.tournament_registrations;
begin
  select lobbies.* into selected_lobby from public.tournament_lobbies as lobbies
  where lobbies.id = new.lobby_id for update;
  if selected_lobby.id is null or selected_lobby.tournament_id <> new.tournament_id
    or selected_lobby.stage_id <> new.stage_id then
    raise exception 'Lobby assignment scope is invalid.' using errcode = 'P4410';
  end if;
  if selected_lobby.status not in ('planned', 'open') then
    raise exception 'The selected lobby is not accepting assignments.' using errcode = 'P4411';
  end if;
  if new.slot_number < 1 or new.slot_number > selected_lobby.capacity then
    raise exception 'Slot must be between 1 and % for %.', selected_lobby.capacity, selected_lobby.display_label using errcode = 'P4412';
  end if;
  select registrations.* into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = new.registration_id for update;
  if selected_registration.id is null
    or selected_registration.tournament_id <> new.tournament_id
    or selected_registration.status not in ('pending', 'confirmed')
    or selected_registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Only an eligible finalized registration can receive an assignment.' using errcode = 'P4413';
  end if;
  return new;
end;
$$;

alter function public.levelledup_guard_stage_assignment() owner to postgres;
revoke all on function public.levelledup_guard_stage_assignment()
  from public, anon, authenticated;
create trigger tournament_stage_assignments_guard
before insert or update of tournament_id, stage_id, lobby_id, registration_id, slot_number, status
on public.tournament_stage_assignments for each row
execute function public.levelledup_guard_stage_assignment();

create function public.levelledup_release_assignments_on_withdrawal()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
begin
  if new.status = 'withdrawn' and old.status is distinct from 'withdrawn' then
    update public.tournament_stage_assignments
    set status = 'released', released_at = now()
    where registration_id = new.id and status = 'assigned';
  end if;
  return new;
end;
$$;
alter function public.levelledup_release_assignments_on_withdrawal() owner to postgres;
revoke all on function public.levelledup_release_assignments_on_withdrawal()
  from public, anon, authenticated;
create trigger tournament_registrations_release_stage_assignments
after update of status on public.tournament_registrations for each row
execute function public.levelledup_release_assignments_on_withdrawal();

create or replace function public.levelledup_admin_review_tournament_registration(
  p_registration_id uuid,
  p_decision text
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  decision text := lower(btrim(coalesce(p_decision, '')));
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
  selected_stage public.tournament_stages;
  selected_lobby public.tournament_lobbies;
  assigned_slot integer;
  confirmed_count integer;
  lobby_count integer;
  new_lobby_order integer;
  new_lobby_code text;
begin
  perform public.levelledup_require_admin('admin');
  if decision not in ('approve', 'reject') then
    raise exception 'Unsupported registration decision.' using errcode = 'P4401';
  end if;

  select registrations.* into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id for update;
  if selected_registration.id is null then raise exception 'Tournament registration not found.' using errcode = 'P4402'; end if;

  select tournaments.* into selected_tournament from public.tournaments as tournaments
  where tournaments.id = selected_registration.tournament_id for update;
  if selected_registration.status <> 'pending' then raise exception 'Only a pending registration can be reviewed.' using errcode = 'P4403'; end if;

  if decision = 'reject' then
    update public.tournament_registrations set status = 'rejected', reviewed_by = auth.uid()
    where id = selected_registration.id returning * into selected_registration;
    return selected_registration;
  end if;

  if selected_registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the tournament roster before approval.' using errcode = 'P4409';
  end if;
  if selected_tournament.status not in ('registration_open', 'registration_closed')
    or now() >= selected_tournament.scheduled_start_at then
    raise exception 'Registration cannot be approved after the tournament starts or leaves registration operations.' using errcode = 'P4404';
  end if;
  select count(*)::integer into confirmed_count from public.tournament_registrations
  where tournament_id = selected_tournament.id and status = 'confirmed';
  if confirmed_count >= selected_tournament.max_team_slots then
    raise exception 'The tournament has reached its overall team capacity.' using errcode = 'P4005';
  end if;

  select stages.* into selected_stage from public.tournament_stages as stages
  where stages.tournament_id = selected_tournament.id
    and stages.status in ('active', 'planned')
  order by case stages.status when 'active' then 0 else 1 end, stages.stage_number
  limit 1 for update;
  if selected_stage.id is null then raise exception 'No eligible tournament stage is configured.' using errcode = 'P4414'; end if;

  select lobbies.* into selected_lobby
  from public.tournament_lobbies as lobbies
  cross join lateral (
    select slots.slot_number
    from generate_series(1, lobbies.capacity) as slots(slot_number)
    where not exists (
      select 1 from public.tournament_stage_assignments as occupied
      where occupied.lobby_id = lobbies.id and occupied.slot_number = slots.slot_number
        and occupied.status = 'assigned'
    ) order by slots.slot_number limit 1
  ) as free_slots
  where lobbies.stage_id = selected_stage.id and lobbies.status in ('planned', 'open')
  order by lobbies.lobby_order limit 1 for update of lobbies;

  if selected_lobby.id is not null then
    select slots.slot_number into assigned_slot
    from generate_series(1, selected_lobby.capacity) as slots(slot_number)
    where not exists (
      select 1 from public.tournament_stage_assignments as occupied
      where occupied.lobby_id = selected_lobby.id
        and occupied.slot_number = slots.slot_number
        and occupied.status = 'assigned'
    )
    order by slots.slot_number limit 1;
  end if;

  if selected_lobby.id is null and selected_tournament.lobby_overflow_mode = 'automatic' then
    select count(*)::integer, coalesce(max(lobby_order), 0) + 1
    into lobby_count, new_lobby_order
    from public.tournament_lobbies where stage_id = selected_stage.id;
    if lobby_count >= selected_tournament.max_lobbies then
      raise exception 'All configured tournament lobbies are full.' using errcode = 'P4005';
    end if;
    new_lobby_code := case when new_lobby_order <= 26 then chr(64 + new_lobby_order) else 'L' || new_lobby_order::text end;
    insert into public.tournament_lobbies (
      tournament_id, stage_id, lobby_code, display_label, lobby_order, capacity, status
    ) values (
      selected_tournament.id, selected_stage.id, new_lobby_code,
      case when new_lobby_order <= 26 then 'Lobby ' || new_lobby_code else 'Lobby ' || new_lobby_order::text end,
      new_lobby_order, selected_tournament.default_lobby_capacity, 'open'
    ) returning * into selected_lobby;
    assigned_slot := 1;
  elsif selected_lobby.id is null then
    raise exception 'No manually configured lobby has an available slot.' using errcode = 'P4414';
  end if;

  insert into public.tournament_stage_assignments (
    tournament_id, stage_id, lobby_id, registration_id, slot_number, assigned_by
  ) values (
    selected_tournament.id, selected_stage.id, selected_lobby.id,
    selected_registration.id, assigned_slot, auth.uid()
  );

  update public.tournament_registrations set status = 'confirmed', reviewed_by = auth.uid()
  where id = selected_registration.id returning * into selected_registration;
  return selected_registration;
exception when unique_violation then
  raise exception 'The selected lobby slot was assigned concurrently. Retry approval.' using errcode = 'P4416';
end;
$$;

alter function public.levelledup_admin_review_tournament_registration(uuid, text) owner to postgres;
revoke all on function public.levelledup_admin_review_tournament_registration(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_review_tournament_registration(uuid, text) to authenticated;

drop function public.levelledup_admin_reassign_tournament_slot(uuid, integer);

create function public.levelledup_admin_reassign_tournament_slot(
  p_registration_id uuid,
  p_lobby_id uuid,
  p_slot_number integer
)
returns public.tournament_stage_assignments
language plpgsql security definer set search_path = '' set row_security = off
as $$
declare
  selected_assignment public.tournament_stage_assignments;
  selected_tournament public.tournaments;
begin
  perform public.levelledup_require_admin('admin');
  select assignments.* into selected_assignment
  from public.tournament_stage_assignments as assignments
  join public.tournament_stages as stages on stages.id = assignments.stage_id
  where assignments.registration_id = p_registration_id
    and assignments.status = 'assigned'
    and stages.status in ('planned', 'active')
  order by stages.stage_number desc limit 1 for update of assignments;
  if selected_assignment.id is null then raise exception 'Active stage assignment not found.' using errcode = 'P4405'; end if;
  select tournaments.* into selected_tournament from public.tournaments as tournaments
  where tournaments.id = selected_assignment.tournament_id for update;
  if now() >= selected_tournament.scheduled_start_at then raise exception 'Tournament assignments cannot change after competition starts.' using errcode = 'P4406'; end if;
  update public.tournament_stage_assignments
  set lobby_id = p_lobby_id, slot_number = p_slot_number, assigned_by = auth.uid(), assigned_at = now()
  where id = selected_assignment.id returning * into selected_assignment;
  return selected_assignment;
exception when unique_violation then
  raise exception 'That lobby slot is already occupied.' using errcode = 'P4408';
end;
$$;
alter function public.levelledup_admin_reassign_tournament_slot(uuid, uuid, integer) owner to postgres;
revoke all on function public.levelledup_admin_reassign_tournament_slot(uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_reassign_tournament_slot(uuid, uuid, integer) to authenticated;

create function public.levelledup_admin_create_tournament_lobby(
  p_stage_id uuid,
  p_capacity integer default null
)
returns public.tournament_lobbies
language plpgsql security definer set search_path = '' set row_security = off
as $$
declare
  selected_stage public.tournament_stages;
  selected_tournament public.tournaments;
  created_lobby public.tournament_lobbies;
  lobby_count integer;
  next_order integer;
  next_code text;
  selected_capacity integer;
begin
  perform public.levelledup_require_admin('admin');
  select stages.* into selected_stage from public.tournament_stages as stages
  where stages.id = p_stage_id for update;
  if selected_stage.id is null then raise exception 'Tournament stage not found.' using errcode = 'P4414'; end if;
  select tournaments.* into selected_tournament from public.tournaments as tournaments
  where tournaments.id = selected_stage.tournament_id for update;
  if now() >= selected_tournament.scheduled_start_at then
    raise exception 'Tournament lobbies cannot be created after competition starts.' using errcode = 'P4406';
  end if;
  select count(*)::integer, coalesce(max(lobby_order), 0) + 1
  into lobby_count, next_order from public.tournament_lobbies
  where stage_id = selected_stage.id;
  if lobby_count >= selected_tournament.max_lobbies then
    raise exception 'The stage has reached its configured lobby limit.' using errcode = 'P4005';
  end if;
  selected_capacity := coalesce(p_capacity, selected_tournament.default_lobby_capacity);
  if selected_capacity < 1 or selected_capacity > 100 then
    raise exception 'Lobby capacity must be between 1 and 100.' using errcode = 'P4412';
  end if;
  next_code := case when next_order <= 26 then chr(64 + next_order) else 'L' || next_order::text end;
  insert into public.tournament_lobbies (
    tournament_id, stage_id, lobby_code, display_label, lobby_order, capacity, status
  ) values (
    selected_tournament.id, selected_stage.id, next_code,
    case when next_order <= 26 then 'Lobby ' || next_code else 'Lobby ' || next_order::text end,
    next_order, selected_capacity, 'open'
  ) returning * into created_lobby;
  return created_lobby;
end;
$$;
alter function public.levelledup_admin_create_tournament_lobby(uuid, integer) owner to postgres;
revoke all on function public.levelledup_admin_create_tournament_lobby(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_create_tournament_lobby(uuid, integer) to authenticated;

alter table public.tournament_matches
  add column stage_id uuid,
  add column lobby_id uuid;

update public.tournament_matches as matches
set
  stage_id = stages.id,
  lobby_id = lobbies.id
from public.tournament_stages as stages
join public.tournament_lobbies as lobbies
  on lobbies.stage_id = stages.id and lobbies.lobby_order = 1
where stages.tournament_id = matches.tournament_id and stages.stage_number = 1;

alter table public.tournament_matches
  alter column stage_id set not null,
  alter column lobby_id set not null,
  add constraint tournament_matches_lobby_scope_fk
    foreign key (lobby_id, stage_id, tournament_id)
    references public.tournament_lobbies (id, stage_id, tournament_id) on delete restrict,
  drop constraint tournament_matches_number_per_tournament_unique,
  add constraint tournament_matches_number_per_lobby_unique unique (lobby_id, match_number);

comment on column public.tournament_matches.stage_id is
  'Competition stage containing this match.';
comment on column public.tournament_matches.lobby_id is
  'Stage lobby containing this match. Match numbers repeat safely across lobbies.';

alter table public.tournament_stages enable row level security;
alter table public.tournament_lobbies enable row level security;
alter table public.tournament_stage_assignments enable row level security;
revoke all on table public.tournament_stages from public, anon, authenticated;
revoke all on table public.tournament_lobbies from public, anon, authenticated;
revoke all on table public.tournament_stage_assignments from public, anon, authenticated;
grant select on table public.tournament_stages to authenticated;
grant select on table public.tournament_lobbies to authenticated;
grant select on table public.tournament_stage_assignments to authenticated;

create policy "Authenticated users can read public tournament stages"
  on public.tournament_stages for select to authenticated
  using (exists (
    select 1 from public.tournaments
    where tournaments.id = tournament_stages.tournament_id
      and tournaments.status <> 'draft' and tournaments.archived_at is null
  ));
create policy "Authenticated users can read public tournament lobbies"
  on public.tournament_lobbies for select to authenticated
  using (exists (
    select 1 from public.tournaments
    where tournaments.id = tournament_lobbies.tournament_id
      and tournaments.status <> 'draft' and tournaments.archived_at is null
  ));
create policy "Members and admins can read stage assignments"
  on public.tournament_stage_assignments for select to authenticated
  using (
    public.levelledup_has_admin_role('admin')
    or exists (
      select 1 from public.tournament_registrations as registrations
      join public.team_roster_members as members on members.team_id = registrations.team_id
      where registrations.id = tournament_stage_assignments.registration_id
        and members.profile_id = auth.uid() and members.status = 'active'
    )
  );

create function public.levelledup_get_tournament_slot_board(p_tournament_code text)
returns table (
  tournament_name text,
  tournament_code text,
  stage_name text,
  tier_label text,
  stage_number integer,
  lobby_label text,
  lobby_code text,
  lobby_order integer,
  lobby_capacity integer,
  slot_number integer,
  team_name text,
  team_code text,
  is_current_user_team boolean
)
language sql stable security definer set search_path = '' set row_security = off
as $$
  select
    tournaments.name,
    tournaments.tournament_id,
    stages.display_name,
    stages.tier_label,
    stages.stage_number,
    lobbies.display_label,
    lobbies.lobby_code,
    lobbies.lobby_order,
    lobbies.capacity,
    slots.slot_number,
    teams.name,
    teams.team_id,
    coalesce(exists (
      select 1 from public.team_roster_members as current_membership
      where current_membership.team_id = registrations.team_id
        and current_membership.profile_id = auth.uid()
        and current_membership.status = 'active'
    ), false)
  from public.tournaments as tournaments
  join public.tournament_stages as stages on stages.tournament_id = tournaments.id
  join public.tournament_lobbies as lobbies on lobbies.stage_id = stages.id
  cross join lateral generate_series(1, lobbies.capacity) as slots(slot_number)
  left join public.tournament_stage_assignments as assignments
    on assignments.lobby_id = lobbies.id and assignments.slot_number = slots.slot_number
    and assignments.status = 'assigned'
  left join public.tournament_registrations as registrations
    on registrations.id = assignments.registration_id
  left join public.teams as teams on teams.id = registrations.team_id
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
alter function public.levelledup_get_tournament_slot_board(text) owner to postgres;
revoke all on function public.levelledup_get_tournament_slot_board(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_get_tournament_slot_board(text) to authenticated;

commit;
