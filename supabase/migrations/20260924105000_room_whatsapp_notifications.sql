-- ============================================================================
-- Scrims — match room credentials, tournament WhatsApp link, team notifications
-- Decided 2026-09-24 with Haider:
--   * "An admin field for an outside WhatsApp tournament group link. A team
--     gets the link only after Haider confirms its payment/entry."
--   * "Room ID and password per match. Admin-only entry. Explicit Publish
--     control to prevent early leakage. Eligible teams receive an in-system
--     notification such as: 'Room details for Match 3 are live.'"
--   * "A paid entry covers exactly one session only." — WhatsApp eligibility
--     is a CONFIRMED registration (Haider confirmed the payment/entry).
-- System is the source of truth; WhatsApp stays the real-time channel.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tournament WhatsApp group link (admin-managed).
-- ---------------------------------------------------------------------------

alter table public.tournaments
  add column if not exists whatsapp_group_link text;

comment on column public.tournaments.whatsapp_group_link is
  'Outside WhatsApp tournament group invite link. Admin-only editing. Visible to a team only after Haider confirms its payment/entry (confirmed registration).';

-- ---------------------------------------------------------------------------
-- 2. Per-match room credentials with an explicit publish gate.
--    Draft values are admin-only. Teams see them only after publish.
-- ---------------------------------------------------------------------------

alter table public.tournament_matches
  add column if not exists room_id text,
  add column if not exists room_password text,
  add column if not exists room_published_at timestamptz,
  add column if not exists room_published_by uuid
    references auth.users (id) on delete set null;

comment on column public.tournament_matches.room_id is
  'Draft room ID (admin-only) until room_published_at is set.';
comment on column public.tournament_matches.room_password is
  'Draft room password (admin-only) until room_published_at is set.';
comment on column public.tournament_matches.room_published_at is
  'Set by the explicit Publish control. Teams can only read room credentials after this is set.';
comment on column public.tournament_matches.room_published_by is
  'Admin who published the room credentials.';

-- ---------------------------------------------------------------------------
-- 3. Team notifications inbox (in-system; WhatsApp stays the realtime channel).
-- ---------------------------------------------------------------------------

create table if not exists public.team_notifications (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null
    references public.teams (id) on delete cascade,
  kind text not null default 'general',
  title text not null,
  body text,
  link text,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint team_notifications_kind_valid check (
    kind in ('general', 'room_live', 'room_updated', 'lobby_open', 'whatsapp')
  ),
  constraint team_notifications_title_valid check (
    char_length(btrim(title)) between 1 and 120
  )
);

comment on table public.team_notifications is
  'In-system inbox for teams (captains/co-captains/members). All writes go through SECURITY DEFINER RPCs.';

create index if not exists team_notifications_team_created_idx
  on public.team_notifications (team_id, created_at desc);

alter table public.team_notifications enable row level security;

-- ---------------------------------------------------------------------------
-- 4. Internal helper: notify every participating team that room details
--    are live (or were updated after publishing).
-- ---------------------------------------------------------------------------

