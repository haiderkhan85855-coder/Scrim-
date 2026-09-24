begin;

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  pubg_ign text,
  pubg_uid text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Application profile with a one-to-one identity relationship to auth.users.';

comment on column public.profiles.pubg_uid is
  'PUBG Mobile UID stored as text; uniqueness is deferred until UID ownership verification exists.';

alter table public.profiles enable row level security;

-- Public-schema tables may inherit broad API grants. Start closed, then grant
-- only the operations and columns required by the initial profile flow.
revoke all on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (display_name, pubg_ign, pubg_uid, avatar_url)
  on table public.profiles to authenticated;

create policy "Users can read their own profile"
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "Users can update their own profile"
  on public.profiles
  for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create function public.levelledup_set_profile_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke execute on function public.levelledup_set_profile_updated_at()
  from public, anon, authenticated;

create trigger profiles_set_updated_at
before update on public.profiles
for each row
execute function public.levelledup_set_profile_updated_at();

create function public.levelledup_handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke execute on function public.levelledup_handle_new_auth_user()
  from public, anon, authenticated;

create trigger on_auth_user_created_create_profile
after insert on auth.users
for each row
execute function public.levelledup_handle_new_auth_user();

-- Create profiles for Auth users that predate this migration. The conflict
-- clause preserves any profile that may already exist and makes the backfill
-- safe against the new-user trigger.
insert into public.profiles (id, created_at, updated_at)
select
  users.id,
  coalesce(users.created_at, now()),
  coalesce(users.created_at, now())
from auth.users as users
on conflict (id) do nothing;

commit;
