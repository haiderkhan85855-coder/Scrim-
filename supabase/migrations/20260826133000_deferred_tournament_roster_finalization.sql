begin;

alter table public.tournaments
  add column roster_lock_at timestamptz,
  add column roster_min_players integer,
  add column roster_max_players integer;

update public.tournaments
set
  roster_lock_at = scheduled_start_at,
  roster_min_players = case game_mode
    when 'solo' then 1
    when 'duo' then 2
    else 4
  end,
  roster_max_players = case game_mode
    when 'solo' then 1
    when 'duo' then 2
    else 4
  end;

alter table public.tournaments
  alter column roster_lock_at set not null,
  alter column roster_min_players set not null,
  alter column roster_max_players set not null,
  add constraint tournaments_roster_lock_window_valid check (
    roster_lock_at >= registration_opens_at
    and roster_lock_at <= scheduled_start_at
  ),
  add constraint tournaments_roster_size_valid check (
    roster_min_players >= 1
    and roster_max_players >= roster_min_players
    and roster_max_players <= 16
  );

comment on column public.tournaments.roster_lock_at is
  'Independent deadline after which a captain cannot finalize the tournament roster. V1 backfill/default uses tournament start until Admin configuration is added.';
comment on column public.tournaments.roster_min_players is
  'Configurable minimum finalized roster size. V1 defaults from game mode but is not encoded into the finalization function.';
comment on column public.tournaments.roster_max_players is
  'Configurable maximum finalized roster size. Future tournament formats may adjust this independently.';

create function public.levelledup_default_tournament_roster_configuration()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  default_roster_size integer := case new.game_mode
    when 'solo' then 1
    when 'duo' then 2
    else 4
  end;
  old_default_roster_size integer;
begin
  if tg_op = 'UPDATE' then
    old_default_roster_size := case old.game_mode
      when 'solo' then 1
      when 'duo' then 2
      else 4
    end;

    if new.scheduled_start_at is distinct from old.scheduled_start_at
      and new.roster_lock_at is not distinct from old.roster_lock_at
      and old.roster_lock_at = old.scheduled_start_at then
      new.roster_lock_at := new.scheduled_start_at;
    end if;

    if new.game_mode is distinct from old.game_mode
      and new.roster_min_players is not distinct from old.roster_min_players
      and new.roster_max_players is not distinct from old.roster_max_players
      and old.roster_min_players = old_default_roster_size
      and old.roster_max_players = old_default_roster_size then
      new.roster_min_players := default_roster_size;
      new.roster_max_players := default_roster_size;
    end if;
  end if;

  new.roster_lock_at := coalesce(new.roster_lock_at, new.scheduled_start_at);
  new.roster_min_players := coalesce(
    new.roster_min_players,
    default_roster_size
  );
  new.roster_max_players := coalesce(
    new.roster_max_players,
    default_roster_size
  );

  return new;
end;
$$;

alter function public.levelledup_default_tournament_roster_configuration()
  owner to postgres;
revoke all on function public.levelledup_default_tournament_roster_configuration()
  from public, anon, authenticated;

create trigger tournaments_default_roster_configuration
before insert or update of scheduled_start_at, game_mode, roster_lock_at,
  roster_min_players, roster_max_players
on public.tournaments
for each row
execute function public.levelledup_default_tournament_roster_configuration();

alter table public.tournament_registrations
  add column roster_status text not null default 'draft',
  add column roster_finalized_at timestamptz,
  add column roster_locked_at timestamptz,
  add constraint tournament_registrations_roster_status_valid check (
    roster_status in ('draft', 'finalized', 'locked')
  );

with roster_snapshots as (
  select
    roster.registration_id,
    max(roster.created_at) as finalized_at
  from public.tournament_registration_roster as roster
  group by roster.registration_id
)
update public.tournament_registrations as registration
set
  roster_status = case
    when now() >= tournament.roster_lock_at
      or tournament.status in ('live', 'completed') then 'locked'
    else 'finalized'
  end,
  roster_finalized_at = roster_snapshots.finalized_at,
  roster_locked_at = case
    when now() >= tournament.roster_lock_at
      or tournament.status in ('live', 'completed')
      then greatest(roster_snapshots.finalized_at, tournament.roster_lock_at)
    else null
  end
from public.tournaments as tournament,
  roster_snapshots
where tournament.id = registration.tournament_id
  and roster_snapshots.registration_id = registration.id;