create or replace function public._levelledup_notify_room_live(
  p_match_id uuid,
  p_updated boolean
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  match_number integer;
  notified integer := 0;
  team_rec record;
begin
  select m.match_number
  into match_number
  from public.tournament_matches as m
  where m.id = p_match_id;

  for team_rec in
    select distinct r.team_id as team_id
    from public.tournament_registrations as r
    where r.id in (
      select public.levelledup_match_active_team_ids(p_match_id)
    )
  loop
    insert into public.team_notifications (
      team_id, kind, title, body, link
    ) values (
      team_rec.team_id,
      case when p_updated then 'room_updated' else 'room_live' end,
      case when p_updated
        then 'Room details updated for Match ' || match_number
        else 'Room details for Match ' || match_number || ' are live'
      end,
      case when p_updated
        then 'The room ID/password for Match ' || match_number || ' changed. Check the lobby page for the latest details.'
        else 'The room ID and password for Match ' || match_number || ' are now available. Open the lobby page to join.'
      end,
      '/lobby/' || p_match_id::text
    );
    notified := notified + 1;
  end loop;

  return notified;
end;
$$;

alter function public._levelledup_notify_room_live(uuid, boolean)
  owner to postgres;

revoke all on function public._levelledup_notify_room_live(uuid, boolean)
  from public, anon, authenticated;

comment on function public._levelledup_notify_room_live(uuid, boolean) is
  'Internal: fan out a room-live / room-updated notification to every team actively participating in the match.';

-- ---------------------------------------------------------------------------
-- 5. Admin: set the tournament WhatsApp group link.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_admin_set_whatsapp_link(
  p_tournament_id uuid,
  p_link text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned text := nullif(btrim(coalesce(p_link, '')), '');
  updated_count integer := 0;
begin
  perform public.levelledup_require_admin('admin');

  if cleaned is not null
    and position('chat.whatsapp.com/' in lower(cleaned)) = 0 then
    raise exception 'That does not look like a WhatsApp group invite link.'
      using errcode = '22023';
  end if;

  update public.tournaments as t
  set whatsapp_group_link = cleaned
  where t.id = p_tournament_id;

  get diagnostics updated_count = row_count;
  if updated_count = 0 then
    raise exception 'Tournament not found.'
      using errcode = 'P0002';
  end if;

  return cleaned;
end;
$$;

alter function public.levelledup_admin_set_whatsapp_link(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_admin_set_whatsapp_link(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_set_whatsapp_link(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_set_whatsapp_link(uuid, text) is
  'Admin-only: set or clear the tournament WhatsApp group invite link. Empty clears it.';

-- ---------------------------------------------------------------------------
-- 6. Admin: save draft room credentials (does NOT publish them).
--    Editing after publish refreshes the publish timestamp and re-notifies.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_admin_set_room_credentials(
  p_match_id uuid,
  p_room_id text,
  p_room_password text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned_id text := nullif(btrim(coalesce(p_room_id, '')), '');
  cleaned_pw text := nullif(btrim(coalesce(p_room_password, '')), '');
  was_published boolean;
  updated_count integer := 0;
begin
  perform public.levelledup_require_admin('admin');

  if (cleaned_id is null) <> (cleaned_pw is null) then
    raise exception 'Room ID and password must be set together, or both cleared.'
      using errcode = '22023';
  end if;

  select m.room_published_at is not null
  into was_published
  from public.tournament_matches as m
  where m.id = p_match_id;
  if not found then
    raise exception 'Match not found.'
      using errcode = 'P0002';
  end if;

  update public.tournament_matches as m
  set room_id = cleaned_id,
      room_password = cleaned_pw,
      room_published_at = case
        when cleaned_id is not null and was_published then now()
        else m.room_published_at
      end,
      room_published_by = case
        when cleaned_id is not null and was_published then auth.uid()
        else m.room_published_by
      end
  where m.id = p_match_id;

  get diagnostics updated_count = row_count;
  if updated_count = 0 then
    raise exception 'Match not found.'
      using errcode = 'P0002';
  end if;

  if cleaned_id is not null and was_published then
    perform public._levelledup_notify_room_live(p_match_id, true);
  end if;

  return true;
end;
$$;

alter function public.levelledup_admin_set_room_credentials(uuid, text, text)
  owner to postgres;

revoke all on function public.levelledup_admin_set_room_credentials(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_set_room_credentials(uuid, text, text)
  to authenticated;

comment on function public.levelledup_admin_set_room_credentials(uuid, text, text) is
  'Admin-only: save draft room credentials without publishing. Editing after publish re-publishes and notifies teams of the update.';

-- ---------------------------------------------------------------------------
-- 7. Admin: publish room credentials (explicit control — no early leakage).
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_admin_publish_room(
  p_match_id uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  has_credentials boolean;
  updated_count integer := 0;
  notified integer := 0;
begin
  perform public.levelledup_require_admin('admin');

  select m.room_id is not null and m.room_password is not null
  into has_credentials
  from public.tournament_matches as m
  where m.id = p_match_id;
  if not found then
    raise exception 'Match not found.'
      using errcode = 'P0002';
  end if;
  if not has_credentials then
    raise exception 'Set the room ID and password before publishing.'
      using errcode = '22023';
  end if;

  update public.tournament_matches as m
  set room_published_at = now(),
      room_published_by = auth.uid()
  where m.id = p_match_id;

  get diagnostics updated_count = row_count;
  if updated_count = 0 then
    raise exception 'Match not found.'
      using errcode = 'P0002';
  end if;

  notified := public._levelledup_notify_room_live(p_match_id, false);
  return notified;
end;
$$;

alter function public.levelledup_admin_publish_room(uuid)
  owner to postgres;

revoke all on function public.levelledup_admin_publish_room(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_publish_room(uuid)
  to authenticated;

comment on function public.levelledup_admin_publish_room(uuid) is
  'Admin-only: explicitly publish room credentials to participating teams and notify them. Returns the number of teams notified.';

-- ---------------------------------------------------------------------------
-- 8. Team: read the WhatsApp link — only with a CONFIRMED registration
--    (Haider confirmed the payment/entry). Any active roster member.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_get_my_whatsapp_links()
returns table (
  tournament_id uuid,
  tournament_name text,
  whatsapp_group_link text
)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct
    t.id,
    t.name,
    t.whatsapp_group_link
  from public.tournaments as t
  join public.tournament_registrations as r
    on r.tournament_id = t.id
  join public.team_roster_members as mb
    on mb.team_id = r.team_id
  where mb.profile_id = auth.uid()
    and mb.status = 'active'
    and r.status = 'confirmed'
    and t.whatsapp_group_link is not null
  order by t.name
$$;

alter function public.levelledup_get_my_whatsapp_links()
  owner to postgres;

revoke all on function public.levelledup_get_my_whatsapp_links()
  from public, anon, authenticated;
grant execute on function public.levelledup_get_my_whatsapp_links()
  to authenticated;

comment on function public.levelledup_get_my_whatsapp_links() is
  'Teams with a confirmed registration (payment/entry confirmed by Haider) can read the tournament WhatsApp group link.';

-- ---------------------------------------------------------------------------
-- 9. Team: read room credentials — only after publish, only participants.
--    Admins can always read (to verify what teams will see).
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_get_match_room(
  p_match_id uuid
)
returns table (
  room_id text,
  room_password text,
  published_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller uuid := auth.uid();
  is_admin boolean := false;
  is_participant boolean := false;
  published timestamptz;
begin
  if caller is null then
    raise exception 'Sign in to view room details.'
      using errcode = '28000';
  end if;

  begin
    perform public.levelledup_require_admin('admin');
    is_admin := true;
  exception when others then
    is_admin := false;
  end;

  select m.room_published_at
  into published
  from public.tournament_matches as m
  where m.id = p_match_id;
  if not found then
    raise exception 'Match not found.'
      using errcode = 'P0002';
  end if;

  if not is_admin then
    if published is null then
      raise exception 'Room details have not been published yet.'
        using errcode = 'P0002';
    end if;

    select exists (
      select 1
      from public.tournament_registrations as r
      join public.team_roster_members as mb
        on mb.team_id = r.team_id
      where mb.profile_id = caller
        and mb.status = 'active'
        and r.id in (
          select public.levelledup_match_active_team_ids(p_match_id)
        )
    ) into is_participant;

    if not is_participant then
      raise exception 'Room details have not been published yet.'
        using errcode = 'P0002';
    end if;
  end if;

  return query
  select m.room_id, m.room_password, m.room_published_at
  from public.tournament_matches as m
  where m.id = p_match_id;
end;
$$;

alter function public.levelledup_get_match_room(uuid)
  owner to postgres;

revoke all on function public.levelledup_get_match_room(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_get_match_room(uuid)
  to authenticated;

comment on function public.levelledup_get_match_room(uuid) is
  'Room credentials are visible only after the explicit Publish control, and only to teams actively participating in the match. Admins can always read.';

-- ---------------------------------------------------------------------------
-- 10. Team: notification inbox (any active roster member of the team).
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_list_my_team_notifications()
returns table (
  id uuid,
  team_id uuid,
  team_name text,
  kind text,
  title text,
  body text,
  link text,
  created_at timestamptz,
  read_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    n.id,
    n.team_id,
    t.name,
    n.kind,
    n.title,
    n.body,
    n.link,
    n.created_at,
    n.read_at
  from public.team_notifications as n
  join public.teams as t
    on t.id = n.team_id
  where n.team_id in (
    select mb.team_id
    from public.team_roster_members as mb
    where mb.profile_id = auth.uid()
      and mb.status = 'active'
  )
  order by n.created_at desc
  limit 50
$$;

alter function public.levelledup_list_my_team_notifications()
  owner to postgres;

revoke all on function public.levelledup_list_my_team_notifications()
  from public, anon, authenticated;
grant execute on function public.levelledup_list_my_team_notifications()
  to authenticated;

comment on function public.levelledup_list_my_team_notifications() is
  'In-system inbox for the caller teams (newest first, 50 max).';

create or replace function public.levelledup_mark_notification_read(
  p_notification_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Sign in required.'
      using errcode = '28000';
  end if;

  update public.team_notifications as n
  set read_at = now()
  where n.id = p_notification_id
    and n.read_at is null
    and n.team_id in (
      select mb.team_id
      from public.team_roster_members as mb
      where mb.profile_id = auth.uid()
        and mb.status = 'active'
    );

  get diagnostics updated_count = row_count;
  return updated_count > 0;
end;
$$;

alter function public.levelledup_mark_notification_read(uuid)
  owner to postgres;

revoke all on function public.levelledup_mark_notification_read(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_mark_notification_read(uuid)
  to authenticated;

comment on function public.levelledup_mark_notification_read(uuid) is
  'Mark one of the caller team notifications as read. Shared per team.';

commit;
