begin;

create function public.levelledup_random_team_id()
returns text
language sql
volatile
set search_path = ''
as $$
  select 'LU-' || string_agg(
    substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
      floor(random() * 32)::integer + 1,
      1
    ),
    ''
  )
  from generate_series(1, 6);
$$;

revoke execute on function public.levelledup_random_team_id()
  from public, anon, authenticated;

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  team_id text not null default public.levelledup_random_team_id(),
  name text not null,
  short_name text,
  logo_url text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint teams_team_id_unique unique (team_id),
  constraint teams_team_id_format check (team_id ~ '^LU-[A-HJ-NP-Z2-9]{6}$'),
  constraint teams_name_format check (
    name = btrim(name)
    and char_length(name) between 2 and 80
  ),
  constraint teams_short_name_format check (
    short_name is null
    or (
      short_name = btrim(short_name)
      and char_length(short_name) between 2 and 12
    )
  ),
  constraint teams_logo_url_format check (
    logo_url is null
    or (
      logo_url = btrim(logo_url)
      and char_length(logo_url) <= 2048
      and logo_url ~* '^https?://[^[:space:]]+$'
    )
  )
);

comment on table public.teams is
  'Persistent LevelledUp teams, independent of tournament participation.';

comment on column public.teams.team_id is
  'Permanent public team identifier used for exact team discovery.';

comment on column public.teams.created_by is
  'Auth user who originally created the team; provenance only, not authorization.';

create index teams_created_by_idx on public.teams (created_by);
create index teams_name_search_idx on public.teams (lower(name));

alter table public.teams enable row level security;

revoke all on table public.teams from anon, authenticated;
grant select on table public.teams to authenticated;

create policy "Authenticated users can read teams"
  on public.teams
  for select
  to authenticated
  using (true);

create function public.levelledup_set_team_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke execute on function public.levelledup_set_team_updated_at()
  from public, anon, authenticated;

create trigger teams_set_updated_at
before update on public.teams
for each row
execute function public.levelledup_set_team_updated_at();

create function public.levelledup_keep_team_id()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.team_id is distinct from old.team_id then
    raise exception 'The permanent LevelledUp Team ID cannot be changed.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

revoke execute on function public.levelledup_keep_team_id()
  from public, anon, authenticated;

create trigger teams_keep_team_id
before update of team_id on public.teams
for each row
execute function public.levelledup_keep_team_id();

commit;
