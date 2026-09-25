-- 20260924140000_team_entry_shift_notifications.sql
--
-- Team-wide notifications for session entry shifts, plus a bulk move RPC.
--
-- Locked rules (Haider, 2026-09-25):
--   1. Notifications are pushed to the TEAM, not the captain. Every active
--      roster member sees them in their profile notification section, shown
--      as team notifications (separate from personal ones).
--   2. A player who joins a team later never sees older notifications: at
--      creation the notification is fanned out to current active members only.
--   3. Anyone on the team may delete one, several, or all of their
--      notifications. Deletion clears only that person's own view; teammates
--      still see theirs.
--   4. Read/unread state is per person.
--   5. A trigger writes the notification automatically whenever an active
--      entry's session changes (single move, bulk move, any future mover).
--      Direct writes to the tables are refused; only the trigger inserts.
--   6. Bulk shift: moves every movable entry, skips the rest with reasons,
--      and returns a {moved, skipped} report. Re-running a bulk call is safe:
--      already-moved entries are a no-op, skipped ones are retried.
--
-- Handoff basis: "admin may move the mark to a later session of the SAME
-- stage if room" (NEW-RULES-CHANGELOG.md); Haider's 2026-09-25 decisions:
-- "i need authority to shift them to next session and they'll know that".

begin;

-- ----------------------------------------------------------------------------
-- 1. team_notifications: one row per event per team.
-- ----------------------------------------------------------------------------

create table public.team_notifications (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams (id) on delete cascade,
  tournament_id uuid not null references public.tournaments (id) on delete cascade,
  type text not null,
  title text not null,
  message text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint team_notifications_type_valid check (
    type = btrim(type) and char_length(type) between 1 and 60
  ),
  constraint team_notifications_title_valid check (
    title = btrim(title) and char_length(title) between 1 and 120
  ),
  constraint team_notifications_message_valid check (
    message = btrim(message) and char_length(message) between 1 and 2000
  )
);

comment on table public.team_notifications is
  'Team-scoped notifications. One row per event per team; visibility and read state live in team_notification_recipients.';

create index team_notifications_team_created_idx
  on public.team_notifications (team_id, created_at desc);

-- ----------------------------------------------------------------------------
-- 2. team_notification_recipients: fan-out to current members at push time.
--    A member who joins later gets no rows for older notifications, so they
--    never see them. Deleting a row clears only that person's own view.
--    read_at null = unread.
-- ----------------------------------------------------------------------------

