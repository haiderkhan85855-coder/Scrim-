begin;

create or replace function public.levelledup_admin_transition_tournament(
  p_tournament_id uuid,
  p_action text
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
  normalized_action text := lower(btrim(p_action));
begin
  perform public.levelledup_require_admin('admin');

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4301';
  end if;

  if normalized_action = 'open_registration' then
    if selected_tournament.status <> 'draft' then
      raise exception 'Only a draft tournament can open registration.'
        using errcode = 'P4303';
    end if;

    if now() < selected_tournament.registration_opens_at then
      raise exception 'Registration has not reached its configured opening time.'
        using errcode = 'P4304';
    end if;

    if now() > selected_tournament.registration_closes_at then
      raise exception 'The configured registration window has closed.'
        using errcode = 'P4304';
    end if;

    if now() >= selected_tournament.scheduled_start_at then
      raise exception 'Registration cannot open after the tournament starts.'
        using errcode = 'P4304';
    end if;

    update public.tournaments
    set status = 'registration_open'
    where id = selected_tournament.id
    returning * into selected_tournament;
  elsif normalized_action = 'close_registration' then
    if selected_tournament.status <> 'registration_open' then
      raise exception 'Only an open registration can be closed.'
        using errcode = 'P4303';
    end if;

    update public.tournaments
    set status = 'registration_closed'
    where id = selected_tournament.id
    returning * into selected_tournament;
  elsif normalized_action = 'cancel' then
    if selected_tournament.status in ('completed', 'cancelled') then
      raise exception 'Completed or cancelled tournaments cannot be cancelled again.'
        using errcode = 'P4303';
    end if;

    update public.tournaments
    set status = 'cancelled'
    where id = selected_tournament.id
    returning * into selected_tournament;
  else
    raise exception 'Unsupported tournament lifecycle action.'
      using errcode = 'P4303';
  end if;

  return selected_tournament;
end;
$$;

alter function public.levelledup_admin_transition_tournament(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_admin_transition_tournament(uuid, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_transition_tournament(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_transition_tournament(uuid, text) is
  'Admin tournament lifecycle control. Registration opens on the inclusive absolute interval registration_opens_at <= now() <= registration_closes_at, provided the tournament has not started.';

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
  assigned_slot integer;
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
    raise exception 'Tournament not found.'
      using errcode = 'P4001';
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      raise exception 'A new tournament registration must begin as pending.'
        using errcode = 'P4003';
    end if;
  elsif new.status is distinct from old.status then
    if not (
      (old.status = 'pending' and new.status in ('confirmed', 'rejected', 'withdrawn'))
      or (old.status = 'confirmed' and new.status = 'withdrawn')
    ) then
      raise exception 'Invalid tournament registration status transition.'
        using errcode = 'P4003';
    end if;
  end if;

  if new.status = 'pending' then
    if selected_tournament.status <> 'registration_open' then
      raise exception 'Tournament registration is not currently open.'
        using errcode = 'P4004';
    end if;

    if now() < selected_tournament.registration_opens_at then
      raise exception 'Tournament registration has not opened yet.'
        using errcode = 'P4004';
    end if;

    if now() > selected_tournament.registration_closes_at then
      raise exception 'Tournament registration has closed.'
        using errcode = 'P4004';
    end if;

    select count(*)::integer
    into confirmed_count
    from public.tournament_registrations
    where tournament_registrations.tournament_id = new.tournament_id
      and tournament_registrations.status = 'confirmed'
      and tournament_registrations.id <> new.id;

    if confirmed_count >= selected_tournament.max_team_slots then
      raise exception 'The tournament is full.'
        using errcode = 'P4005';
    end if;

    new.slot_number := null;
  elsif new.status = 'confirmed' then
    if selected_tournament.status not in (
      'registration_open',
      'registration_closed'
    ) or now() >= selected_tournament.scheduled_start_at then
      raise exception 'This tournament cannot confirm registrations now.'
        using errcode = 'P4004';
    end if;

    if not exists (
      select 1
      from public.tournament_registration_roster
      where tournament_registration_roster.registration_id = new.id
    ) then
      raise exception 'A submitted roster is required before confirmation.'
        using errcode = 'P4006';
    end if;

    if new.slot_number is null then
      select available_slots.slot_number
      into assigned_slot
      from generate_series(
        1,
        selected_tournament.max_team_slots
      ) as available_slots(slot_number)
      where not exists (
        select 1
        from public.tournament_registrations as occupied
        where occupied.tournament_id = new.tournament_id
          and occupied.status = 'confirmed'
          and occupied.slot_number = available_slots.slot_number
          and occupied.id <> new.id
      )
      order by available_slots.slot_number
      limit 1;

      if assigned_slot is null then
        raise exception 'The tournament is full.'
          using errcode = 'P4005';
      end if;

      new.slot_number := assigned_slot;
    elsif new.slot_number > selected_tournament.max_team_slots then
      raise exception 'The assigned slot exceeds the tournament slot limit.'
        using errcode = 'P4007';
    end if;

    if tg_op = 'UPDATE' and old.status <> 'confirmed' then
      new.confirmed_at := now();
      new.reviewed_at := now();
      new.reviewed_by := coalesce(new.reviewed_by, auth.uid());
    end if;
  elsif new.status = 'rejected' then
    new.slot_number := null;

    if tg_op = 'UPDATE' and old.status <> 'rejected' then
      new.rejected_at := now();
      new.reviewed_at := now();
      new.reviewed_by := coalesce(new.reviewed_by, auth.uid());
    end if;
  elsif new.status = 'withdrawn' then
    if tg_op = 'UPDATE'
      and old.status = 'confirmed'
      and (
        selected_tournament.status not in (
          'registration_open',
          'registration_closed'
        )
        or now() >= selected_tournament.scheduled_start_at
      ) then
      raise exception 'A confirmed registration cannot be withdrawn after the tournament starts.'
        using errcode = 'P4014';
    end if;

    if tg_op = 'UPDATE' and old.status <> 'confirmed' then
      new.slot_number := null;
    end if;

    if tg_op = 'UPDATE' and old.status <> 'withdrawn' then
      new.withdrawn_at := now();
    end if;
  end if;

  return new;
end;
$$;

alter function public.levelledup_manage_tournament_registration_lifecycle()
  owner to postgres;

revoke all on function public.levelledup_manage_tournament_registration_lifecycle()
  from public, anon, authenticated;

comment on function public.levelledup_manage_tournament_registration_lifecycle() is
  'Registration lifecycle validation using absolute timestamptz instants. New pending registrations are allowed on the inclusive registration interval.';

commit;
