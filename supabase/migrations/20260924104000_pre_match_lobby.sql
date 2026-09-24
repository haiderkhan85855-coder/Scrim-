-- Pre-match lobby: temporary live chat + captain/co-captain ready check + timer.
--
-- Rule implemented (Haider-approved 2026-09-24):
--   * When an admin opens the pre-match lobby, participating teams get a
--     temporary chat and a "mark team set" control.
--   * Only the captain or co-captain of a participating team can mark their
--     own team set (toggleable until the match starts) and only they plus
--     admins can send chat messages.
--   * The match can start when every participating team is set, or when the
--     lobby timer expires (see levelledup_admin_start_match).
--   * The chat is temporary: the UI only surfaces it while the lobby is open.
--     Rows are retained afterwards for audit, never shown.

-- ---------------------------------------------------------------------------
-- 1. Ready checks: one row per participating team per match.
-- ---------------------------------------------------------------------------
create table if not exists public.match_ready_checks (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete restrict,
  tournament_match_id uuid not null references public.tournament_matches(id) on delete cascade,
  tournament_registration_id uuid not null references public.tournament_registrations(id) on delete cascade,
  marked_by uuid not null references auth.users(id) on delete set null,
  marked_at timestamptz not null default clock_timestamp(),
  constraint match_ready_checks_one_mark_per_team unique (
    tournament_match_id, tournament_registration_id
  )
);

create index if not exists match_ready_checks_match_idx
  on public.match_ready_checks (tournament_match_id);

alter table public.match_ready_checks enable row level security;

revoke all on table public.match_ready_checks
  from public, anon, authenticated;

comment on table public.match_ready_checks is
  'Pre-match ready check: the captain or co-captain marks their team set. One row per participating team per match; removed or ignored once the match starts.';

-- ---------------------------------------------------------------------------
-- 2. Lobby chat messages (temporary by UI rule, retained for audit).
-- ---------------------------------------------------------------------------
create table if not exists public.match_lobby_messages (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete restrict,
  tournament_match_id uuid not null references public.tournament_matches(id) on delete cascade,
  sender_user_id uuid not null references auth.users(id) on delete set null,
  sender_team_id uuid references public.teams(id) on delete set null,
  sender_label text not null,
  body text not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint match_lobby_messages_body_length check (
    char_length(body) between 1 and 500
  )
);

create index if not exists match_lobby_messages_match_idx
  on public.match_lobby_messages (tournament_match_id, created_at);

alter table public.match_lobby_messages enable row level security;

revoke all on table public.match_lobby_messages
  from public, anon, authenticated;

comment on table public.match_lobby_messages is
  'Temporary pre-match lobby chat. Only surfaced while the lobby is open; rows are kept afterwards for audit. Senders are admins or captains/co-captains of participating teams.';

