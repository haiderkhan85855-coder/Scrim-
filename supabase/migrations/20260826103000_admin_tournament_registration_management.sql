begin;

create policy "Admins can read all tournament registrations"
  on public.tournament_registrations
  for select
  to authenticated
  using (public.levelledup_has_admin_role('admin'));

create policy "Admins can read all tournament roster snapshots"
  on public.tournament_registration_roster
  for select
  to authenticated
  using (public.levelledup_has_admin_role('admin'));

create policy "Admins can read registered teams"
  on public.teams
  for select
  to authenticated
  using (public.levelledup_has_admin_role('admin'));

create function public.levelledup_admin_review_tournament_registration(
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
  normalized_decision text := lower(btrim(coalesce(p_decision, '')));
  selected_tournament_id uuid;
  selected_tournament public.tournaments;
  selected_registration public.tournament_registrations;
  confirmed_count integer;
begin
  perform public.levelledup_require_admin('admin');

  if normalized_decision not in ('approve', 'reject') then
    raise exception 'Unsupported registration decision.'
      using errcode = 'P4401';
  end if;

  select tournament_registrations.tournament_id
  into selected_tournament_id
  from public.tournament_registrations
  where tournament_registrations.id = p_registration_id;

  if selected_tournament_id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4402';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = selected_tournament_id
  for update;

  select tournament_registrations.*
  into selected_registration
  from public.tournament_registrations
  where tournament_registrations.id = p_registration_id
    and tournament_registrations.tournament_id = selected_tournament.id
  for update;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4402';
  end if;

  if selected_registration.status <> 'pending' then
    raise exception 'Only a pending registration can be reviewed.'
      using errcode = 'P4403';
  end if;

  if normalized_decision = 'approve' then
    if selected_tournament.status not in (
      'registration_open',
      'registration_closed'
    ) or now() >= selected_tournament.scheduled_start_at then
      raise exception 'Registration cannot be approved after the tournament starts or leaves registration operations.'
        using errcode = 'P4404';
    end if;

    select count(*)::integer
    into confirmed_count
    from public.tournament_registrations
    where tournament_registrations.tournament_id = selected_tournament.id
      and tournament_registrations.status = 'confirmed';

    if confirmed_count >= selected_tournament.max_team_slots then
      raise exception 'Tournament is full.'
        using errcode = 'P4005';
    end if;

    update public.tournament_registrations
    set
      status = 'confirmed',
      reviewed_by = auth.uid()
    where id = selected_registration.id
    returning * into selected_registration;
  else
    update public.tournament_registrations
    set
      status = 'rejected',
      reviewed_by = auth.uid()
    where id = selected_registration.id
    returning * into selected_registration;
  end if;

  return selected_registration;
end;
$$;

alter function public.levelledup_admin_review_tournament_registration(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_admin_review_tournament_registration(uuid, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_review_tournament_registration(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_review_tournament_registration(uuid, text) is
  'Admin-only pending registration approval/rejection. Approval reuses the registration lifecycle trigger for atomic first-available slot assignment and all existing eligibility checks.';

create function public.levelledup_admin_reassign_tournament_slot(
  p_registration_id uuid,
  p_slot_number integer
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament_id uuid;
  selected_tournament public.tournaments;
  selected_registration public.tournament_registrations;
begin
  perform public.levelledup_require_admin('admin');

  select tournament_registrations.tournament_id
  into selected_tournament_id
  from public.tournament_registrations
  where tournament_registrations.id = p_registration_id;

  if selected_tournament_id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4402';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = selected_tournament_id
  for update;

  select tournament_registrations.*
  into selected_registration
  from public.tournament_registrations
  where tournament_registrations.id = p_registration_id
    and tournament_registrations.tournament_id = selected_tournament.id
  for update;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4402';
  end if;

  if selected_registration.status <> 'confirmed' then
    raise exception 'Only a confirmed registration has an assignable slot.'
      using errcode = 'P4405';
  end if;

  if now() >= selected_tournament.scheduled_start_at then
    raise exception 'Tournament slots cannot be changed after the tournament starts.'
      using errcode = 'P4406';
  end if;

  if selected_tournament.status not in (
    'registration_open',
    'registration_closed'
  ) then
    raise exception 'Slots can be changed only during tournament registration operations.'
      using errcode = 'P4406';
  end if;

  if p_slot_number is null
    or p_slot_number < 1
    or p_slot_number > selected_tournament.max_team_slots then
    raise exception 'Slot must be between 1 and %.', selected_tournament.max_team_slots
      using errcode = 'P4407';
  end if;

  if exists (
    select 1
    from public.tournament_registrations as occupied
    where occupied.tournament_id = selected_tournament.id
      and occupied.status = 'confirmed'
      and occupied.slot_number = p_slot_number
      and occupied.id <> selected_registration.id
  ) then
    raise exception 'Slot % is already occupied.', p_slot_number
      using errcode = 'P4408';
  end if;

  update public.tournament_registrations
  set slot_number = p_slot_number
  where id = selected_registration.id
  returning * into selected_registration;

  return selected_registration;
exception
  when unique_violation then
    raise exception 'Slot % is already occupied.', p_slot_number
      using errcode = 'P4408';
end;
$$;

alter function public.levelledup_admin_reassign_tournament_slot(uuid, integer)
  owner to postgres;

revoke all on function public.levelledup_admin_reassign_tournament_slot(uuid, integer)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_reassign_tournament_slot(uuid, integer)
  to authenticated;

comment on function public.levelledup_admin_reassign_tournament_slot(uuid, integer) is
  'Admin-only pre-start slot reassignment. Tournament locking and the existing partial unique index prevent concurrent duplicate slot allocation; occupied slots are never silently swapped.';

commit;
