begin;

create table public.tournament_id_registry (
  tournament_id text primary key,
  tournament_uuid uuid not null unique,
  reserved_at timestamptz not null default now(),
  constraint tournament_id_registry_format check (
    tournament_id ~ '^LU-T-[A-HJ-NP-Z2-9]{8}$'
  )
);

comment on table public.tournament_id_registry is
  'Permanent registry of every issued LevelledUp Tournament ID. Rows remain after an eligible draft tournament is deleted so IDs can never be reused.';

insert into public.tournament_id_registry (
  tournament_id,
  tournament_uuid,
  reserved_at
)
select
  tournaments.tournament_id,
  tournaments.id,
  tournaments.created_at
from public.tournaments;

alter table public.tournament_id_registry enable row level security;

revoke all on table public.tournament_id_registry
  from public, anon, authenticated;

create function public.levelledup_reserve_tournament_id()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  insert into public.tournament_id_registry (
    tournament_id,
    tournament_uuid
  )
  values (
    new.tournament_id,
    new.id
  );

  return new;
exception
  when unique_violation then
    raise exception 'A permanent tournament ID could not be allocated. Please try again.'
      using errcode = '23505';
end;
$$;

alter function public.levelledup_reserve_tournament_id()
  owner to postgres;

revoke all on function public.levelledup_reserve_tournament_id()
  from public, anon, authenticated;

create trigger tournaments_reserve_tournament_id
before insert on public.tournaments
for each row
execute function public.levelledup_reserve_tournament_id();

alter table public.tournaments
  add column archived_at timestamptz,
  add column archived_by uuid references auth.users (id) on delete set null,
  add constraint tournaments_archive_provenance_valid check (
    (archived_at is null and archived_by is null)
    or archived_at is not null
  );

comment on column public.tournaments.archived_at is
  'Set when an admin retires a tournament that cannot be physically deleted without losing participant or operational history.';

comment on column public.tournaments.archived_by is
  'Authenticated admin who retired the tournament; nullable later if that Auth user is removed.';

create index tournaments_archive_status_idx
  on public.tournaments (archived_at, status, scheduled_start_at desc);

create function public.levelledup_guard_tournament_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status <> 'draft' then
    raise exception 'Only a draft tournament can be physically deleted.'
      using errcode = 'P4310';
  end if;

  if exists (
    select 1
    from public.tournament_registrations
    where tournament_registrations.tournament_id = old.id
  ) or exists (
    select 1
    from public.tournament_matches
    where tournament_matches.tournament_id = old.id
  ) then
    raise exception 'A tournament with participant or match history cannot be physically deleted.'
      using errcode = 'P4311';
  end if;

  return old;
end;
$$;

alter function public.levelledup_guard_tournament_delete()
  owner to postgres;

revoke all on function public.levelledup_guard_tournament_delete()
  from public, anon, authenticated;

create trigger tournaments_guard_delete
before delete on public.tournaments
for each row
execute function public.levelledup_guard_tournament_delete();

create function public.levelledup_admin_retire_tournament(
  p_tournament_id uuid,
  p_public_tournament_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_tournament public.tournaments;
  has_history boolean;
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

  if upper(btrim(coalesce(p_public_tournament_id, '')))
    <> selected_tournament.tournament_id then
    raise exception 'Enter the permanent Tournament ID to confirm this action.'
      using errcode = 'P4312';
  end if;

  select
    exists (
      select 1
      from public.tournament_registrations
      where tournament_registrations.tournament_id = selected_tournament.id
    )
    or exists (
      select 1
      from public.tournament_matches
      where tournament_matches.tournament_id = selected_tournament.id
    )
  into has_history;

  if selected_tournament.status = 'draft' and not has_history then
    delete from public.tournaments
    where tournaments.id = selected_tournament.id;

    return jsonb_build_object(
      'outcome', 'deleted',
      'tournament_id', selected_tournament.tournament_id
    );
  end if;

  if selected_tournament.archived_at is not null then
    raise exception 'This tournament is already archived.'
      using errcode = 'P4313';
  end if;

  update public.tournaments
  set
    status = case
      when status = 'completed' then status
      else 'cancelled'
    end,
    archived_at = now(),
    archived_by = authenticated_user_id
  where tournaments.id = selected_tournament.id;

  return jsonb_build_object(
    'outcome', 'archived',
    'tournament_id', selected_tournament.tournament_id
  );
end;
$$;

alter function public.levelledup_admin_retire_tournament(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_admin_retire_tournament(uuid, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_retire_tournament(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_retire_tournament(uuid, text) is
  'Admin-only retirement operation. Deletes only dependency-free drafts; otherwise preserves the tournament and marks it archived, cancelling non-completed tournaments.';

commit;
