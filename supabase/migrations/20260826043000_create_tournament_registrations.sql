begin;

create table public.tournament_registrations (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null
    references public.tournaments (id) on delete restrict,
  team_id uuid not null
    references public.teams (id) on delete restrict,
  status text not null default 'pending',
  slot_number integer,
  registered_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id) on delete set null,
  confirmed_at timestamptz,
  rejected_at timestamptz,
  withdrawn_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_registrations_identity_unique unique (
    id,
    tournament_id,
    team_id
  ),
  constraint tournament_registrations_status_valid check (
    status in ('pending', 'confirmed', 'rejected', 'withdrawn')
  ),
  constraint tournament_registrations_slot_positive check (
    slot_number is null or slot_number >= 1
  ),
  constraint tournament_registrations_slot_state_valid check (
    (status = 'confirmed' and slot_number is not null)
    or (status in ('pending', 'rejected') and slot_number is null)
    or status = 'withdrawn'
  )
);

comment on table public.tournament_registrations is
  'A team tournament entry. Slots belong to this record and never to the persistent team.';

comment on column public.tournament_registrations.slot_number is
  'Tournament-local slot. Confirmed registrations require one; withdrawn registrations may retain the historical assignment.';

create unique index tournament_registrations_one_active_team_idx
  on public.tournament_registrations (tournament_id, team_id)
  where status in ('pending', 'confirmed');

create unique index tournament_registrations_confirmed_slot_idx
  on public.tournament_registrations (tournament_id, slot_number)
  where status = 'confirmed';

create index tournament_registrations_team_history_idx
  on public.tournament_registrations (team_id, registered_at desc);

create index tournament_registrations_tournament_status_idx
  on public.tournament_registrations (tournament_id, status);

create table public.tournament_registration_roster (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null,
  tournament_id uuid not null,
  team_id uuid not null,
  source_roster_member_id uuid not null
    references public.team_roster_members (id) on delete restrict,
  profile_id uuid references public.profiles (id) on delete set null,
  display_name text not null,
  pubg_uid text not null,
  pubg_ign text,
  role text not null,
  created_at timestamptz not null default now(),
  constraint tournament_registration_roster_registration_fk
    foreign key (registration_id, tournament_id, team_id)
    references public.tournament_registrations (
      id,
      tournament_id,
      team_id
    )
    on delete restrict,
  constraint tournament_registration_roster_name_valid check (
    display_name = btrim(display_name)
    and char_length(display_name) between 1 and 80
  ),
  constraint tournament_registration_roster_pubg_uid_valid check (
    pubg_uid = btrim(pubg_uid)
    and char_length(pubg_uid) between 1 and 32
  ),
  constraint tournament_registration_roster_pubg_ign_valid check (
    pubg_ign is null
    or (
      pubg_ign = btrim(pubg_ign)
      and char_length(pubg_ign) between 1 and 32
    )
  ),
  constraint tournament_registration_roster_role_valid check (
    role in ('captain', 'member', 'substitute')
  ),
  constraint tournament_registration_roster_uid_per_registration_unique
    unique (registration_id, pubg_uid),
  constraint tournament_registration_roster_source_per_registration_unique
    unique (registration_id, source_roster_member_id)
);

comment on table public.tournament_registration_roster is
  'Immutable submitted player identity snapshot for one tournament registration.';

comment on column public.tournament_registration_roster.profile_id is
  'Optional LevelledUp identity. Snapshot text remains authoritative if the profile later changes or is removed.';

create unique index tournament_registration_roster_profile_per_registration_idx
  on public.tournament_registration_roster (registration_id, profile_id)
  where profile_id is not null;

create index tournament_registration_roster_tournament_profile_idx
  on public.tournament_registration_roster (tournament_id, profile_id)
  where profile_id is not null;

create index tournament_registration_roster_tournament_uid_idx
  on public.tournament_registration_roster (tournament_id, pubg_uid);

create function public.levelledup_set_tournament_registration_updated_at()
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

alter function public.levelledup_set_tournament_registration_updated_at()
  owner to postgres;

revoke all on function public.levelledup_set_tournament_registration_updated_at()
  from public, anon, authenticated;

create trigger tournament_registrations_set_updated_at
before update on public.tournament_registrations
for each row
execute function public.levelledup_set_tournament_registration_updated_at();

create function public.levelledup_keep_tournament_registration_identity()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.tournament_id is distinct from old.tournament_id
    or new.team_id is distinct from old.team_id then
    raise exception 'A tournament registration cannot be moved to another tournament or team.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_tournament_registration_identity()
  owner to postgres;

revoke all on function public.levelledup_keep_tournament_registration_identity()
  from public, anon, authenticated;

create trigger tournament_registrations_keep_identity
before update of tournament_id, team_id on public.tournament_registrations
for each row
execute function public.levelledup_keep_tournament_registration_identity();

