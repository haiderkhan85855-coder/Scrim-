begin;

create table public.admin_users (
  user_id uuid primary key
    references auth.users (id) on delete restrict,
  role text not null,
  granted_by uuid
    references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint admin_users_role_valid check (
    role in ('admin', 'super_admin')
  )
);

comment on table public.admin_users is
  'LevelledUp staff authorization keyed only by verified Supabase Auth user IDs. Team and profile roles are intentionally unrelated.';

comment on column public.admin_users.granted_by is
  'Auth user that granted this staff role. Null is reserved for the one-time database-owner bootstrap.';

create index admin_users_role_idx
  on public.admin_users (role);

create function public.levelledup_set_admin_user_updated_at()
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

alter function public.levelledup_set_admin_user_updated_at()
  owner to postgres;

revoke all on function public.levelledup_set_admin_user_updated_at()
  from public, anon, authenticated;

create trigger admin_users_set_updated_at
before update on public.admin_users
for each row
execute function public.levelledup_set_admin_user_updated_at();

create function public.levelledup_keep_admin_user_identity()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id then
    raise exception 'An admin authorization row cannot be reassigned to another user.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_admin_user_identity()
  owner to postgres;

revoke all on function public.levelledup_keep_admin_user_identity()
  from public, anon, authenticated;

create trigger admin_users_keep_identity
before update of user_id on public.admin_users
for each row
execute function public.levelledup_keep_admin_user_identity();

create function public.levelledup_current_admin_role()
returns text
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select admin_users.role
  from public.admin_users
  where admin_users.user_id = auth.uid();
$$;

alter function public.levelledup_current_admin_role()
  owner to postgres;

revoke all on function public.levelledup_current_admin_role()
  from public, anon, authenticated;
grant execute on function public.levelledup_current_admin_role()
  to authenticated;

comment on function public.levelledup_current_admin_role() is
  'Returns only the authenticated caller staff role, or null. It cannot inspect another user.';

create function public.levelledup_has_admin_role(
  p_required_role text default 'admin'
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
begin
  if authenticated_user_id is null then
    return false;
  end if;

  if p_required_role is null
    or p_required_role not in ('admin', 'super_admin') then
    raise exception 'Unknown LevelledUp admin role.'
      using errcode = '22023';
  end if;

  return exists (
    select 1
    from public.admin_users
    where admin_users.user_id = authenticated_user_id
      and (
        admin_users.role = 'super_admin'
        or (
          p_required_role = 'admin'
          and admin_users.role = 'admin'
        )
      )
  );
end;
$$;

alter function public.levelledup_has_admin_role(text)
  owner to postgres;

revoke all on function public.levelledup_has_admin_role(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_has_admin_role(text)
  to authenticated;

comment on function public.levelledup_has_admin_role(text) is
  'Checks only auth.uid(). super_admin satisfies both operational and super-admin checks.';

create function public.levelledup_require_admin(
  p_required_role text default 'admin'
)
returns void
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  if not public.levelledup_has_admin_role(p_required_role) then
    raise exception 'LevelledUp admin authorization is required.'
      using errcode = '42501';
  end if;
end;
$$;

alter function public.levelledup_require_admin(text)
  owner to postgres;

-- This assertion is an internal building block for SECURITY DEFINER RPCs.
-- It is deliberately not callable directly by browser roles.
revoke all on function public.levelledup_require_admin(text)
  from public, anon, authenticated;

comment on function public.levelledup_require_admin(text) is
  'Internal assertion for trusted RPCs. Future tournament operations must call this inside the same database transaction.';

alter table public.admin_users enable row level security;

revoke all on table public.admin_users
  from public, anon, authenticated;

-- No direct table policies are intentional. Authenticated users can learn
-- only their own role through the narrowly scoped helper functions above.

commit;