alter table public.tournament_registrations
  add constraint tournament_registrations_roster_state_valid check (
    (
      roster_status = 'draft'
      and roster_finalized_at is null
      and roster_locked_at is null
    )
    or (
      roster_status = 'finalized'
      and roster_finalized_at is not null
      and roster_locked_at is null
    )
    or (
      roster_status = 'locked'
      and roster_finalized_at is not null
      and roster_locked_at is not null
      and roster_locked_at >= roster_finalized_at
    )
  );

comment on column public.tournament_registrations.roster_status is
  'Draft means no immutable snapshot exists; finalized means the snapshot was atomically submitted; locked means the finalized roster is past its lock boundary.';

create function public.levelledup_guard_tournament_roster_snapshot_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
begin
  select tournament_registrations.*
  into selected_registration
  from public.tournament_registrations
  where tournament_registrations.id = new.registration_id
  for update;

  if selected_registration.id is null
    or selected_registration.roster_status <> 'draft' then
    raise exception 'Only a draft tournament roster can be finalized.'
      using errcode = 'P4015';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = selected_registration.tournament_id
  for share;

  if now() >= selected_tournament.roster_lock_at then
    raise exception 'The tournament roster-lock deadline has passed.'
      using errcode = 'P4016';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_tournament_roster_snapshot_insert()
  owner to postgres;
revoke all on function public.levelledup_guard_tournament_roster_snapshot_insert()
  from public, anon, authenticated;

create trigger tournament_registration_roster_00_guard_finalization
before insert on public.tournament_registration_roster
for each row
execute function public.levelledup_guard_tournament_roster_snapshot_insert();

create function public.levelledup_register_team_for_tournament(
  p_tournament_id uuid,
  p_team_id uuid
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  created_registration public.tournament_registrations;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to register a team.'
      using errcode = '42501';
  end if;

  if not public.levelledup_is_active_team_captain(p_team_id) then
    raise exception 'Only the active team captain can register this team.'
      using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_tournament_id::text || ':team:' || p_team_id::text,
      0
    )
  );

  if exists (
    select 1
    from public.tournament_registrations
    where tournament_registrations.tournament_id = p_tournament_id
      and tournament_registrations.team_id = p_team_id
      and tournament_registrations.status in ('pending', 'confirmed')
  ) then
    raise exception 'This team already has an active tournament registration.'
      using errcode = 'P4017';
  end if;

  insert into public.tournament_registrations (
    tournament_id,
    team_id,
    status,
    roster_status
  )
  values (
    p_tournament_id,
    p_team_id,
    'pending',
    'draft'
  )
  returning * into created_registration;

  return created_registration;
end;
$$;

alter function public.levelledup_register_team_for_tournament(uuid, uuid)
  owner to postgres;
