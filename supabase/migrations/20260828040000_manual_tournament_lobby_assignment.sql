-- Manual V1 tournament lobby management.
--
-- The deployed stage/lobby schema remains the source of truth for historical
-- assignments. This correction removes automatic lobby allocation from
-- registration approval and exposes only narrowly scoped admin operations for
-- lobby creation and lobby-local slot assignment.

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
    perform 1
    from public.teams
    where teams.id = new.team_id
      and teams.status = 'active'
    for share;

    if not found then
      raise exception 'Only an active team can register for a tournament.'
        using errcode = 'P4002';
    end if;
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = new.tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.' using errcode = 'P4001';
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      raise exception 'A new tournament registration must begin as pending.'
        using errcode = 'P4003';
    end if;
  elsif new.status is distinct from old.status and not (
    (old.status = 'pending' and new.status in ('confirmed', 'rejected', 'withdrawn'))
    or (old.status = 'confirmed' and new.status = 'withdrawn')
  ) then
    raise exception 'Invalid tournament registration status transition.'
      using errcode = 'P4003';
  end if;

  if new.status = 'pending' then
    if selected_tournament.status <> 'registration_open'
      or now() < selected_tournament.registration_opens_at
      or now() > selected_tournament.registration_closes_at then
      raise exception 'Tournament registration is not currently open.'
        using errcode = 'P4004';
    end if;
  elsif new.status = 'confirmed' then
    if selected_tournament.status not in ('registration_open', 'registration_closed')
      or now() >= selected_tournament.scheduled_start_at then
      raise exception 'This tournament cannot confirm registrations now.'
        using errcode = 'P4004';
    end if;

    if new.roster_status not in ('finalized', 'locked') then
      raise exception 'Finalize the tournament Squad before approval.'
        using errcode = 'P4409';
    end if;

    select count(*)::integer
    into confirmed_count
    from public.tournament_registrations
    where tournament_id = new.tournament_id
      and status = 'confirmed'
      and id <> new.id;

    if confirmed_count >= selected_tournament.max_team_slots then
      raise exception 'The tournament has reached its overall team capacity.'
        using errcode = 'P4005';
    end if;

    if tg_op = 'UPDATE' and old.status <> 'confirmed' then
      new.confirmed_at := now();
      new.reviewed_at := now();
      new.reviewed_by := coalesce(new.reviewed_by, auth.uid());
    end if;
  elsif new.status = 'rejected' then
    if tg_op = 'UPDATE' and old.status <> 'rejected' then
      new.rejected_at := now();
      new.reviewed_at := now();
      new.reviewed_by := coalesce(new.reviewed_by, auth.uid());
    end if;
  elsif new.status = 'withdrawn' then
    if tg_op = 'UPDATE'
      and old.status = 'confirmed'
      and (
        selected_tournament.status not in ('registration_open', 'registration_closed')
        or now() >= selected_tournament.scheduled_start_at
      ) then
      raise exception 'A confirmed registration cannot be withdrawn after the tournament starts.'
        using errcode = 'P4014';
    end if;

    if tg_op = 'UPDATE' and old.status <> 'withdrawn' then
      new.withdrawn_at := now();
    end if;
  end if;

  -- Legacy tournament-wide slots remain null. Lobby-local assignments are
  -- stored in tournament_stage_assignments and may be made after confirmation.
  new.slot_number := null;
  return new;
end;
$$;

alter function public.levelledup_manage_tournament_registration_lifecycle()
  owner to postgres;
revoke all on function public.levelledup_manage_tournament_registration_lifecycle()
  from public, anon, authenticated;

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
  confirmed_count integer;
