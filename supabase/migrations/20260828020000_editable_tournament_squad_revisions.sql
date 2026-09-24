begin;

alter table public.tournament_registrations
  add column roster_revision integer not null default 0;

update public.tournament_registrations as registrations
set roster_revision = 1
where registrations.roster_status in ('finalized', 'locked')
  and exists (
    select 1
    from public.tournament_registration_roster as snapshots
    where snapshots.registration_id = registrations.id
  );

alter table public.tournament_registrations
  add constraint tournament_registrations_roster_revision_valid check (
    (roster_status = 'draft' and roster_revision = 0)
    or (roster_status in ('finalized', 'locked') and roster_revision >= 1)
  );

comment on column public.tournament_registrations.roster_revision is
  'Current immutable tournament Squad snapshot revision. Earlier revisions remain historical and are never updated or deleted.';

alter table public.tournament_registration_roster
  add column revision_number integer not null default 1;

alter table public.tournament_registration_roster
  add constraint tournament_registration_roster_revision_valid check (
    revision_number >= 1
  );

alter table public.tournament_registration_roster
  drop constraint tournament_registration_roster_uid_per_registration_unique,
  drop constraint tournament_registration_roster_source_per_registration_unique,
  drop constraint tournament_registration_roster_number_per_registration_unique;

drop index public.tournament_registration_roster_profile_per_registration_idx;

alter table public.tournament_registration_roster
  add constraint tournament_registration_roster_uid_per_revision_unique
    unique (registration_id, revision_number, pubg_uid),
  add constraint tournament_registration_roster_source_per_revision_unique
    unique (registration_id, revision_number, source_roster_member_id),
  add constraint tournament_registration_roster_number_per_revision_unique
    unique (registration_id, revision_number, roster_number);

create unique index tournament_registration_roster_profile_per_revision_idx
  on public.tournament_registration_roster (
    registration_id,
    revision_number,
    profile_id
  )
  where profile_id is not null;

create index tournament_registration_roster_current_revision_idx
  on public.tournament_registration_roster (registration_id, revision_number);

comment on column public.tournament_registration_roster.revision_number is
  'Immutable Squad revision containing this historical snapshot row.';

create or replace function public.levelledup_guard_tournament_roster_snapshot_insert()
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
  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = new.registration_id
  for update;

  if selected_registration.id is null
    or selected_registration.status not in ('pending', 'confirmed')
    or selected_registration.roster_status not in ('draft', 'finalized') then
    raise exception 'Only an active unlocked tournament Squad can be finalized.'
      using errcode = 'P4015';
  end if;

  if new.revision_number <> selected_registration.roster_revision + 1 then
    raise exception 'Tournament Squad revision is invalid.'
      using errcode = 'P4015';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_registration.tournament_id
  for share;

  if selected_tournament.id is null
    or now() >= selected_tournament.roster_lock_at then
    raise exception 'The tournament Squad-lock deadline has passed.'
      using errcode = 'P4016';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_tournament_roster_snapshot_insert()
  owner to postgres;
revoke all on function public.levelledup_guard_tournament_roster_snapshot_insert()
  from public, anon, authenticated;