create table public.team_notification_recipients (
  notification_id uuid not null
    references public.team_notifications (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (notification_id, user_id)
);

comment on table public.team_notification_recipients is
  'Per-member visibility of team notifications. Rows are created only for active roster members at push time, so later joiners never see older notifications.';

create index team_notification_recipients_user_created_idx
  on public.team_notification_recipients (user_id, created_at desc);

alter table public.team_notifications enable row level security;
alter table public.team_notification_recipients enable row level security;

revoke all on table public.team_notifications from anon, authenticated;
revoke all on table public.team_notification_recipients from anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. Trigger: notify the team whenever an active entry's session changes.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_notify_team_on_entry_session_change()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  team_id uuid;
  tournament_name text;
  old_session_name text;
  new_session_name text;
  last_move jsonb;
  move_reason text;
  notification_id uuid;
begin
  if old.session_id is not distinct from new.session_id then
    return new;
  end if;

  if new.status <> 'active' then
    return new;
  end if;

  select registration.team_id into team_id
  from public.tournament_registrations as registration
  where registration.id = new.registration_id;

  if team_id is null then
    return new;
  end if;

  select tournament.name into tournament_name
  from public.tournaments as tournament
  where tournament.id = new.tournament_id;

  select session.display_name into old_session_name
  from public.tournament_stage_sessions as session
  where session.id = old.session_id;

  select session.display_name into new_session_name
  from public.tournament_stage_sessions as session
  where session.id = new.session_id;

  last_move :=
    coalesce(new.source_provenance -> 'session_moves', '[]'::jsonb) -> -1;
  move_reason := nullif(btrim(coalesce(last_move ->> 'reason', '')), '');

  insert into public.team_notifications
    (team_id, tournament_id, type, title, message, metadata)
  values (
    team_id,
    new.tournament_id,
    'session_entry_moved',
    'Session changed',
    'Your entry for ' || coalesce(tournament_name, 'the tournament')
      || ' was moved from ' || coalesce(old_session_name, 'a session')
      || ' to ' || coalesce(new_session_name, 'a session') || '.'
      || case
           when move_reason is not null then ' Reason: ' || move_reason
           else ''
         end,
    jsonb_build_object(
      'entry_id', new.id::text,
      'from_session_id', old.session_id::text,
      'to_session_id', new.session_id::text
    )
  )
  returning id into notification_id;

  -- Fan out to current active members only. Unclaimed roster slots
  -- (profile_id null) and left/removed members get nothing.
  insert into public.team_notification_recipients (notification_id, user_id)
  select notification_id, member.profile_id
  from public.team_roster_members as member
  where member.team_id = team_id
    and member.status = 'active'
    and member.profile_id is not null
  on conflict do nothing;

  return new;
end;
$$;

comment on function public.levelledup_notify_team_on_entry_session_change() is
  'Trigger: fans a team notification out to current active roster members whenever an active session entry changes session.';

alter function public.levelledup_notify_team_on_entry_session_change()
  owner to postgres;

revoke all on function public.levelledup_notify_team_on_entry_session_change()
  from public, anon, authenticated;

drop trigger if exists team_entry_session_change_notify
  on public.tournament_session_entries;

create trigger team_entry_session_change_notify
  after update of session_id on public.tournament_session_entries
  for each row
  execute function public.levelledup_notify_team_on_entry_session_change();

-- ----------------------------------------------------------------------------
-- 4. Bulk move RPC: shift many entries to the next session in one call.
--    Same guards per entry as the single move (same stage only, target not
--    started, entry unused, team unassigned, room). Moves what is movable,
--    skips the rest with reasons, returns a report.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_admin_move_session_entries(
  p_entry_ids uuid[],
  p_target_session_id uuid,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_reason text := btrim(coalesce(p_reason, ''));
  target public.tournament_stage_sessions;
  entry_id uuid;
  per_entry_request_id uuid;
  hex text;
  moved_ids text[] := '{}';
  skipped jsonb := '[]'::jsonb;
begin
  perform public.levelledup_require_admin('admin');

  if p_entry_ids is null
    or cardinality(p_entry_ids) = 0
    or p_target_session_id is null
    or p_request_id is null
    or char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'Entry list, target Session, request ID and a 10-1000 character reason are required.'
      using errcode = '22023';
  end if;

  select session.* into target
  from public.tournament_stage_sessions as session
  where session.id = p_target_session_id;

  if target.id is null then
    raise exception 'Target Session not found.' using errcode = 'P4414';
  end if;

  if public.levelledup_session_has_started(target.id) then
    raise exception 'This session is already closed.' using errcode = 'P4407';
  end if;

  foreach entry_id in array p_entry_ids loop
    -- Stable per-entry request id derived from the bulk request id, so a
    -- re-run of the same bulk call is idempotent at the single-move level.
    hex := md5(p_request_id::text || ':' || entry_id::text);
    per_entry_request_id :=
      (substr(hex, 1, 8) || '-' || substr(hex, 9, 4) || '-' ||
       substr(hex, 13, 4) || '-' || substr(hex, 17, 4) || '-' ||
       substr(hex, 21, 12))::uuid;

    begin
      perform public.levelledup_admin_move_session_entry(
        entry_id,
        p_target_session_id,
        normalized_reason,
        per_entry_request_id
      );
      moved_ids := moved_ids || entry_id::text;
    exception when others then
      skipped := skipped || jsonb_build_object(
        'entry_id', entry_id::text,
        'reason', SQLERRM
      );
    end;
  end loop;

  return jsonb_build_object(
    'moved', to_jsonb(moved_ids),
    'skipped', skipped,
    'request_id', p_request_id::text
  );
end;
$$;

comment on function public.levelledup_admin_move_session_entries(uuid[], uuid, text, uuid) is
  'Admin-only bulk shift of unused session entries to another session of the SAME stage. Moves what is movable, skips the rest with reasons, returns a {moved, skipped} report.';

alter function public.levelledup_admin_move_session_entries(uuid[], uuid, text, uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_move_session_entries(uuid[], uuid, text, uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_move_session_entries(uuid[], uuid, text, uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Read RPC for the profile notification section: my team notifications.
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_get_my_team_notifications(
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller uuid := auth.uid();
  result jsonb;
begin
  if caller is null then
    raise exception 'Sign-in required.' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(payload order by created_at desc), '[]'::jsonb)
  into result
  from (
    select
      jsonb_build_object(
        'id', notification.id::text,
        'scope', 'team',
        'type', notification.type,
        'title', notification.title,
        'message', notification.message,
        'team_id', team.id::text,
        'team_name', team.name,
        'tournament_id', tournament.id::text,
        'tournament_name', tournament.name,
        'metadata', notification.metadata,
        'read', recipient.read_at is not null,
        'created_at', notification.created_at
      ) as payload,
      notification.created_at as created_at
    from public.team_notification_recipients as recipient
    join public.team_notifications as notification
      on notification.id = recipient.notification_id
    join public.teams as team
      on team.id = notification.team_id
    join public.tournaments as tournament
      on tournament.id = notification.tournament_id
    where recipient.user_id = caller
    order by notification.created_at desc
    limit greatest(coalesce(p_limit, 50), 1)
  ) as ordered;

  return result;
end;
$$;

comment on function public.levelledup_get_my_team_notifications(integer) is
  'Profile notification section: team notifications for the caller, newest first. Only notifications fanned out while the caller was an active member are visible.';

alter function public.levelledup_get_my_team_notifications(integer)
  owner to postgres;

revoke all on function public.levelledup_get_my_team_notifications(integer)
  from public, anon, authenticated;

grant execute on function public.levelledup_get_my_team_notifications(integer)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Mark read (mine only).
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_mark_team_notifications_read(
  p_notification_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller uuid := auth.uid();
  marked integer;
begin
  if caller is null then
    raise exception 'Sign-in required.' using errcode = '28000';
  end if;

  update public.team_notification_recipients as recipient
  set read_at = now()
  where recipient.user_id = caller
    and recipient.notification_id = any (p_notification_ids)
    and recipient.read_at is null;

  get diagnostics marked = row_count;
  return marked;
end;
$$;

comment on function public.levelledup_mark_team_notifications_read(uuid[]) is
  'Marks the caller''s team notifications as read. Only the caller''s own rows are touched.';

alter function public.levelledup_mark_team_notifications_read(uuid[])
  owner to postgres;

revoke all on function public.levelledup_mark_team_notifications_read(uuid[])
  from public, anon, authenticated;

grant execute on function public.levelledup_mark_team_notifications_read(uuid[])
  to authenticated;

-- ----------------------------------------------------------------------------
-- 7. Delete: one/several (mine only), or clear all (mine only).
-- ----------------------------------------------------------------------------

create or replace function public.levelledup_delete_team_notifications(
  p_notification_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller uuid := auth.uid();
  deleted_count integer;
begin
  if caller is null then
    raise exception 'Sign-in required.' using errcode = '28000';
  end if;

  delete from public.team_notification_recipients as recipient
  where recipient.user_id = caller
    and recipient.notification_id = any (p_notification_ids);

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

comment on function public.levelledup_delete_team_notifications(uuid[]) is
  'Deletes the caller''s selected team notifications. Only the caller''s own rows are removed; teammates still see theirs.';

alter function public.levelledup_delete_team_notifications(uuid[])
  owner to postgres;

revoke all on function public.levelledup_delete_team_notifications(uuid[])
  from public, anon, authenticated;

grant execute on function public.levelledup_delete_team_notifications(uuid[])
  to authenticated;

create or replace function public.levelledup_clear_team_notifications()
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller uuid := auth.uid();
  deleted_count integer;
begin
  if caller is null then
    raise exception 'Sign-in required.' using errcode = '28000';
  end if;

  delete from public.team_notification_recipients as recipient
  where recipient.user_id = caller;

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

comment on function public.levelledup_clear_team_notifications() is
  'Clears all of the caller''s team notifications. Only the caller''s own rows are removed; teammates still see theirs.';

alter function public.levelledup_clear_team_notifications()
  owner to postgres;

revoke all on function public.levelledup_clear_team_notifications()
  from public, anon, authenticated;

grant execute on function public.levelledup_clear_team_notifications()
  to authenticated;

commit;