revoke all on function public.levelledup_register_team_for_tournament(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_register_team_for_tournament(uuid, uuid)
  to authenticated;

drop function public.levelledup_register_team_for_tournament(
  uuid,
  uuid,
  uuid[]
);

comment on function public.levelledup_register_team_for_tournament(uuid, uuid) is
  'Captain-only registration start. Creates a pending registration with a draft roster and never snapshots players.';

create function public.levelledup_finalize_tournament_roster(
  p_registration_id uuid,
  p_roster_member_ids uuid[]
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
  selected_member record;
  requested_roster_count integer;
  eligible_roster_count integer;
  inserted_roster_count integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to finalize a tournament roster.'
      using errcode = '42501';
  end if;

  select tournament_registrations.*
  into selected_registration
  from public.tournament_registrations
  where tournament_registrations.id = p_registration_id
  for update;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4001';
  end if;

  if not public.levelledup_is_active_team_captain(
    selected_registration.team_id
  ) then
    raise exception 'Only the active team captain can finalize this roster.'
      using errcode = '42501';
  end if;

  if selected_registration.status <> 'pending'
    or selected_registration.roster_status <> 'draft' then
    raise exception 'Only a pending registration with a draft roster can be finalized.'
      using errcode = 'P4015';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = selected_registration.tournament_id
  for share;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4001';
  end if;

  if selected_tournament.status not in (
    'registration_open',
    'registration_closed'
  ) or now() >= selected_tournament.roster_lock_at then
    raise exception 'The tournament roster-lock deadline has passed.'
      using errcode = 'P4016';
  end if;

  requested_roster_count := cardinality(p_roster_member_ids);

  if requested_roster_count is null
    or requested_roster_count < selected_tournament.roster_min_players
    or requested_roster_count > selected_tournament.roster_max_players then
    raise exception 'Select between % and % eligible players.',
      selected_tournament.roster_min_players,
      selected_tournament.roster_max_players
      using errcode = 'P4012';
  end if;

  if requested_roster_count <> (
    select count(distinct roster_member_id)::integer
    from unnest(p_roster_member_ids) as selected(roster_member_id)
  ) then
    raise exception 'The submitted tournament roster contains duplicate selections.'
      using errcode = 'P4012';
  end if;

  select count(*)::integer
  into eligible_roster_count
  from public.team_roster_members as roster
  where roster.id = any(p_roster_member_ids)
    and roster.team_id = selected_registration.team_id
    and roster.status = 'active';

  if eligible_roster_count <> requested_roster_count then
    raise exception 'Every selected player must be an active member of the registering team.'
      using errcode = 'P4010';
  end if;

  if exists (
    select 1
    from public.tournament_registration_roster
    where tournament_registration_roster.registration_id = selected_registration.id
  ) then
    raise exception 'This registration already has an immutable roster snapshot.'
      using errcode = 'P4015';
  end if;

  for selected_member in
    select roster.profile_id, roster.pubg_uid
    from public.team_roster_members as roster
    where roster.id = any(p_roster_member_ids)
    order by coalesce(roster.profile_id::text, ''), roster.pubg_uid
  loop
    if selected_member.profile_id is not null then
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
          selected_registration.tournament_id::text
            || ':profile:'
            || selected_member.profile_id::text,
          0
        )
      );
    end if;

    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        selected_registration.tournament_id::text
          || ':pubg:'
          || selected_member.pubg_uid,
        0
      )
    );
  end loop;

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
    selected_registration.id,
    selected_registration.tournament_id,
    selected_registration.team_id,
    roster.id,
    roster.profile_id,
    roster.display_name,
    roster.pubg_uid,
    roster.pubg_ign,
    roster.role
  from public.team_roster_members as roster
  where roster.id = any(p_roster_member_ids)
    and roster.team_id = selected_registration.team_id
    and roster.status = 'active'
  order by roster.created_at, roster.id;

  get diagnostics inserted_roster_count = row_count;

  if inserted_roster_count <> requested_roster_count then
    raise exception 'Every selected player must remain active until finalization completes.'
      using errcode = 'P4010';
  end if;

  update public.tournament_registrations
  set
    roster_status = 'finalized',
    roster_finalized_at = now()
  where id = selected_registration.id
  returning * into selected_registration;

  return selected_registration;
end;
$$;

alter function public.levelledup_finalize_tournament_roster(uuid, uuid[])
  owner to postgres;
revoke all on function public.levelledup_finalize_tournament_roster(uuid, uuid[])
  from public, anon, authenticated;
grant execute on function public.levelledup_finalize_tournament_roster(uuid, uuid[])
  to authenticated;

comment on function public.levelledup_finalize_tournament_roster(uuid, uuid[]) is
  'Captain-only atomic roster finalization. Validates configured size and active membership, obtains deterministic identity locks, writes immutable snapshots, and only then marks the registration finalized.';

create function public.levelledup_require_finalized_roster_for_confirmation()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.status = 'confirmed'
    and old.status is distinct from 'confirmed'
    and new.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the tournament roster before approval.'
      using errcode = 'P4409';
  end if;

  return new;
end;
$$;

alter function public.levelledup_require_finalized_roster_for_confirmation()
  owner to postgres;
revoke all on function public.levelledup_require_finalized_roster_for_confirmation()
  from public, anon, authenticated;

create trigger tournament_registrations_00_require_finalized_roster
before update of status on public.tournament_registrations
for each row
execute function public.levelledup_require_finalized_roster_for_confirmation();

create function public.levelledup_lock_rosters_when_tournament_starts()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.status in ('live', 'completed')
    and old.status is distinct from new.status then
    update public.tournament_registrations
    set
      roster_status = 'locked',
      roster_locked_at = greatest(roster_finalized_at, new.roster_lock_at)
    where tournament_id = new.id
      and roster_status = 'finalized';
  end if;

  return new;
end;
$$;

alter function public.levelledup_lock_rosters_when_tournament_starts()
  owner to postgres;
revoke all on function public.levelledup_lock_rosters_when_tournament_starts()
  from public, anon, authenticated;

create trigger tournaments_lock_finalized_rosters
after update of status on public.tournaments
for each row
execute function public.levelledup_lock_rosters_when_tournament_starts();

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
    if selected_registration.roster_status not in ('finalized', 'locked') then
      raise exception 'Finalize the tournament roster before approval.'
        using errcode = 'P4409';
    end if;

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

commit;