create or replace function public.levelledup_validate_tournament_roster_snapshot()
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
  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = new.registration_id
  for update;

  if selected_registration.id is null
    or selected_registration.tournament_id <> new.tournament_id
    or selected_registration.team_id <> new.team_id then
    raise exception 'Tournament Squad does not match its registration.'
      using errcode = 'P4008';
  end if;

  if selected_registration.status not in ('pending', 'confirmed')
    or selected_registration.roster_status not in ('draft', 'finalized')
    or new.revision_number <> selected_registration.roster_revision + 1 then
    raise exception 'This tournament Squad cannot be finalized now.'
      using errcode = 'P4009';
  end if;

  select members.*
  into source_member
  from public.team_roster_members as members
  where members.id = new.source_roster_member_id
    and members.team_id = new.team_id
    and members.status = 'active'
  for share;

  if source_member.id is null
    or source_member.profile_id is distinct from new.profile_id
    or source_member.pubg_uid <> new.pubg_uid
    or source_member.pubg_ign is distinct from new.pubg_ign
    or source_member.display_name <> new.display_name
    or source_member.role <> new.role
    or source_member.roster_number <> new.roster_number then
    raise exception 'Tournament Squad identity must match the selected active team member.'
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
    from public.tournament_registration_roster as existing_squad
    join public.tournament_registrations as existing_registration
      on existing_registration.id = existing_squad.registration_id
    where existing_squad.tournament_id = new.tournament_id
      and existing_squad.team_id <> new.team_id
      and existing_registration.status in ('pending', 'confirmed')
      and existing_squad.revision_number = existing_registration.roster_revision
      and (
        (
          new.profile_id is not null
          and existing_squad.profile_id = new.profile_id
        )
        or existing_squad.pubg_uid = new.pubg_uid
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

create function public.levelledup_keep_tournament_squad_revision()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.revision_number is distinct from old.revision_number then
    raise exception 'Tournament Squad snapshot revisions are immutable.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_tournament_squad_revision()
  owner to postgres;
revoke all on function public.levelledup_keep_tournament_squad_revision()
  from public, anon, authenticated;

create trigger tournament_registration_roster_keep_revision
before update of revision_number on public.tournament_registration_roster
for each row
execute function public.levelledup_keep_tournament_squad_revision();

create or replace function public.levelledup_finalize_tournament_roster(
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
  requested_squad_count integer;
  eligible_squad_count integer;
  inserted_squad_count integer;
  next_revision integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to finalize a tournament Squad.'
      using errcode = '42501';
  end if;

  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id
  for update;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4001';
  end if;

  if not public.levelledup_is_active_team_captain(selected_registration.team_id) then
    raise exception 'Only the active team Captain can finalize this Squad.'
      using errcode = '42501';
  end if;

  if selected_registration.status not in ('pending', 'confirmed')
    or selected_registration.roster_status not in ('draft', 'finalized') then
    raise exception 'Only an active unlocked tournament Squad can be finalized.'
      using errcode = 'P4015';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_registration.tournament_id
  for share;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4001';
  end if;

  if selected_tournament.status not in ('registration_open', 'registration_closed')
    or now() >= selected_tournament.roster_lock_at then
    raise exception 'The tournament Squad-lock deadline has passed.'
      using errcode = 'P4016';
  end if;

  requested_squad_count := cardinality(p_roster_member_ids);

  if requested_squad_count is null
    or requested_squad_count < 1
    or requested_squad_count > 6 then
    raise exception 'Select between 1 and 6 eligible Squad members.'
      using errcode = 'P4012';
  end if;

  if requested_squad_count <> (
    select count(distinct selected_member_id)::integer
    from unnest(p_roster_member_ids) as selected(selected_member_id)
  ) then
    raise exception 'The submitted tournament Squad contains duplicate selections.'
      using errcode = 'P4012';
  end if;

  select count(*)::integer
  into eligible_squad_count
  from public.team_roster_members as members
  where members.id = any(p_roster_member_ids)
    and members.team_id = selected_registration.team_id
    and members.status = 'active';

  if eligible_squad_count <> requested_squad_count then
    raise exception 'Every selected player must be an active member of the registering team.'
      using errcode = 'P4010';
  end if;

  for selected_member in
    select members.profile_id, members.pubg_uid
    from public.team_roster_members as members
    where members.id = any(p_roster_member_ids)
    order by coalesce(members.profile_id::text, ''), members.pubg_uid
  loop
    if selected_member.profile_id is not null then
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
          selected_registration.tournament_id::text
            || ':profile:' || selected_member.profile_id::text,
          0
        )
      );
    end if;

    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        selected_registration.tournament_id::text
          || ':pubg:' || selected_member.pubg_uid,
        0
      )
    );
  end loop;

  next_revision := selected_registration.roster_revision + 1;

  insert into public.tournament_registration_roster (
    registration_id,
    tournament_id,
    team_id,
    source_roster_member_id,
    profile_id,
    display_name,
    pubg_uid,
    pubg_ign,
    role,
    roster_number,
    revision_number
  )
  select
    selected_registration.id,
    selected_registration.tournament_id,
    selected_registration.team_id,
    members.id,
    members.profile_id,
    members.display_name,
    members.pubg_uid,
    members.pubg_ign,
    members.role,
    members.roster_number,
    next_revision
  from public.team_roster_members as members
  where members.id = any(p_roster_member_ids)
    and members.team_id = selected_registration.team_id
    and members.status = 'active'
  order by members.roster_number;

  get diagnostics inserted_squad_count = row_count;

  if inserted_squad_count <> requested_squad_count then
    raise exception 'Every selected player must remain active until Squad finalization completes.'
      using errcode = 'P4010';
  end if;

  update public.tournament_registrations
  set
    roster_revision = next_revision,
    roster_status = 'finalized',
    roster_finalized_at = now(),
    roster_locked_at = null
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
  'Captain-only transactional Squad finalization. Each pre-lock edit appends an immutable revision and atomically advances the registration current revision.';

commit;