create function public.levelledup_manage_tournament_registration_lifecycle()
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
    if selected_tournament.status <> 'registration_open'
      or now() < selected_tournament.registration_opens_at
      or now() >= selected_tournament.registration_closes_at then
      raise exception 'Tournament registration is not currently open.'
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

create trigger tournament_registrations_manage_lifecycle
before insert or update on public.tournament_registrations
for each row
execute function public.levelledup_manage_tournament_registration_lifecycle();

create function public.levelledup_guard_tournament_slot_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.max_team_slots < old.max_team_slots
    and exists (
      select 1
      from public.tournament_registrations
      where tournament_registrations.tournament_id = old.id
        and tournament_registrations.status = 'confirmed'
        and tournament_registrations.slot_number > new.max_team_slots
    ) then
    raise exception 'The slot limit cannot be lower than an assigned confirmed slot.'
      using errcode = 'P4007';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_tournament_slot_limit()
  owner to postgres;

revoke all on function public.levelledup_guard_tournament_slot_limit()
  from public, anon, authenticated;

create trigger tournaments_guard_slot_limit
before update of max_team_slots on public.tournaments
for each row
execute function public.levelledup_guard_tournament_slot_limit();

create function public.levelledup_validate_tournament_roster_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_registration public.tournament_registrations;
  source_member public.team_roster_members;
begin
  select tournament_registrations.*
  into selected_registration
  from public.tournament_registrations
  where tournament_registrations.id = new.registration_id
  for update;

  if selected_registration.id is null
    or selected_registration.tournament_id <> new.tournament_id
    or selected_registration.team_id <> new.team_id then
    raise exception 'Tournament roster does not match its registration.'
      using errcode = 'P4008';
  end if;

  if selected_registration.status <> 'pending' then
    raise exception 'A tournament roster can only be submitted while registration is pending.'
      using errcode = 'P4009';
  end if;

  select team_roster_members.*
  into source_member
  from public.team_roster_members
  where team_roster_members.id = new.source_roster_member_id
    and team_roster_members.team_id = new.team_id
    and team_roster_members.status = 'active'
  for share;

  if source_member.id is null
    or source_member.profile_id is distinct from new.profile_id
    or source_member.pubg_uid <> new.pubg_uid
    or source_member.pubg_ign is distinct from new.pubg_ign
    or source_member.display_name <> new.display_name
    or source_member.role <> new.role then
    raise exception 'Tournament roster identity must match the selected active team roster member.'
      using errcode = 'P4010';
  end if;

  if new.profile_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        new.tournament_id::text || ':profile:' || new.profile_id::text,
        0
      )
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      new.tournament_id::text || ':pubg:' || new.pubg_uid,
      0
    )
  );

  if exists (
    select 1
    from public.tournament_registration_roster as existing_roster
    join public.tournament_registrations as existing_registration
      on existing_registration.id = existing_roster.registration_id
    where existing_roster.tournament_id = new.tournament_id
      and existing_roster.team_id <> new.team_id
      and existing_registration.status in ('pending', 'confirmed')
      and (
        (
          new.profile_id is not null
          and existing_roster.profile_id = new.profile_id
        )
        or existing_roster.pubg_uid = new.pubg_uid
      )
  ) then
    raise exception 'A player may represent only one team in the same tournament.'
      using errcode = 'P4011';
  end if;

  return new;
end;
$$;

alter function public.levelledup_validate_tournament_roster_snapshot()
  owner to postgres;

revoke all on function public.levelledup_validate_tournament_roster_snapshot()
  from public, anon, authenticated;

create trigger tournament_registration_roster_validate_snapshot
before insert on public.tournament_registration_roster
for each row
execute function public.levelledup_validate_tournament_roster_snapshot();

create function public.levelledup_keep_tournament_roster_snapshot()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Tournament roster snapshots cannot be deleted.'
      using errcode = '22023';
  end if;

  if new.registration_id is distinct from old.registration_id
    or new.tournament_id is distinct from old.tournament_id
    or new.team_id is distinct from old.team_id
    or new.source_roster_member_id is distinct from old.source_roster_member_id
    or new.display_name is distinct from old.display_name
    or new.pubg_uid is distinct from old.pubg_uid
    or new.pubg_ign is distinct from old.pubg_ign
    or new.role is distinct from old.role
    or (
      new.profile_id is distinct from old.profile_id
      and new.profile_id is not null
    )
    or new.created_at is distinct from old.created_at then
    raise exception 'Tournament roster snapshots are immutable.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_tournament_roster_snapshot()
  owner to postgres;

revoke all on function public.levelledup_keep_tournament_roster_snapshot()
  from public, anon, authenticated;

create trigger tournament_registration_roster_keep_snapshot
before update or delete on public.tournament_registration_roster
for each row
execute function public.levelledup_keep_tournament_roster_snapshot();

