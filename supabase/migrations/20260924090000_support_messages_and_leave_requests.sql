-- Captain -> admin support messages, and the captain-approved leave-request flow.
--
-- Haider's rules (2026-09-24):
--   * Notification bar is for payment issues AND messages from team captains.
--     For a captain the same surface is a 24/7 support button.
--   * Only the captain can remove a person. A player who wants to leave sends a
--     request; the request goes to the captain, who approves it (removal happens
--     then, with history preserved). Direct self-leave is replaced by this flow.
--   * No 1+1+4 composition: up to six Squad members, anyone may play any match.

begin;

-- ---------------------------------------------------------------------------
-- 1. support_messages: captain -> admin one-way messages (admin reads them in
--    the notification section).
-- ---------------------------------------------------------------------------
create table public.support_messages (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams (id) on delete cascade,
  sender_profile_id uuid not null references public.profiles (id) on delete cascade,
  message text not null
    check (char_length(btrim(message)) between 1 and 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);

comment on table public.support_messages is
  'Captain-to-admin support messages. Surfaced in the admin notification section; for captains the entry point is the 24/7 support button.';

alter table public.support_messages enable row level security;

-- Deny direct table access; every path goes through SECURITY DEFINER RPCs.
create policy support_messages_deny_all on public.support_messages
  for all using (false) with check (false);

create index support_messages_unread_idx
  on public.support_messages (created_at desc)
  where read_at is null;

-- ---------------------------------------------------------------------------
-- 2. team_leave_requests: a player asks to leave, the captain approves/rejects.
-- ---------------------------------------------------------------------------
create table public.team_leave_requests (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams (id) on delete cascade,
  requester_profile_id uuid not null references public.profiles (id) on delete cascade,
  roster_member_id uuid not null references public.team_roster_members (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by_profile_id uuid references public.profiles (id) on delete set null
);

comment on table public.team_leave_requests is
  'Voluntary leave requests: a Squad member asks to leave, only the captain can approve (which removes them, history preserved) or reject.';

alter table public.team_leave_requests enable row level security;

create policy team_leave_requests_deny_all on public.team_leave_requests
  for all using (false) with check (false);

-- One pending request per roster membership at a time.
create unique index team_leave_requests_one_pending_per_member
  on public.team_leave_requests (roster_member_id)
  where status = 'pending';

create index team_leave_requests_team_pending_idx
  on public.team_leave_requests (team_id, created_at desc)
  where status = 'pending';

-- ---------------------------------------------------------------------------
-- 3. RPCs
-- ---------------------------------------------------------------------------

-- Captain sends a support message to the admin.
create function public.levelledup_send_support_message(
  p_team_id uuid,
  p_message text
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_message text := btrim(coalesce(p_message, ''));
  new_id uuid;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to contact support.'
      using errcode = '42501';
  end if;

  if not public.levelledup_is_active_team_captain(p_team_id) then
    raise exception 'Only the team captain can send a support message.'
      using errcode = '42501';
  end if;

  if char_length(normalized_message) < 1 or char_length(normalized_message) > 2000 then
    raise exception 'The message must be between 1 and 2000 characters.'
      using errcode = 'P3001';
  end if;

  insert into public.support_messages (team_id, sender_profile_id, message)
  values (p_team_id, authenticated_user_id, normalized_message)
  returning id into new_id;

  return new_id;
end;
$$;

alter function public.levelledup_send_support_message(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_send_support_message(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_send_support_message(uuid, text)
  to authenticated;

comment on function public.levelledup_send_support_message(uuid, text) is
  'Captain-only: sends a support message to the admin (appears in the admin notification section).';

-- Admin lists support messages (unread first).
create function public.levelledup_list_support_messages()
returns table (
  id uuid,
  team_id uuid,
  team_name text,
  sender_name text,
  message text,
  created_at timestamptz,
  read_at timestamptz
)
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  return query
  select
    m.id,
    m.team_id,
    t.name,
    coalesce(nullif(btrim(p.display_name), ''), 'Captain'),
    m.message,
    m.created_at,
    m.read_at
  from public.support_messages as m
  join public.teams as t on t.id = m.team_id
  left join public.profiles as p on p.id = m.sender_profile_id
  order by m.read_at nulls first, m.created_at desc
  limit 200;
end;
$$;

alter function public.levelledup_list_support_messages()
  owner to postgres;

revoke all on function public.levelledup_list_support_messages()
  from public, anon, authenticated;
grant execute on function public.levelledup_list_support_messages()
  to authenticated;

-- Admin marks a support message as read.
create function public.levelledup_mark_support_message_read(
  p_message_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  update public.support_messages
  set read_at = coalesce(read_at, now())
  where id = p_message_id;

  if not found then
    raise exception 'Support message not found.'
      using errcode = 'P3011';
  end if;

  return true;
end;
$$;

alter function public.levelledup_mark_support_message_read(uuid)
  owner to postgres;

revoke all on function public.levelledup_mark_support_message_read(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_mark_support_message_read(uuid)
  to authenticated;

-- Squad member requests to leave; the captain must approve.
create function public.levelledup_request_team_leave(
  p_team_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  roster_member public.team_roster_members;
  new_id uuid;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to request leaving a team.'
      using errcode = '42501';
  end if;

  select team_roster_members.*
  into roster_member
  from public.team_roster_members
  where team_roster_members.team_id = p_team_id
    and team_roster_members.profile_id = authenticated_user_id
    and team_roster_members.status = 'active'
  for update;

  if roster_member.id is null then
    raise exception 'Active team membership not found.'
      using errcode = 'P3011';
  end if;

  if roster_member.role = 'captain' then
    raise exception 'Captains must transfer leadership or disband the team before leaving.'
      using errcode = 'P3010';
  end if;

  begin
    insert into public.team_leave_requests (team_id, requester_profile_id, roster_member_id)
    values (p_team_id, authenticated_user_id, roster_member.id)
    returning id into new_id;
  exception
    when unique_violation then
      raise exception 'You already have a pending leave request for this team.'
        using errcode = 'P3013';
  end;

  return new_id;
end;
$$;

alter function public.levelledup_request_team_leave(uuid)
  owner to postgres;

revoke all on function public.levelledup_request_team_leave(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_request_team_leave(uuid)
  to authenticated;

comment on function public.levelledup_request_team_leave(uuid) is
  'A Squad member requests to leave; only the captain can approve the request (approval removes the member, history preserved).';

-- Captain approves or rejects a leave request.
create function public.levelledup_decide_team_leave(
  p_request_id uuid,
  p_approve boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  leave_request public.team_leave_requests;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to decide a leave request.'
      using errcode = '42501';
  end if;

  select team_leave_requests.*
  into leave_request
  from public.team_leave_requests
  where team_leave_requests.id = p_request_id
  for update;

  if leave_request.id is null then
    raise exception 'Leave request not found.'
      using errcode = 'P3011';
  end if;

  if leave_request.status <> 'pending' then
    raise exception 'This leave request was already decided.'
      using errcode = 'P3014';
  end if;

  if not public.levelledup_is_active_team_captain(leave_request.team_id) then
    raise exception 'Only the team captain can decide leave requests.'
      using errcode = '42501';
  end if;

  if p_approve then
    -- Approved: the member leaves with history preserved (same as a voluntary
    -- leave; the captain's approval is the audit trail).
    update public.team_roster_members
    set status = 'left'
    where id = leave_request.roster_member_id
      and status = 'active';

    if not found then
      raise exception 'The Squad member is no longer active.'
        using errcode = 'P3011';
    end if;

    update public.team_leave_requests
    set status = 'approved',
        decided_at = now(),
        decided_by_profile_id = authenticated_user_id
    where id = leave_request.id;
  else
    update public.team_leave_requests
    set status = 'rejected',
        decided_at = now(),
        decided_by_profile_id = authenticated_user_id
    where id = leave_request.id;
  end if;

  return true;
end;
$$;

alter function public.levelledup_decide_team_leave(uuid, boolean)
  owner to postgres;

revoke all on function public.levelledup_decide_team_leave(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.levelledup_decide_team_leave(uuid, boolean)
  to authenticated;

comment on function public.levelledup_decide_team_leave(uuid, boolean) is
  'Captain-only: approves (removes the member, history preserved) or rejects a pending leave request.';

-- Lists pending leave requests for a team. Captains see every pending request;
-- other members see only their own.
create function public.levelledup_list_team_leave_requests(
  p_team_id uuid
)
returns table (
  id uuid,
  requester_name text,
  is_own_request boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  viewer_is_captain boolean;
  viewer_is_member boolean;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  select exists (
    select 1
    from public.team_roster_members
    where team_roster_members.team_id = p_team_id
      and team_roster_members.profile_id = authenticated_user_id
      and team_roster_members.status = 'active'
  ) into viewer_is_member;

  if not viewer_is_member then
    raise exception 'Only team members can view leave requests.'
      using errcode = '42501';
  end if;

  viewer_is_captain := public.levelledup_is_active_team_captain(p_team_id);

  return query
  select
    r.id,
    coalesce(nullif(btrim(p.display_name), ''), 'Squad member'),
    r.requester_profile_id = authenticated_user_id,
    r.created_at
  from public.team_leave_requests as r
  left join public.profiles as p on p.id = r.requester_profile_id
  where r.team_id = p_team_id
    and r.status = 'pending'
    and (viewer_is_captain or r.requester_profile_id = authenticated_user_id)
  order by r.created_at asc;
end;
$$;

alter function public.levelledup_list_team_leave_requests(uuid)
  owner to postgres;

revoke all on function public.levelledup_list_team_leave_requests(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_list_team_leave_requests(uuid)
  to authenticated;

commit;