begin
  perform public.levelledup_require_admin('admin');

  if decision not in ('approve', 'reject') then
    raise exception 'Unsupported registration decision.' using errcode = 'P4401';
  end if;

  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id
  for update;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4402';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_registration.tournament_id
  for update;

  if selected_registration.status <> 'pending' then
    raise exception 'Only a pending registration can be reviewed.' using errcode = 'P4403';
  end if;

  if decision = 'reject' then
    update public.tournament_registrations
    set status = 'rejected', reviewed_by = auth.uid()
    where id = selected_registration.id
    returning * into selected_registration;

    return selected_registration;
  end if;

  if selected_registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the tournament Squad before approval.' using errcode = 'P4409';
  end if;

  if selected_tournament.status not in ('registration_open', 'registration_closed')
    or now() >= selected_tournament.scheduled_start_at then
    raise exception 'Registration cannot be approved after the tournament starts or leaves registration operations.'
      using errcode = 'P4404';
  end if;

  select count(*)::integer
  into confirmed_count
  from public.tournament_registrations
  where tournament_id = selected_tournament.id
    and status = 'confirmed';

  if confirmed_count >= selected_tournament.max_team_slots then
    raise exception 'The tournament has reached its overall team capacity.'
      using errcode = 'P4005';
  end if;

  -- The payment guard trigger remains authoritative for paid tournaments.
  -- Confirmation and lobby placement are deliberately separate operations.
  update public.tournament_registrations
  set status = 'confirmed', reviewed_by = auth.uid()
  where id = selected_registration.id
  returning * into selected_registration;

  return selected_registration;
end;
$$;