create function public.levelledup_withdraw_registrations_for_inactive_team()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status = 'active' and new.status <> 'active' then
    update public.tournament_registrations as registration
    set status = 'withdrawn'
    from public.tournaments as tournament
    where registration.team_id = new.id
      and registration.status in ('pending', 'confirmed')
      and tournament.id = registration.tournament_id
      and tournament.status in (
        'draft',
        'registration_open',
        'registration_closed'
      )
      and (
        registration.status = 'pending'
        or now() < tournament.scheduled_start_at
      );
  end if;

  return new;
end;
$$;

alter function public.levelledup_withdraw_registrations_for_inactive_team()
  owner to postgres;

revoke all on function public.levelledup_withdraw_registrations_for_inactive_team()
  from public, anon, authenticated;

create trigger teams_withdraw_tournament_registrations_when_inactive
after update of status on public.teams
for each row
execute function public.levelledup_withdraw_registrations_for_inactive_team();

alter table public.tournament_registrations enable row level security;
alter table public.tournament_registration_roster enable row level security;

revoke all on table public.tournament_registrations
  from public, anon, authenticated;
revoke all on table public.tournament_registration_roster
  from public, anon, authenticated;

grant select on table public.tournament_registrations
  to authenticated;
grant select on table public.tournament_registration_roster
  to authenticated;

create policy "Active team members can read tournament registrations"
  on public.tournament_registrations
  for select
  to authenticated
  using (public.levelledup_is_active_team_member(team_id));

create policy "Active team members can read tournament roster snapshots"
  on public.tournament_registration_roster
  for select
  to authenticated
  using (public.levelledup_is_active_team_member(team_id));

create function public.levelledup_register_team_for_tournament(
  p_tournament_id uuid,
  p_team_id uuid,
  p_roster_member_ids uuid[]
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  created_registration public.tournament_registrations;
  requested_roster_count integer;
  inserted_roster_count integer;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to register a team.'
      using errcode = '42501';
  end if;

  if not public.levelledup_is_active_team_captain(p_team_id) then
    raise exception 'Only the active team captain can register this team.'
      using errcode = '42501';
  end if;

  requested_roster_count := cardinality(p_roster_member_ids);

  if requested_roster_count is null or requested_roster_count < 1 then
    raise exception 'Select at least one active roster member.'
      using errcode = 'P4012';
  end if;

  if requested_roster_count <> (
    select count(distinct roster_member_id)::integer
    from unnest(p_roster_member_ids) as selected(roster_member_id)
  ) then
    raise exception 'The submitted tournament roster contains duplicate selections.'
      using errcode = 'P4012';
  end if;

  insert into public.tournament_registrations (
    tournament_id,
    team_id,
    status
  )
  values (
    p_tournament_id,
    p_team_id,
    'pending'
  )
  returning * into created_registration;

  insert into public.tournament_registration_roster (
    registration_id,
    tournament_id,
    team_id,
    source_roster_member_id,
    profile_id,
    display_name,
    pubg_uid,
    pubg_ign,
    role
  )
  select
    created_registration.id,
    created_registration.tournament_id,
    created_registration.team_id,
    roster.id,
    roster.profile_id,
    roster.display_name,
    roster.pubg_uid,
    roster.pubg_ign,
    roster.role
  from public.team_roster_members as roster
  where roster.id = any(p_roster_member_ids)
    and roster.team_id = p_team_id
    and roster.status = 'active';

  get diagnostics inserted_roster_count = row_count;

  if inserted_roster_count <> requested_roster_count then
    raise exception 'Every selected player must be an active member of the registering team.'
      using errcode = 'P4010';
  end if;

  return created_registration;
end;
$$;

alter function public.levelledup_register_team_for_tournament(uuid, uuid, uuid[])
  owner to postgres;

revoke all on function public.levelledup_register_team_for_tournament(uuid, uuid, uuid[])
  from public, anon, authenticated;
grant execute on function public.levelledup_register_team_for_tournament(uuid, uuid, uuid[])
  to authenticated;

create function public.levelledup_withdraw_tournament_registration(
  p_registration_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_registration public.tournament_registrations;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to withdraw a registration.'
      using errcode = '42501';
  end if;

  select tournament_registrations.*
  into selected_registration
  from public.tournament_registrations
  where tournament_registrations.id = p_registration_id
  for update;

  if selected_registration.id is null
    or selected_registration.status not in ('pending', 'confirmed') then
    raise exception 'Active tournament registration not found.'
      using errcode = 'P4013';
  end if;

  if not public.levelledup_is_active_team_captain(
    selected_registration.team_id
  ) then
    raise exception 'Only the active team captain can withdraw this registration.'
      using errcode = '42501';
  end if;

  update public.tournament_registrations
  set status = 'withdrawn'
  where id = selected_registration.id;

  return true;
end;
$$;

alter function public.levelledup_withdraw_tournament_registration(uuid)
  owner to postgres;

revoke all on function public.levelledup_withdraw_tournament_registration(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_withdraw_tournament_registration(uuid)
  to authenticated;

commit;
