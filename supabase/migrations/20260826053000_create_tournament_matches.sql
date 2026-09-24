begin;

create table public.pubg_maps (
  code text primary key,
  display_name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pubg_maps_code_canonical check (
    code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'
  ),
  constraint pubg_maps_display_name_valid check (
    display_name = btrim(display_name)
    and char_length(display_name) between 1 and 80
  )
);

comment on table public.pubg_maps is
  'Canonical PUBG map catalog. New maps can be added without changing tournament match rows or constraints.';

insert into public.pubg_maps (code, display_name)
values
  ('erangel', 'Erangel'),
  ('miramar', 'Miramar'),
  ('sanhok', 'Sanhok');

create table public.tournament_matches (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null
    references public.tournaments (id) on delete restrict,
  match_number integer not null,
  map_code text not null
    references public.pubg_maps (code) on update restrict on delete restrict,
  scheduled_start_at timestamptz not null,
  status text not null default 'scheduled',
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_matches_number_positive check (
    match_number >= 1
  ),
  constraint tournament_matches_status_valid check (
    status in ('scheduled', 'live', 'completed', 'cancelled')
  ),
  constraint tournament_matches_completion_state_valid check (
    (
      status = 'completed'
      and completed_at is not null
      and completed_at >= scheduled_start_at
    )
    or (
      status <> 'completed'
      and completed_at is null
    )
  ),
  constraint tournament_matches_number_per_tournament_unique unique (
    tournament_id,
    match_number
  )
);

comment on table public.tournament_matches is
  'Ordered tournament matches. Results, room credentials, and standings reference the internal match UUID in later migrations.';

comment on column public.tournament_matches.map_code is
  'Canonical lowercase map identifier used for stable per-map statistics.';

comment on column public.tournament_matches.status is
  'Cancelled matches are terminal and must be excluded by future result and standings calculations.';

create index tournament_matches_tournament_status_idx
  on public.tournament_matches (tournament_id, status);

create index tournament_matches_schedule_idx
  on public.tournament_matches (scheduled_start_at);

create index tournament_matches_map_completed_idx
  on public.tournament_matches (map_code, completed_at)
  where status = 'completed';

create function public.levelledup_set_pubg_map_updated_at()
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

alter function public.levelledup_set_pubg_map_updated_at()
  owner to postgres;

revoke all on function public.levelledup_set_pubg_map_updated_at()
  from public, anon, authenticated;

create trigger pubg_maps_set_updated_at
before update on public.pubg_maps
for each row
execute function public.levelledup_set_pubg_map_updated_at();

create function public.levelledup_keep_pubg_map_code()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Canonical PUBG map codes cannot be deleted.'
      using errcode = '22023';
  end if;

  if new.code is distinct from old.code then
    raise exception 'Canonical PUBG map codes cannot be changed.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_pubg_map_code()
  owner to postgres;

revoke all on function public.levelledup_keep_pubg_map_code()
  from public, anon, authenticated;

create trigger pubg_maps_keep_code
before update or delete on public.pubg_maps
for each row
execute function public.levelledup_keep_pubg_map_code();

create function public.levelledup_set_tournament_match_updated_at()
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

alter function public.levelledup_set_tournament_match_updated_at()
  owner to postgres;

revoke all on function public.levelledup_set_tournament_match_updated_at()
  from public, anon, authenticated;

create trigger tournament_matches_set_updated_at
before update on public.tournament_matches
for each row
execute function public.levelledup_set_tournament_match_updated_at();

create function public.levelledup_validate_tournament_match()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
  configured_match_count bigint;
begin
  if tg_op = 'UPDATE'
    and new.tournament_id is distinct from old.tournament_id then
    raise exception 'A match cannot be moved to another tournament.'
      using errcode = '22023';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = new.tournament_id
  for share;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4101';
  end if;

  if selected_tournament.status = 'completed' then
    raise exception 'Matches cannot be changed after tournament completion.'
      using errcode = 'P4102';
  end if;

  if tg_op = 'INSERT'
    and selected_tournament.status = 'cancelled' then
    raise exception 'Matches cannot be added to a cancelled tournament.'
      using errcode = 'P4102';
  end if;

  configured_match_count :=
    selected_tournament.matches_per_day::bigint
    * selected_tournament.number_of_days::bigint;

  if new.match_number::bigint > configured_match_count then
    raise exception 'Match number exceeds the tournament configured match count.'
      using errcode = 'P4103';
  end if;

  if new.scheduled_start_at < selected_tournament.scheduled_start_at
    or (
      selected_tournament.scheduled_end_at is not null
      and new.scheduled_start_at > selected_tournament.scheduled_end_at
    ) then
    raise exception 'Match schedule falls outside the tournament schedule.'
      using errcode = 'P4104';
  end if;

  if tg_op = 'INSERT'
    or new.map_code is distinct from old.map_code then
    if not exists (
      select 1
      from public.pubg_maps
      where pubg_maps.code = new.map_code
        and pubg_maps.is_active
    ) then
      raise exception 'Select an active canonical PUBG map.'
        using errcode = 'P4105';
    end if;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'scheduled' then
      raise exception 'A new match must begin as scheduled.'
        using errcode = 'P4106';
    end if;
  elsif old.status in ('completed', 'cancelled') then
    raise exception 'Completed and cancelled matches are historically immutable.'
      using errcode = 'P4102';
  elsif new.status is distinct from old.status
    and not (
      (old.status = 'scheduled' and new.status in ('live', 'cancelled'))
      or (old.status = 'live' and new.status in ('completed', 'cancelled'))
    ) then
    raise exception 'Invalid match status transition.'
      using errcode = 'P4106';
  end if;

  if tg_op = 'UPDATE'
    and old.status = 'live'
    and (
      new.match_number is distinct from old.match_number
      or new.map_code is distinct from old.map_code
      or new.scheduled_start_at is distinct from old.scheduled_start_at
    ) then
    raise exception 'Live match identity and schedule cannot be changed.'
      using errcode = '22023';
  end if;

  if new.status = 'live'
    and selected_tournament.status <> 'live' then
    raise exception 'A match can go live only while its tournament is live.'
      using errcode = 'P4107';
  end if;

  if new.status = 'completed'
    and selected_tournament.status <> 'live' then
    raise exception 'A match can be completed only while its tournament is live.'
      using errcode = 'P4107';
  end if;

  if selected_tournament.status = 'cancelled'
    and new.status <> 'cancelled' then
    raise exception 'Matches in a cancelled tournament must be cancelled.'
      using errcode = 'P4107';
  end if;

  if new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  else
    new.completed_at := null;
  end if;

  return new;