-- ---------------------------------------------------------------------------
-- 3. Helper: the caller's participating registration for a match.
--    Returns the registration id when the caller is an active captain or
--    co-captain of a team currently assigned to the match lobby.
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_lobby_caller_registration(
  p_match_id uuid,
  p_tournament_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller uuid := auth.uid();
  found_registration_id uuid;
begin
  if caller is null then
    return null;
  end if;

  select r.id
  into found_registration_id
  from public.tournament_registrations as r
  join public.team_roster_members as mb
    on mb.team_id = r.team_id
  where r.tournament_id = p_tournament_id
    and mb.profile_id = caller
    and mb.role in ('captain', 'co_captain')
    and mb.status = 'active'
    and r.id in (
      select public.levelledup_match_active_team_ids(p_match_id)
    )
  limit 1;

  return found_registration_id;
end;
$$;

alter function public.levelledup_lobby_caller_registration(uuid, uuid)
  owner to postgres;

revoke all on function public.levelledup_lobby_caller_registration(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Mark / unmark team set (captain or co-captain, own team only).
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_mark_team_set(
  p_match_id uuid
)
returns public.match_ready_checks
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller uuid := auth.uid();
  selected_match public.tournament_matches;
  registration_id uuid;
  saved_check public.match_ready_checks;
begin
  if caller is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into selected_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id;

  if selected_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  if selected_match.status <> 'pre_match' then
    raise exception 'Teams can only be marked set while the pre-match lobby is open.'
      using errcode = '22023';
  end if;

  registration_id := public.levelledup_lobby_caller_registration(
    p_match_id, selected_match.tournament_id
  );

  if registration_id is null then
    raise exception 'Only the captain or co-captain of a participating team can mark it set.'
      using errcode = '42501';
  end if;

  insert into public.match_ready_checks (
    tournament_id, tournament_match_id, tournament_registration_id, marked_by
  ) values (
    selected_match.tournament_id, p_match_id, registration_id, caller
  )
  on conflict (tournament_match_id, tournament_registration_id)
  do update set
    marked_by = excluded.marked_by,
    marked_at = clock_timestamp()
  returning * into saved_check;

  return saved_check;
end;
$$;

alter function public.levelledup_mark_team_set(uuid)
  owner to postgres;

revoke all on function public.levelledup_mark_team_set(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_mark_team_set(uuid)
  to authenticated;

comment on function public.levelledup_mark_team_set(uuid) is
  'Captain/co-captain marks their own participating team set for the pre-match lobby. Idempotent.';

create or replace function public.levelledup_unmark_team_set(
  p_match_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller uuid := auth.uid();
  selected_match public.tournament_matches;
  registration_id uuid;
  removed integer := 0;
begin
  if caller is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into selected_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id;

  if selected_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  if selected_match.status <> 'pre_match' then
    raise exception 'Teams can only be unmarked while the pre-match lobby is open.'
      using errcode = '22023';
  end if;

  registration_id := public.levelledup_lobby_caller_registration(
    p_match_id, selected_match.tournament_id
  );

  if registration_id is null then
    raise exception 'Only the captain or co-captain of a participating team can unmark it.'
      using errcode = '42501';
  end if;

  delete from public.match_ready_checks
  where tournament_match_id = p_match_id
    and tournament_registration_id = registration_id;

  get diagnostics removed = row_count;
  return removed > 0;
end;
$$;

alter function public.levelledup_unmark_team_set(uuid)
  owner to postgres;

revoke all on function public.levelledup_unmark_team_set(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_unmark_team_set(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Temporary lobby chat: send (admins + captains/co-captains of
--    participating teams, only while the lobby is open).
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_send_lobby_message(
  p_match_id uuid,
  p_body text
)
returns public.match_lobby_messages
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller uuid := auth.uid();
  selected_match public.tournament_matches;
  normalized_body text := nullif(btrim(coalesce(p_body, '')), '');
  is_admin boolean;
  registration_id uuid;
  label text;
  team_id uuid;
  saved_message public.match_lobby_messages;
begin
  if caller is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  if normalized_body is null or char_length(normalized_body) > 500 then
    raise exception 'A message of 1 to 500 characters is required.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into selected_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id;

  if selected_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  if selected_match.status <> 'pre_match' then
    raise exception 'The lobby chat is only open while the pre-match lobby is open.'
      using errcode = '22023';
  end if;

  is_admin := public.levelledup_has_admin_role('admin');

  if is_admin then
    label := 'Admin';
    team_id := null;
  else
    registration_id := public.levelledup_lobby_caller_registration(
      p_match_id, selected_match.tournament_id
    );

    if registration_id is null then
      raise exception 'Only match admins and participating team captains can chat here.'
        using errcode = '42501';
    end if;

    select t.id, t.name
    into team_id, label
    from public.tournament_registrations as r
    join public.teams as t on t.id = r.team_id
    where r.id = registration_id;
  end if;

  insert into public.match_lobby_messages (
    tournament_id, tournament_match_id, sender_user_id,
    sender_team_id, sender_label, body
  ) values (
    selected_match.tournament_id, p_match_id, caller,
    team_id, label, normalized_body
  )
  returning * into saved_message;

  return saved_message;
end;
$$;

alter function public.levelledup_send_lobby_message(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_send_lobby_message(uuid, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_send_lobby_message(uuid, text)
  to authenticated;

comment on function public.levelledup_send_lobby_message(uuid, text) is
  'Sends a temporary pre-match lobby chat message. Admins and captains/co-captains of participating teams only, while the lobby is open.';

-- ---------------------------------------------------------------------------
-- 6. Read the lobby state: timer, teams + ready marks, recent messages.
--    Visible to admins and active members of participating teams.
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_get_pre_match_lobby(
  p_match_id uuid
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
  selected_match public.tournament_matches;
  is_admin boolean;
  can_view boolean := false;
  result jsonb;
begin
  if caller is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  if p_match_id is null then
    raise exception 'A match is required.'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into selected_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id;

  if selected_match.id is null then
    raise exception 'Match not found.'
      using errcode = 'P4203';
  end if;

  is_admin := public.levelledup_has_admin_role('admin');

  if is_admin then
    can_view := true;
  else
    select exists (
      select 1
      from public.tournament_registrations as r
      join public.team_roster_members as mb on mb.team_id = r.team_id
      where r.tournament_id = selected_match.tournament_id
        and mb.profile_id = caller
        and mb.status = 'active'
        and r.id in (
          select public.levelledup_match_active_team_ids(p_match_id)
        )
    ) into can_view;
  end if;

  if not can_view then
    raise exception 'You are not part of this match lobby.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'match_id', selected_match.id,
    'status', selected_match.status,
    'match_number', selected_match.match_number,
    'map_code', selected_match.map_code,
    'opened_at', selected_match.pre_match_opened_at,
    'timer_seconds', selected_match.pre_match_timer_seconds,
    'expires_at', selected_match.pre_match_opened_at
      + (selected_match.pre_match_timer_seconds * interval '1 second'),
    'closed_at', selected_match.pre_match_closed_at,
    'is_admin', is_admin,
    'my_registration_id', public.levelledup_lobby_caller_registration(
      p_match_id, selected_match.tournament_id
    ),
    'teams', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'registration_id', r.id,
          'team_id', t.id,
          'team_name', t.name,
          'is_set', rc.tournament_registration_id is not null,
          'marked_at', rc.marked_at
        )
        order by t.name
      )
      from public.tournament_stage_assignments as a
      join public.tournament_registrations as r on r.id = a.registration_id
      join public.teams as t on t.id = r.team_id
      left join public.match_ready_checks as rc
        on rc.tournament_match_id = p_match_id
        and rc.tournament_registration_id = r.id
      where a.lobby_id = selected_match.lobby_id
        and a.status = 'assigned'
        and a.released_at is null
    ), '[]'::jsonb),
    'messages', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', m.id,
          'sender_label', m.sender_label,
          'sender_team_id', m.sender_team_id,
          'body', m.body,
          'created_at', m.created_at
        )
        order by m.created_at
      )
      from (
        select *
        from public.match_lobby_messages
        where tournament_match_id = p_match_id
        order by created_at desc
        limit 100
      ) as m
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

alter function public.levelledup_get_pre_match_lobby(uuid)
  owner to postgres;

revoke all on function public.levelledup_get_pre_match_lobby(uuid)
  from public, anon, authenticated;

grant execute on function public.levelledup_get_pre_match_lobby(uuid)
  to authenticated;

comment on function public.levelledup_get_pre_match_lobby(uuid) is
  'Reads the pre-match lobby state: timer, participating teams with ready marks, and recent chat messages. Admins and active members of participating teams only.';

-- ---------------------------------------------------------------------------
-- 7. My open lobbies: pre-match matches where the caller is captain or
--    co-captain of a participating team. Powers the captain's lobby list.
-- ---------------------------------------------------------------------------
create or replace function public.levelledup_get_my_pre_match_lobbies()
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
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'match_id', m.id,
      'tournament_id', m.tournament_id,
      'match_number', m.match_number,
      'map_code', m.map_code,
      'lobby_id', m.lobby_id,
      'opened_at', m.pre_match_opened_at,
      'expires_at', m.pre_match_opened_at
        + (m.pre_match_timer_seconds * interval '1 second'),
      'team_name', t.name
    )
    order by m.pre_match_opened_at desc
  ), '[]'::jsonb)
  into result
  from public.tournament_matches as m
  join public.tournament_registrations as r
    on r.tournament_id = m.tournament_id
  join public.teams as t
    on t.id = r.team_id
  join public.team_roster_members as mb
    on mb.team_id = r.team_id
  where m.status = 'pre_match'
    and mb.profile_id = caller
    and mb.role in ('captain', 'co_captain')
    and mb.status = 'active'
    and r.id in (
      select public.levelledup_match_active_team_ids(m.id)
    );

  return result;
end;
$$;

alter function public.levelledup_get_my_pre_match_lobbies()
  owner to postgres;

revoke all on function public.levelledup_get_my_pre_match_lobbies()
  from public, anon, authenticated;

grant execute on function public.levelledup_get_my_pre_match_lobbies()
  to authenticated;

comment on function public.levelledup_get_my_pre_match_lobbies() is
  'Pre-match matches where the caller is captain/co-captain of a participating team. Powers the captain lobby list.';
