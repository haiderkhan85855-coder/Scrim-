-- Fix 8: disbanding becomes a request with approvals, expiry, and archive.
--
-- Haider's approved rules:
--   * Captain enters the permanent team ID to request disbanding.
--   * Disband becomes a request; two other players must approve.
--   * The request expires after 48 hours without both approvals.
--   * The captain may cancel a pending request.
--   * Archive, never delete (existing archive behavior preserved).
--   * Disbanding is not blocked merely because a tournament is active.
--   * The existing tournament-withdraw flow remains available (unchanged).
--
-- When the second approval lands, the existing archive sequence runs:
-- credit eligible unused entries before registration close, archive the
-- team, deactivate memberships, reject pending join requests.

create table public.team_disband_requests (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  team_id uuid not null references public.teams (id),
  requested_by uuid not null,
  confirmation_team_id text not null,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'cancelled', 'expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now(),
  decided_at timestamptz,
  decided_by uuid
);

create index team_disband_requests_team_status_idx
  on public.team_disband_requests (team_id, status);

create table public.team_disband_approvals (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  request_id uuid not null
    references public.team_disband_requests (id) on delete cascade,
  approver_profile_id uuid not null,
  approved_at timestamptz not null default pg_catalog.now(),
  constraint team_disband_approvals_unique_approver
    unique (request_id, approver_profile_id)
);

create index team_disband_approvals_request_idx
  on public.team_disband_approvals (request_id);

alter table public.team_disband_requests enable row level security;
alter table public.team_disband_approvals enable row level security;
revoke all on table public.team_disband_requests from anon, authenticated;
revoke all on table public.team_disband_approvals from anon, authenticated;

-- Reads go through the RPC below; no direct table grants.