alter function public.levelledup_admin_review_tournament_registration(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_admin_review_tournament_registration(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_review_tournament_registration(uuid, text)
  to authenticated;

create or replace function public.levelledup_admin_reassign_tournament_slot(
  p_registration_id uuid,
  p_lobby_id uuid,
  p_slot_number integer
)
returns public.tournament_stage_assignments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
  selected_lobby public.tournament_lobbies;
  selected_stage public.tournament_stages;
  previous_assignment public.tournament_stage_assignments;
  created_assignment public.tournament_stage_assignments;
begin
  perform public.levelledup_require_admin('admin');

  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id
  for update;

  if selected_registration.id is null
    or selected_registration.status <> 'confirmed' then
    raise exception 'Only a confirmed registration can receive a lobby assignment.'
      using errcode = 'P4405';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_registration.tournament_id
  for update;

  if now() >= selected_tournament.scheduled_start_at then
    raise exception 'Tournament assignments cannot change after competition starts.'
      using errcode = 'P4406';
  end if;

  select lobbies.*
  into selected_lobby
  from public.tournament_lobbies as lobbies
  where lobbies.id = p_lobby_id
  for update;

  select stages.*
  into selected_stage
  from public.tournament_stages as stages
  where stages.id = selected_lobby.stage_id
  for update;

  if selected_lobby.id is null
    or selected_lobby.tournament_id <> selected_registration.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> selected_registration.tournament_id
    or selected_stage.stage_number <> 1 then
    raise exception 'Select a valid tournament lobby.' using errcode = 'P4410';
  end if;

  if p_slot_number < 1 or p_slot_number > selected_lobby.capacity then
    raise exception 'Slot must be between 1 and % for %.',
      selected_lobby.capacity,
      selected_lobby.display_label
      using errcode = 'P4412';
  end if;

  perform 1
  from public.tournament_stage_assignments as occupied
  where occupied.lobby_id = selected_lobby.id
    and occupied.slot_number = p_slot_number
    and occupied.status = 'assigned'
    and occupied.registration_id <> selected_registration.id
  for update;

  if found then
    raise exception 'That lobby slot is already occupied.' using errcode = 'P4408';
  end if;

  select assignments.*
  into previous_assignment
  from public.tournament_stage_assignments as assignments
  where assignments.registration_id = selected_registration.id
    and assignments.stage_id = selected_stage.id
    and assignments.status = 'assigned'
  for update;

  if previous_assignment.id is not null
    and previous_assignment.lobby_id = selected_lobby.id
    and previous_assignment.slot_number = p_slot_number then
    return previous_assignment;
  end if;

  if previous_assignment.id is not null then
    update public.tournament_stage_assignments
    set status = 'released', released_at = now()
    where id = previous_assignment.id;
  end if;

  insert into public.tournament_stage_assignments (
    tournament_id,
    stage_id,
    lobby_id,
    registration_id,
    slot_number,
    assigned_by
  ) values (
    selected_registration.tournament_id,
    selected_stage.id,
    selected_lobby.id,
    selected_registration.id,
    p_slot_number,
    auth.uid()
  )
  returning * into created_assignment;

  return created_assignment;
exception
  when unique_violation then
    raise exception 'That lobby slot is already occupied.' using errcode = 'P4408';
end;
$$;

alter function public.levelledup_admin_reassign_tournament_slot(uuid, uuid, integer)
  owner to postgres;
revoke all on function public.levelledup_admin_reassign_tournament_slot(uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_reassign_tournament_slot(uuid, uuid, integer)
  to authenticated;

create function public.levelledup_admin_get_tournament_lobbies(
  p_tournament_code text
)
returns table (
  stage_id uuid,
  lobby_id uuid,
  lobby_label text,
  lobby_code text,
  lobby_order integer,
  lobby_capacity integer,
  lobby_status text
)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  return query
  select
    stages.id,
    lobbies.id,
    lobbies.display_label,
    lobbies.lobby_code,
    lobbies.lobby_order,
    lobbies.capacity,
    lobbies.status
  from public.tournaments as tournaments
  join public.tournament_stages as stages
    on stages.tournament_id = tournaments.id
    and stages.stage_number = 1
  join public.tournament_lobbies as lobbies
    on lobbies.stage_id = stages.id
  where tournaments.tournament_id = upper(btrim(p_tournament_code))
  order by lobbies.lobby_order;
end;
$$;

alter function public.levelledup_admin_get_tournament_lobbies(text)
  owner to postgres;
revoke all on function public.levelledup_admin_get_tournament_lobbies(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_get_tournament_lobbies(text)
  to authenticated;

comment on function public.levelledup_admin_get_tournament_lobbies(text) is
  'Admin-only lobby identities for manual stage-one assignment controls. Does not expose stages as a V1 product feature.';

create function public.levelledup_admin_create_tournament_lobby_for_tournament(
  p_tournament_code text,
  p_capacity integer default null
)
returns public.tournament_lobbies
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_stage_id uuid;
  created_lobby public.tournament_lobbies;
begin
  perform public.levelledup_require_admin('admin');

  select stages.id
  into selected_stage_id
  from public.tournaments as tournaments
  join public.tournament_stages as stages
    on stages.tournament_id = tournaments.id
    and stages.stage_number = 1
  where tournaments.tournament_id = upper(btrim(p_tournament_code))
  for update of stages;

  if selected_stage_id is null then
    raise exception 'Tournament lobby foundation is not configured.' using errcode = 'P4414';
  end if;

  select *
  into created_lobby
  from public.levelledup_admin_create_tournament_lobby(
    selected_stage_id,
    p_capacity
  );

  return created_lobby;
end;
$$;

alter function public.levelledup_admin_create_tournament_lobby_for_tournament(text, integer)
  owner to postgres;
revoke all on function public.levelledup_admin_create_tournament_lobby_for_tournament(text, integer)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_create_tournament_lobby_for_tournament(text, integer)
  to authenticated;

comment on function public.levelledup_admin_create_tournament_lobby_for_tournament(text, integer) is
  'Creates the next ordered V1 lobby (Lobby A, B, C...) without exposing internal stage controls.';

comment on function public.levelledup_admin_review_tournament_registration(uuid, text) is
  'Admin review preserves tournament capacity checks but deliberately leaves confirmed teams unassigned for manual lobby placement.';

comment on function public.levelledup_admin_reassign_tournament_slot(uuid, uuid, integer) is
  'Assigns or moves a confirmed registration to a stage-one lobby-local slot while preserving the released assignment row.';