end;
$$;

alter function public.levelledup_validate_tournament_match()
  owner to postgres;

revoke all on function public.levelledup_validate_tournament_match()
  from public, anon, authenticated;

create trigger tournament_matches_validate
before insert or update on public.tournament_matches
for each row
execute function public.levelledup_validate_tournament_match();

create function public.levelledup_guard_tournament_match_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status in ('completed', 'cancelled')
    or exists (
      select 1
      from public.tournaments
      where tournaments.id = old.tournament_id
        and tournaments.status = 'completed'
    ) then
    raise exception 'Historical tournament matches cannot be deleted.'
      using errcode = '22023';
  end if;

  return old;
end;
$$;

alter function public.levelledup_guard_tournament_match_delete()
  owner to postgres;

revoke all on function public.levelledup_guard_tournament_match_delete()
  from public, anon, authenticated;

create trigger tournament_matches_guard_delete
before delete on public.tournament_matches
for each row
execute function public.levelledup_guard_tournament_match_delete();

create function public.levelledup_guard_tournament_match_configuration()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  configured_match_count bigint :=
    new.matches_per_day::bigint * new.number_of_days::bigint;
begin
  if old.status in ('live', 'completed')
    and (
      new.matches_per_day is distinct from old.matches_per_day
      or new.number_of_days is distinct from old.number_of_days
      or new.scheduled_start_at is distinct from old.scheduled_start_at
      or new.scheduled_end_at is distinct from old.scheduled_end_at
    ) then
    raise exception 'Live and completed tournament match configuration is immutable.'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.tournament_matches
    where tournament_matches.tournament_id = old.id
      and (
        tournament_matches.match_number::bigint > configured_match_count
        or tournament_matches.scheduled_start_at < new.scheduled_start_at
        or (
          new.scheduled_end_at is not null
          and tournament_matches.scheduled_start_at > new.scheduled_end_at
        )
      )
  ) then
    raise exception 'Tournament match configuration conflicts with an existing match.'
      using errcode = 'P4103';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_tournament_match_configuration()
  owner to postgres;

revoke all on function public.levelledup_guard_tournament_match_configuration()
  from public, anon, authenticated;

create trigger tournaments_guard_match_configuration
before update of matches_per_day, number_of_days, scheduled_start_at, scheduled_end_at
on public.tournaments
for each row
execute function public.levelledup_guard_tournament_match_configuration();

create function public.levelledup_guard_tournament_completion_matches()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.status = 'completed'
    and old.status <> 'completed'
    and exists (
      select 1
      from public.tournament_matches
      where tournament_matches.tournament_id = new.id
        and tournament_matches.status not in ('completed', 'cancelled')
    ) then
    raise exception 'Every tournament match must be completed or cancelled first.'
      using errcode = 'P4108';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_tournament_completion_matches()
  owner to postgres;

revoke all on function public.levelledup_guard_tournament_completion_matches()
  from public, anon, authenticated;

create trigger tournaments_guard_completion_matches
before update of status on public.tournaments
for each row
execute function public.levelledup_guard_tournament_completion_matches();

create function public.levelledup_cancel_matches_for_cancelled_tournament()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    update public.tournament_matches
    set status = 'cancelled'
    where tournament_id = new.id
      and status in ('scheduled', 'live');
  end if;

  return new;
end;
$$;

alter function public.levelledup_cancel_matches_for_cancelled_tournament()
  owner to postgres;

revoke all on function public.levelledup_cancel_matches_for_cancelled_tournament()
  from public, anon, authenticated;

create trigger tournaments_cancel_active_matches
after update of status on public.tournaments
for each row
execute function public.levelledup_cancel_matches_for_cancelled_tournament();

alter table public.pubg_maps enable row level security;
alter table public.tournament_matches enable row level security;

revoke all on table public.pubg_maps
  from public, anon, authenticated;
revoke all on table public.tournament_matches
  from public, anon, authenticated;

grant select on table public.pubg_maps
  to authenticated;
grant select on table public.tournament_matches
  to authenticated;

create policy "Authenticated users can read PUBG maps"
  on public.pubg_maps
  for select
  to authenticated
  using (true);

create policy "Authenticated users can read non-draft tournament matches"
  on public.tournament_matches
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.tournaments
      where tournaments.id = tournament_matches.tournament_id
        and tournaments.status <> 'draft'
    )
  );

commit;