create or replace function public.levelledup_request_team_disband(
  p_team_id uuid,
  p_confirmation_team_id text
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_team public.teams;
  new_request_id uuid;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to request disbanding.'
      using errcode = '42501';
  end if;

  select teams.*
  into selected_team
  from public.teams as teams
  where teams.id = p_team_id
  for update;

  if selected_team.id is null or selected_team.status <> 'active' then
    raise exception 'The team is no longer active.' using errcode = 'P3020';
  end if;

  if not public.levelledup_is_active_team_captain(selected_team.id) then
    raise exception 'Only the active captain can request disbanding.'
      using errcode = '42501';
  end if;

  if upper(btrim(coalesce(p_confirmation_team_id, ''))) <> selected_team.team_id then
    raise exception 'Team ID confirmation does not match.' using errcode = 'P3022';
  end if;

  if exists (
    select 1
    from public.team_disband_requests as requests
    where requests.team_id = selected_team.id
      and requests.status = 'pending'
  ) then
    raise exception 'A disband request is already pending for this team.'
      using errcode = 'P3033';
  end if;

  insert into public.team_disband_requests (
    team_id, requested_by, confirmation_team_id, expires_at
  )
  values (
    selected_team.id,
    authenticated_user_id,
    selected_team.team_id,
    pg_catalog.now() + interval '48 hours'
  )
  returning id into new_request_id;

  return new_request_id;
end;
$$;

alter function public.levelledup_request_team_disband(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_request_team_disband(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_request_team_disband(uuid, text)
  to authenticated;

create or replace function public.levelledup_approve_team_disband(
  p_request_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  disband_request public.team_disband_requests;
  selected_team public.teams;
  selected_registration record;
  approval_count integer;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to approve disbanding.'
      using errcode = '42501';
  end if;

  select requests.*
  into disband_request
  from public.team_disband_requests as requests
  where requests.id = p_request_id
  for update;

  if disband_request.id is null then
    raise exception 'Disband request not found.' using errcode = 'P3034';
  end if;

  if disband_request.status = 'pending'
    and disband_request.expires_at <= pg_catalog.now() then
    update public.team_disband_requests
    set status = 'expired', decided_at = pg_catalog.now()
    where id = disband_request.id;
    raise exception 'The disband request has expired.'
      using errcode = 'P3034';
  end if;

  if disband_request.status <> 'pending' then
    raise exception 'The disband request is no longer pending.'
      using errcode = 'P3034';
  end if;

  select teams.*
  into selected_team
  from public.teams as teams
  where teams.id = disband_request.team_id
  for update;

  if selected_team.id is null or selected_team.status <> 'active' then
    raise exception 'The team is no longer active.' using errcode = 'P3020';
  end if;

  -- Two OTHER players: the requesting captain cannot approve their own request.
  if authenticated_user_id = disband_request.requested_by then
    raise exception 'The requesting captain cannot approve their own request.'
      using errcode = 'P3035';
  end if;

  if not exists (
    select 1
    from public.team_roster_members as members
    where members.team_id = selected_team.id
      and members.profile_id = authenticated_user_id
      and members.status = 'active'
  ) then
    raise exception 'Only active Squad members can approve disbanding.'
      using errcode = 'P3035';
  end if;

  begin
    insert into public.team_disband_approvals (request_id, approver_profile_id)
    values (disband_request.id, authenticated_user_id);
  exception
    when unique_violation then
      raise exception 'You have already approved this request.'
        using errcode = 'P3036';
  end;

  select count(*)::integer
  into approval_count
  from public.team_disband_approvals
  where request_id = disband_request.id;

  if approval_count < 2 then
    return false;
  end if;

  -- Second approval: execute the archive sequence (same as the legacy
  -- immediate disband). Disbanding is not blocked by active tournaments;
  -- only pre-registration-close unused entries become credit.
  for selected_registration in
    select registrations.id
    from public.tournament_registrations as registrations
    join public.tournaments as tournaments
      on tournaments.id = registrations.tournament_id
    where registrations.team_id = selected_team.id
      and registrations.status in ('pending', 'confirmed')
      and pg_catalog.clock_timestamp() < tournaments.registration_closes_at
    order by registrations.created_at, registrations.id
    for update of registrations
  loop
    perform public.levelledup_credit_unused_entries_before_registration_close(
      selected_registration.id,
      authenticated_user_id,
      'Team disbanded after two player approvals'
    );
  end loop;

  update public.teams
  set
    status = 'disbanded',
    disbanded_at = pg_catalog.now(),
    disbanded_by = disband_request.requested_by
  where id = selected_team.id;

  update public.team_roster_members
  set status = 'disbanded'
  where team_id = selected_team.id
    and status = 'active';

  update public.team_join_requests
  set
    status = 'rejected',
    reviewed_at = pg_catalog.now(),
    reviewed_by = authenticated_user_id
  where team_id = selected_team.id
    and status = 'pending';

  update public.team_disband_requests
  set
    status = 'approved',
    decided_at = pg_catalog.now(),
    decided_by = authenticated_user_id
  where id = disband_request.id;

  return true;
end;
$$;

alter function public.levelledup_approve_team_disband(uuid)
  owner to postgres;
revoke all on function public.levelledup_approve_team_disband(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_approve_team_disband(uuid)
  to authenticated;

create or replace function public.levelledup_cancel_team_disband(
  p_request_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  disband_request public.team_disband_requests;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to cancel disbanding.'
      using errcode = '42501';
  end if;

  select requests.*
  into disband_request
  from public.team_disband_requests as requests
  where requests.id = p_request_id
  for update;

  if disband_request.id is null or disband_request.status <> 'pending' then
    raise exception 'The disband request is no longer pending.'
      using errcode = 'P3034';
  end if;

  if not public.levelledup_is_active_team_captain(disband_request.team_id) then
    raise exception 'Only the active captain can cancel the disband request.'
      using errcode = '42501';
  end if;

  update public.team_disband_requests
  set
    status = 'cancelled',
    decided_at = pg_catalog.now(),
    decided_by = authenticated_user_id
  where id = disband_request.id;

  return true;
end;
$$;

alter function public.levelledup_cancel_team_disband(uuid)
  owner to postgres;
revoke all on function public.levelledup_cancel_team_disband(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_cancel_team_disband(uuid)
  to authenticated;

-- Explicit expiry sweep (also enforced lazily inside the approve RPC).
create or replace function public.levelledup_expire_team_disband_requests()
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  expired_count integer;
begin
  update public.team_disband_requests
  set status = 'expired', decided_at = pg_catalog.now()
  where status = 'pending'
    and expires_at <= pg_catalog.now();

  get diagnostics expired_count = row_count;
  return expired_count;
end;
$$;

alter function public.levelledup_expire_team_disband_requests()
  owner to postgres;
revoke all on function public.levelledup_expire_team_disband_requests()
  from public, anon, authenticated;
grant execute on function public.levelledup_expire_team_disband_requests()
  to authenticated;

-- Pending request + approvals for the team page (callers see only their teams).
create or replace function public.levelledup_get_team_disband_request(
  p_team_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  disband_request public.team_disband_requests;
  approval_count integer;
  caller_approved boolean;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.team_roster_members as members
    where members.team_id = p_team_id
      and members.profile_id = authenticated_user_id
      and members.status in ('active', 'disbanded')
  ) then
    raise exception 'Team membership is required.' using errcode = '42501';
  end if;

  perform public.levelledup_expire_team_disband_requests();

  select requests.*
  into disband_request
  from public.team_disband_requests as requests
  where requests.team_id = p_team_id
    and requests.status = 'pending'
  order by requests.created_at desc
  limit 1;

  if disband_request.id is null then
    return jsonb_build_object('request', null);
  end if;

  select count(*)::integer
  into approval_count
  from public.team_disband_approvals
  where request_id = disband_request.id;

  select exists (
    select 1
    from public.team_disband_approvals
    where request_id = disband_request.id
      and approver_profile_id = authenticated_user_id
  )
  into caller_approved;

  return jsonb_build_object(
    'request', jsonb_build_object(
      'id', disband_request.id,
      'teamId', disband_request.team_id,
      'requestedBy', disband_request.requested_by,
      'isCallerRequester', disband_request.requested_by = authenticated_user_id,
      'status', disband_request.status,
      'expiresAt', disband_request.expires_at,
      'createdAt', disband_request.created_at,
      'approvalCount', approval_count,
      'approvalsNeeded', 2,
      'callerApproved', caller_approved
    )
  );
end;
$$;

alter function public.levelledup_get_team_disband_request(uuid)
  owner to postgres;
revoke all on function public.levelledup_get_team_disband_request(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_get_team_disband_request(uuid)
  to authenticated;
