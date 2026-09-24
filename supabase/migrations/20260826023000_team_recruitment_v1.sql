begin;

create table public.team_recruitment_posts (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null unique
    references public.teams (id) on delete restrict,
  mic_required boolean not null default false,
  captain_note text,
  status text not null default 'open',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint team_recruitment_posts_status_valid check (
    status in ('open', 'closed')
  ),
  constraint team_recruitment_posts_note_valid check (
    captain_note is null
    or (
      captain_note = btrim(captain_note)
      and char_length(captain_note) between 1 and 500
    )
  )
);

create index team_recruitment_posts_open_created_idx
  on public.team_recruitment_posts (created_at desc)
  where status = 'open';

comment on table public.team_recruitment_posts is
  'One V1 recruitment post per persistent team. Structured requirements are intentionally deferred.';

create function public.levelledup_set_recruitment_updated_at()
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

alter function public.levelledup_set_recruitment_updated_at()
  owner to postgres;

revoke all on function public.levelledup_set_recruitment_updated_at()
  from public, anon, authenticated;

create trigger team_recruitment_posts_set_updated_at
before update on public.team_recruitment_posts
for each row
execute function public.levelledup_set_recruitment_updated_at();

alter table public.team_recruitment_posts enable row level security;

revoke all on table public.team_recruitment_posts
  from public, anon, authenticated;
grant select on table public.team_recruitment_posts
  to authenticated;

create policy "Active team members can read recruitment"
  on public.team_recruitment_posts
  for select
  to authenticated
  using (public.levelledup_is_active_team_member(team_id));

create function public.levelledup_save_team_recruitment(
  p_team_id uuid,
  p_mic_required boolean,
  p_captain_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_note text := nullif(btrim(p_captain_note), '');
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to manage recruitment.'
      using errcode = '42501';
  end if;

  if normalized_note is not null and char_length(normalized_note) > 500 then
    raise exception 'Captain note must be 500 characters or fewer.'
      using errcode = '22023';
  end if;

  perform 1
  from public.teams
  where teams.id = p_team_id
    and teams.status = 'active'
  for update;

  if not found then
    raise exception 'The team is no longer active.'
      using errcode = 'P3020';
  end if;

  if not public.levelledup_is_active_team_captain(p_team_id) then
    raise exception 'Only the active team captain can manage recruitment.'
      using errcode = '42501';
  end if;

  insert into public.team_recruitment_posts (
    team_id,
    mic_required,
    captain_note
  )
  values (
    p_team_id,
    p_mic_required,
    normalized_note
  )
  on conflict (team_id) do update
  set
    mic_required = excluded.mic_required,
    captain_note = excluded.captain_note;

  return true;
end;
$$;

alter function public.levelledup_save_team_recruitment(uuid, boolean, text)
  owner to postgres;

revoke all on function public.levelledup_save_team_recruitment(uuid, boolean, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_save_team_recruitment(uuid, boolean, text)
  to authenticated;

create function public.levelledup_set_team_recruitment_status(
  p_team_id uuid,
  p_status text
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_status text := lower(btrim(coalesce(p_status, '')));
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to manage recruitment.'
      using errcode = '42501';
  end if;

  if normalized_status not in ('open', 'closed') then
    raise exception 'Recruitment status must be open or closed.'
      using errcode = '22023';
  end if;

  perform 1
  from public.teams
  where teams.id = p_team_id
    and teams.status = 'active'
  for update;

  if not found then
    raise exception 'The team is no longer active.'
      using errcode = 'P3020';
  end if;

  if not public.levelledup_is_active_team_captain(p_team_id) then
    raise exception 'Only the active team captain can manage recruitment.'
      using errcode = '42501';
  end if;

  update public.team_recruitment_posts
  set status = normalized_status
  where team_id = p_team_id;

  if not found then
    raise exception 'Create a recruitment post before changing its status.'
      using errcode = 'P3031';
  end if;

  return true;
end;
$$;

alter function public.levelledup_set_team_recruitment_status(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_set_team_recruitment_status(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_set_team_recruitment_status(uuid, text)
  to authenticated;

create function public.levelledup_list_open_team_recruitment()
returns table (
  team_name text,
  team_public_id text,
  mic_required boolean,
  captain_note text
)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to browse recruitment.'
      using errcode = '42501';
  end if;

  return query
  select
    teams.name,
    teams.team_id,
    recruitment.mic_required,
    recruitment.captain_note
  from public.team_recruitment_posts as recruitment
  join public.teams as teams
    on teams.id = recruitment.team_id
  where recruitment.status = 'open'
    and teams.status = 'active'
  order by recruitment.created_at desc;
end;
$$;

alter function public.levelledup_list_open_team_recruitment()
  owner to postgres;

revoke all on function public.levelledup_list_open_team_recruitment()
  from public, anon, authenticated;
grant execute on function public.levelledup_list_open_team_recruitment()
  to authenticated;

create function public.levelledup_close_recruitment_for_inactive_team()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status = 'active' and new.status <> 'active' then
    update public.team_recruitment_posts
    set status = 'closed'
    where team_id = new.id
      and status = 'open';
  end if;

  return new;
end;
$$;

alter function public.levelledup_close_recruitment_for_inactive_team()
  owner to postgres;

revoke all on function public.levelledup_close_recruitment_for_inactive_team()
  from public, anon, authenticated;

create trigger teams_close_recruitment_when_inactive
after update of status on public.teams
for each row
execute function public.levelledup_close_recruitment_for_inactive_team();

commit;
