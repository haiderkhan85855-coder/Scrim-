-- ============================================================================
-- 20260924170000_permanent_cancellation.sql
--
-- Permanent cancellation, credit, kill switch, match recreate, pause/resume.
--
-- Handoff rule: "LevelledUp cancellation should refund/credit unused eligible
-- entries. A paid entry becomes consumed irreversibly when its first
-- applicable Match becomes live."
--
-- Locked product rules (Haider):
--   1. Cancel & Recreate (rebuild): NO credit. Teams migrate to the new
--      tournament, money stays in play as team credit in the new tournament.
--   2. Permanent cancellation (no continuation): UNUSED paid entries become
--      credit on the TEAM. Played entries (failed OR won/advanced) are
--      consumed: nothing back. Free/earned entries just end (no money in them).
--   3. "Unused" = the team's match never went live. Consumed = assigned team
--      + live/completed match (same definition as the 150000 entry lock).
--   4. Kill switch = permanent cancellation, SUPER ADMIN ONLY, four UI steps
--      (confirm -> type tournament ID -> confirm -> captcha-style check).
--      The database verifies the typed ID and the caller. Cannot be undone.
--   5. Matches CANNOT be cancelled. A broken match is RECREATED: a fresh match
--      in the same lobby, teams shift to it, every lobby player is notified
--      with a custom admin message.
--   6. Pause button: freezing a tournament blocks registrations, payments,
--      lobby creation, match changes and new entries until resumed. Everyone
--      in the tournament sees the admin's message (custom, with a generic
--      default).
--   7. A player who leaves a team gets their own money back without asking
--      the admin (principle locked here; exact math lands in 200000).
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Pause + kill-switch columns on tournaments
-- ----------------------------------------------------------------------------
alter table public.tournaments
  add column if not exists paused_at timestamptz,
  add column if not exists paused_reason text,
  add column if not exists paused_by uuid
    references auth.users (id) on delete restrict,
  add column if not exists kill_switched_at timestamptz;

comment on column public.tournaments.paused_at is
  'When the tournament was paused. Null = running. While set, money/match/entry writes are frozen.';
comment on column public.tournaments.paused_reason is
  'Admin-written message shown to every player while the tournament is paused.';
comment on column public.tournaments.kill_switched_at is
  'When the super-admin kill switch permanently cancelled this tournament. Never cleared.';

-- ----------------------------------------------------------------------------
-- 2. Pause freeze enforcement.
--
-- A single row trigger on the five write-heavy tables refuses writes while
-- the tournament is paused. Privileged internal flows (pause/resume itself,
-- permanent cancellation, kill switch, migrate, match recreate) opt out with
-- a transaction-local bypass flag, so the freeze can never deadlock admin
-- recovery. The flag dies with the transaction: connection-pool safe.
-- ----------------------------------------------------------------------------
create or replace function public.levelledup_guard_tournament_pause()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_tournament_id uuid;
  tournament_is_paused boolean;
begin
  if current_setting('levelledup.paused_write_bypass', true) = 'on' then
    return case when TG_OP = 'DELETE' then old else new end;
  end if;

  -- Every guarded table carries tournament_id.
  target_tournament_id :=
    case when TG_OP = 'DELETE' then old.tournament_id else new.tournament_id end;

  select (tournament.paused_at is not null)
  into tournament_is_paused
  from public.tournaments as tournament
  where tournament.id = target_tournament_id;

  if coalesce(tournament_is_paused, false) then
    raise exception 'This tournament is paused. Resume it before making changes.'
      using errcode = 'P4408';
  end if;

  return case when TG_OP = 'DELETE' then old else new end;
end;
$$;

comment on function public.levelledup_guard_tournament_pause() is
  'Row trigger: refuses writes to a paused tournament unless the transaction set the paused_write_bypass flag.';

alter function public.levelledup_guard_tournament_pause() owner to postgres;
revoke all on function public.levelledup_guard_tournament_pause()
  from public, anon, authenticated;

drop trigger if exists tournament_registrations_pause_guard
  on public.tournament_registrations;
create trigger tournament_registrations_pause_guard
  before insert on public.tournament_registrations
  for each row execute function public.levelledup_guard_tournament_pause();

drop trigger if exists tournament_registration_payments_pause_guard
  on public.tournament_registration_payments;
create trigger tournament_registration_payments_pause_guard
  before insert or update on public.tournament_registration_payments
  for each row execute function public.levelledup_guard_tournament_pause();

drop trigger if exists tournament_lobbies_pause_guard
  on public.tournament_lobbies;
create trigger tournament_lobbies_pause_guard
  before insert on public.tournament_lobbies
  for each row execute function public.levelledup_guard_tournament_pause();

drop trigger if exists tournament_matches_pause_guard
  on public.tournament_matches;
create trigger tournament_matches_pause_guard
  before insert or update on public.tournament_matches
  for each row execute function public.levelledup_guard_tournament_pause();

drop trigger if exists tournament_session_entries_pause_guard
  on public.tournament_session_entries;
create trigger tournament_session_entries_pause_guard
  before insert on public.tournament_session_entries
  for each row execute function public.levelledup_guard_tournament_pause();

-- ----------------------------------------------------------------------------
-- 3. Tournament-wide team notification helper.
--    Same fan-out pattern as the 140000 entry-shift notifications: every
--    registered team gets a notification, delivered to current active roster
--    members only. Read/deletion state stays personal.
-- ----------------------------------------------------------------------------
create or replace function public.levelledup_notify_tournament_teams(
  p_tournament_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_metadata jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  team_rec record;
  notification_id uuid;
  sent_count integer := 0;
begin
  if p_tournament_id is null then
    raise exception 'A tournament is required.' using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(p_type, '')), '') is null
    or nullif(btrim(coalesce(p_title, '')), '') is null
    or nullif(btrim(coalesce(p_message, '')), '') is null then
    raise exception 'Notification type, title and message are required.'
      using errcode = '22023';
  end if;

  for team_rec in
    select distinct registration.team_id
    from public.tournament_registrations as registration
    where registration.tournament_id = p_tournament_id
      and registration.status in ('pending', 'confirmed')
    order by registration.team_id
  loop
    insert into public.team_notifications
      (team_id, tournament_id, type, title, message, metadata)
    values (
      team_rec.team_id, p_tournament_id,
      btrim(p_type), btrim(p_title), btrim(p_message),
      coalesce(p_metadata, '{}'::jsonb)
    )
    returning id into notification_id;

    insert into public.team_notification_recipients (notification_id, user_id)
    select notification_id, member.profile_id
    from public.team_roster_members as member
    where member.team_id = team_rec.team_id
      and member.status = 'active'
      and member.profile_id is not null
    on conflict do nothing;

    sent_count := sent_count + 1;
  end loop;

  return sent_count;
end;
$$;

comment on function public.levelledup_notify_tournament_teams(uuid, text, text, text, jsonb) is
  'Sends one notification per registered team, fanned out to current active roster members only.';

alter function public.levelledup_notify_tournament_teams(uuid, text, text, text, jsonb)
  owner to postgres;
revoke all on function public.levelledup_notify_tournament_teams(uuid, text, text, text, jsonb)
  from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. Pause / resume.
-- ----------------------------------------------------------------------------
create or replace function public.levelledup_pause_tournament(
  p_tournament_id uuid,
  p_message text
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  selected_tournament public.tournaments;
  pause_message text :=
    nullif(btrim(coalesce(p_message, '')), '');
begin
  perform public.levelledup_require_admin('admin');

  select tournament.*
  into selected_tournament
  from public.tournaments as tournament
  where tournament.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.' using errcode = 'P4301';
  end if;

  if selected_tournament.status in ('cancelled', 'completed') then
    raise exception 'A finished tournament cannot be paused.'
      using errcode = 'P4303';
  end if;

  if selected_tournament.paused_at is not null then
    raise exception 'This tournament is already paused.'
      using errcode = '22023';
  end if;

  if pause_message is null then
    pause_message :=
      'This tournament is paused due to technical issues. Please wait for further updates.';
  elsif char_length(pause_message) > 500 then
    raise exception 'Pause message must be 500 characters or fewer.'
      using errcode = '22023';
  end if;

  update public.tournaments
  set paused_at = now(),
      paused_reason = pause_message,
      paused_by = actor_user_id
  where id = selected_tournament.id
  returning * into selected_tournament;

  perform public.levelledup_notify_tournament_teams(
    selected_tournament.id,
    'tournament_paused',
    'Tournament paused',
    pause_message,
    jsonb_build_object('paused_by', actor_user_id::text)
  );

  return selected_tournament;
end;
$$;

comment on function public.levelledup_pause_tournament(uuid, text) is
  'Freezes a tournament: registrations, payments, lobbies, matches and new entries are refused until resumed. Every team is notified with the admin message.';

alter function public.levelledup_pause_tournament(uuid, text) owner to postgres;
revoke all on function public.levelledup_pause_tournament(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_pause_tournament(uuid, text)
  to authenticated;

create or replace function public.levelledup_resume_tournament(
  p_tournament_id uuid
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  selected_tournament public.tournaments;
begin
  perform public.levelledup_require_admin('admin');

  select tournament.*
  into selected_tournament
  from public.tournaments as tournament
  where tournament.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.' using errcode = 'P4301';
  end if;

  if selected_tournament.paused_at is null then
    raise exception 'This tournament is not paused.'
      using errcode = '22023';
  end if;

  update public.tournaments
  set paused_at = null,
      paused_reason = null,
      paused_by = null
  where id = selected_tournament.id
  returning * into selected_tournament;

  perform public.levelledup_notify_tournament_teams(
    selected_tournament.id,
    'tournament_resumed',
    'Tournament resumed',
    'The tournament is running again. Check your sessions and matches.',
    jsonb_build_object('resumed_by', actor_user_id::text)
  );

  return selected_tournament;
end;
$$;

comment on function public.levelledup_resume_tournament(uuid) is
  'Unfreezes a paused tournament and notifies every team.';

alter function public.levelledup_resume_tournament(uuid) owner to postgres;
revoke all on function public.levelledup_resume_tournament(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_resume_tournament(uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Cancel unused session entries, SKIPPING consumed ones.
--
-- The existing levelledup_cancel_unused_registration_session_entries() raises
-- the moment it meets a consumed entry, which is right for withdrawals but
-- wrong for whole-tournament cancellation: one played entry must not block
-- crediting every other unused entry. This variant leaves consumed entries
-- (and their history) untouched and cancels everything else, including free
-- earned entries (they carry no money, so they produce no credit).
-- ----------------------------------------------------------------------------
create or replace function public.levelledup_cancel_unused_session_entries_skip_consumed(
  p_registration_id uuid,
  p_actor_user_id uuid,
  p_reason text
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  session_entry public.tournament_session_entries;
  source_paid_entry public.tournament_registration_paid_entries;
  cancelled_count integer := 0;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  decision_at timestamptz := clock_timestamp();
begin
  if p_actor_user_id is null then
    raise exception 'A trusted Session Entry cancellation actor is required.'
      using errcode = '42501';
  end if;

  if char_length(normalized_reason) not between 10 and 500 then
    raise exception 'Provide a Session Entry cancellation reason between 10 and 500 characters.'
      using errcode = '22023';
  end if;

  select current_registration.*
  into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4013';
  end if;

  for session_entry in
    select entry.*
    from public.tournament_session_entries as entry
    where entry.registration_id = registration.id
      and entry.status = 'active'
      and entry.source_type in ('paid', 'registration', 'earned')
    order by entry.created_at, entry.id
    for update
  loop
    source_paid_entry := null;

    if session_entry.source_type = 'paid' then
      select paid_entry.*
      into source_paid_entry
      from public.tournament_registration_paid_entries as paid_entry
      where paid_entry.id = session_entry.source_paid_entry_id
      for update;

      if source_paid_entry.id is null
        or source_paid_entry.registration_id <> registration.id
        or source_paid_entry.session_id <> session_entry.session_id then
        raise exception 'Paid Session Entry source history is inconsistent.'
          using errcode = '23503';
      end if;

      -- Already processed or consumed value: leave it as history, skip it.
      if source_paid_entry.status <> 'paid' then
        continue;
      end if;
    elsif session_entry.source_type = 'registration'
      and session_entry.source_provenance ->> 'entitlement'
        is distinct from 'initial_registration_confirmation' then
      -- Not the preserved initial entitlement: leave it alone.
      continue;
    end if;
    -- 'earned' entries: free, no money. They are cancelled below for tidiness
    -- but never produce credit.

    -- Consumed = the team was assigned and a match in that lobby went
    -- live/completed. Consumed participation stays as history: skip it.
    if exists (
      select 1
      from public.tournament_stage_assignments as assignment
      join public.tournament_matches as match
        on match.lobby_id = assignment.lobby_id
       and match.stage_id = assignment.stage_id
       and match.tournament_id = assignment.tournament_id
      where assignment.session_entry_id = session_entry.id
        and match.status in ('live', 'completed')
    ) then
      continue;
    end if;

    update public.tournament_stage_assignments
    set status = 'released', released_at = decision_at
    where session_entry_id = session_entry.id
      and status = 'assigned';

    update public.tournament_session_entries
    set
      status = 'cancelled',
      cancelled_by = p_actor_user_id,
      cancelled_at = decision_at,
      cancellation_reason = normalized_reason,
      cancellation_request_id = gen_random_uuid()
    where id = session_entry.id;

    cancelled_count := cancelled_count + 1;
  end loop;

  return cancelled_count;
end;
$$;

comment on function public.levelledup_cancel_unused_session_entries_skip_consumed(uuid, uuid, text) is
  'Cancels unused active session entries (paid, registration, earned), leaving consumed entries as history. Used by whole-tournament cancellation and migrate.';

alter function public.levelledup_cancel_unused_session_entries_skip_consumed(uuid, uuid, text)
  owner to postgres;
revoke all on function public.levelledup_cancel_unused_session_entries_skip_consumed(uuid, uuid, text)
  from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 6. Permanent cancellation, rewritten.
--
-- The old version REFUSED to cancel a tournament once it had begun. The new
-- version allows cancelling at any point before completion, but only UNUSED
-- value is credited, and it lands on the TEAM (tournament_team_credits for
-- the registration fee, tournament_stage_credit_entitlements for session
-- fees). Consumed entries (played-and-failed, played-and-won) are history:
-- nothing back. Free/earned entries simply end.
-- ----------------------------------------------------------------------------
create or replace function public.levelledup_admin_cancel_tournament_with_credits(
  p_tournament_id uuid
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_admin_id uuid := auth.uid();
  selected_tournament public.tournaments;
  registration record;
  session_payment record;
begin
  perform public.levelledup_require_admin('admin');
  perform set_config('levelledup.paused_write_bypass', 'on', true);

  select tournament.*
  into selected_tournament
  from public.tournaments as tournament
  where tournament.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.' using errcode = 'P4301';
  end if;

  if selected_tournament.status in ('cancelled', 'completed') then
    raise exception 'This tournament is already finished and cannot be cancelled.'
      using errcode = 'P4303';
  end if;

  if selected_tournament.status not in (
    'draft', 'registration_open', 'registration_closed', 'live'
  ) then
    raise exception 'This tournament cannot be cancelled in its current state.'
      using errcode = 'P4303';
  end if;

  -- A begun tournament CAN now be cancelled. Only unused value is credited;
  -- consumed entries stay as history. Nothing below depends on the
  -- tournament being unstarted.

  perform 1 from public.tournament_registrations as current_registration
  where current_registration.tournament_id = selected_tournament.id
  for update;
  perform 1 from public.tournament_registration_payments as payment
  where payment.tournament_id = selected_tournament.id
  for update;

  -- Only true Session-attempt payments enter the Session refund path. Initial
  -- Tournament payments retain their selected Session identity but are not
  -- converted into an exact-price paid Session allocation.
  for session_payment in
    select payment.id as payment_id, payment.registration_id,
      session.stage_id, session.id as session_id
    from public.tournament_registration_payments as payment
    join public.tournament_registrations as current_registration
      on current_registration.id = payment.registration_id
     and current_registration.tournament_id = payment.tournament_id
     and current_registration.team_id = payment.team_id
    join public.tournament_stage_sessions as session
      on session.id = payment.session_id
     and session.tournament_id = payment.tournament_id
    where payment.tournament_id = selected_tournament.id
      and payment.status = 'verified'
      and payment.session_id is not null
      and not (
        current_registration.initial_session_id = payment.session_id
        and payment.expected_amount_minor::bigint = selected_tournament.entry_fee_minor
        and payment.currency = selected_tournament.currency
      )
    order by payment.submitted_at, payment.id
  loop
    perform public.levelledup_admin_create_stage_paid_entry(
      session_payment.registration_id, session_payment.stage_id, 'session',
      session_payment.payment_id, session_payment.session_id, null
    );
  end loop;

  for registration in
    select current_registration.id
    from public.tournament_registrations as current_registration
    where current_registration.tournament_id = selected_tournament.id
    order by current_registration.created_at, current_registration.id
  loop
    -- Cancels unused entries; consumed ones are skipped and kept as history.
    perform public.levelledup_cancel_unused_session_entries_skip_consumed(
      registration.id, authenticated_admin_id,
      'Tournament cancelled; unused Session participation cancelled'
    );
    -- Credits unused paid entries; consumed paid entries are skipped inside.
    perform public.levelledup_credit_unused_registration_paid_entries(
      registration.id, authenticated_admin_id,
      'Tournament cancelled; unused Session payment credited', true
    );
  end loop;

  update public.tournaments set status = 'cancelled'
  where id = selected_tournament.id
  returning * into selected_tournament;

  -- Registration-fee credit, but ONLY for teams that never participated.
  -- A team that played anything (any live/completed match on its entries)
  -- has consumed its registration: nothing back.
  insert into public.tournament_team_credits (
    tournament_id, registration_id, team_id, source_payment_id,
    source_reference_id, amount_minor, currency, status,
    created_by, status_updated_by
  )
  select selected_tournament.id, current_registration.id,
    current_registration.team_id, payment.id, payment.reference_id,
    selected_tournament.entry_fee_minor, selected_tournament.currency,
    'available', authenticated_admin_id, authenticated_admin_id
  from public.tournament_registrations as current_registration
  join public.tournament_registration_payments as payment
    on payment.registration_id = current_registration.id
   and payment.tournament_id = current_registration.tournament_id
   and payment.team_id = current_registration.team_id
   and payment.status = 'verified'
  where current_registration.tournament_id = selected_tournament.id
    and selected_tournament.entry_fee_minor > 0
    and (
      payment.session_id is null
      or (
        current_registration.initial_session_id = payment.session_id
        and payment.expected_amount_minor::bigint = selected_tournament.entry_fee_minor
        and payment.currency = selected_tournament.currency
      )
    )
    and not exists (
      select 1
      from public.tournament_session_entries as entry
      join public.tournament_stage_assignments as assignment
        on assignment.session_entry_id = entry.id
      join public.tournament_matches as match
        on match.lobby_id = assignment.lobby_id
       and match.stage_id = assignment.stage_id
       and match.tournament_id = assignment.tournament_id
      where entry.registration_id = current_registration.id
        and match.status in ('live', 'completed')
    )
  on conflict (registration_id) do nothing;

  perform public.levelledup_notify_tournament_teams(
    selected_tournament.id,
    'tournament_cancelled',
    'Tournament cancelled',
    'This tournament was permanently cancelled. Unused payments were credited to your team balance. Played entries are consumed and are not credited.',
    jsonb_build_object('cancelled_by', authenticated_admin_id::text)
  );

  return selected_tournament;
end;
$$;

comment on function public.levelledup_admin_cancel_tournament_with_credits(uuid) is
  'Permanent cancellation, allowed even mid-tournament. Credits UNUSED paid value to the team; consumed entries (played) get nothing. Free/earned entries end with no credit.';

-- Grants persist across CREATE OR REPLACE; re-assert for safety.
alter function public.levelledup_admin_cancel_tournament_with_credits(uuid)
  owner to postgres;
revoke all on function public.levelledup_admin_cancel_tournament_with_credits(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_cancel_tournament_with_credits(uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 7. Kill switch: super-admin-only permanent cancellation.
--
-- The app walks Haider through four steps (confirm -> type the tournament ID
-- -> confirm again -> captcha-style check) and then calls this with the typed
-- text. The database re-verifies the typed ID matches and the caller is the
-- super admin before doing anything.
-- ----------------------------------------------------------------------------
create or replace function public.levelledup_kill_tournament(
  p_tournament_id uuid,
  p_typed_confirmation text
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  selected_tournament public.tournaments;
  typed_text text := nullif(btrim(coalesce(p_typed_confirmation, '')), '');
begin
  perform public.levelledup_require_admin('super_admin');

  if typed_text is null then
    raise exception 'Type the tournament ID to confirm the kill switch.'
      using errcode = '22023';
  end if;

  if typed_text <> p_tournament_id::text then
    raise exception 'Confirmation does not match the tournament ID. Kill switch aborted.'
      using errcode = '22023';
  end if;

  select tournament.*
  into selected_tournament
  from public.tournaments as tournament
  where tournament.id = p_tournament_id;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.' using errcode = 'P4301';
  end if;

  if selected_tournament.status in ('cancelled', 'completed') then
    raise exception 'This tournament is already finished.'
      using errcode = 'P4303';
  end if;

  perform set_config('levelledup.paused_write_bypass', 'on', true);

  perform public.levelledup_admin_cancel_tournament_with_credits(p_tournament_id);

  update public.tournaments
  set kill_switched_at = now()
  where id = p_tournament_id
  returning * into selected_tournament;

  return selected_tournament;
end;
$$;

comment on function public.levelledup_kill_tournament(uuid, text) is
  'SUPER ADMIN ONLY. Permanent tournament cancellation after typed-ID confirmation. Cannot be undone.';

alter function public.levelledup_kill_tournament(uuid, text) owner to postgres;
revoke all on function public.levelledup_kill_tournament(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_kill_tournament(uuid, text)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 8. A cancelled tournament can never be reopened. The kill switch and
--    permanent cancellation are one-way doors.
-- ----------------------------------------------------------------------------
create or replace function public.levelledup_guard_terminal_tournament_status()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if old.status = 'cancelled'
    and new.status is distinct from old.status then
    raise exception 'A cancelled tournament cannot be reopened.'
      using errcode = 'P4303';
  end if;
  return new;
end;
$$;

comment on function public.levelledup_guard_terminal_tournament_status() is
  'Cancelled is terminal: no update may move a tournament out of cancelled status.';

alter function public.levelledup_guard_terminal_tournament_status()
  owner to postgres;
revoke all on function public.levelledup_guard_terminal_tournament_status()
  from public, anon, authenticated;

drop trigger if exists tournaments_terminal_status_guard
  on public.tournaments;
create trigger tournaments_terminal_status_guard
  before update on public.tournaments
  for each row execute function public.levelledup_guard_terminal_tournament_status();

-- ----------------------------------------------------------------------------
-- 9. Matches cannot be cancelled anymore. The old cancel RPC now refuses with
--    a clear message pointing at the recreate path.
-- ----------------------------------------------------------------------------
create or replace function public.levelledup_admin_cancel_match(
  p_match_id uuid,
  p_reason text
)
returns public.tournament_matches
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');
  raise exception 'Matches cannot be cancelled. Recreate the match instead: the teams shift to the new match and every player is notified.'
    using errcode = 'P4409';
  return null;
end;
$$;

comment on function public.levelledup_admin_cancel_match(uuid, text) is
  'DISABLED by product rule: matches are never cancelled, they are recreated. Always raises P4409.';

-- A recreated match points back at the match it replaced.
alter table public.tournament_matches
  add column if not exists superseded_by uuid
    references public.tournament_matches (id) on delete restrict;

comment on column public.tournament_matches.superseded_by is
  'The replacement match, when this match was recreated via levelledup_admin_recreate_match. Null otherwise.';

-- Lobby-scoped notifier used by match recreate.
create or replace function public.levelledup_notify_lobby_teams(
  p_tournament_id uuid,
  p_lobby_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_metadata jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  team_rec record;
  notification_id uuid;
  sent_count integer := 0;
begin
  for team_rec in
    select distinct registration.team_id
    from public.tournament_stage_assignments as assignment
    join public.tournament_session_entries as entry
      on entry.id = assignment.session_entry_id
    join public.tournament_registrations as registration
      on registration.id = entry.registration_id
    where assignment.tournament_id = p_tournament_id
      and assignment.lobby_id = p_lobby_id
      and assignment.status = 'assigned'
      and entry.status = 'active'
    order by registration.team_id
  loop
    insert into public.team_notifications
      (team_id, tournament_id, type, title, message, metadata)
    values (
      team_rec.team_id, p_tournament_id,
      btrim(p_type), btrim(p_title), btrim(p_message),
      coalesce(p_metadata, '{}'::jsonb)
    )
    returning id into notification_id;

    insert into public.team_notification_recipients (notification_id, user_id)
    select notification_id, member.profile_id
    from public.team_roster_members as member
    where member.team_id = team_rec.team_id
      and member.status = 'active'
      and member.profile_id is not null
    on conflict do nothing;

    sent_count := sent_count + 1;
  end loop;

  return sent_count;
end;
$$;

comment on function public.levelledup_notify_lobby_teams(uuid, uuid, text, text, text, jsonb) is
  'Notifies the teams currently assigned to one lobby (active roster members only).';

alter function public.levelledup_notify_lobby_teams(uuid, uuid, text, text, text, jsonb)
  owner to postgres;
revoke all on function public.levelledup_notify_lobby_teams(uuid, uuid, text, text, text, jsonb)
  from public, anon, authenticated;

create or replace function public.levelledup_admin_recreate_match(
  p_match_id uuid,
  p_message text,
  p_scheduled_start_at timestamptz default null
)
returns public.tournament_matches
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  old_match public.tournament_matches;
  new_match public.tournament_matches;
  new_match_number integer;
  notify_message text := nullif(btrim(coalesce(p_message, '')), '');
begin
  perform public.levelledup_require_admin('admin');
  perform set_config('levelledup.paused_write_bypass', 'on', true);

  if p_match_id is null then
    raise exception 'A match is required.' using errcode = '22023';
  end if;

  if notify_message is null or char_length(notify_message) > 500 then
    raise exception 'A message for the players is required (3 to 500 characters).'
      using errcode = '22023';
  end if;
  if char_length(notify_message) < 3 then
    raise exception 'A message for the players is required (3 to 500 characters).'
      using errcode = '22023';
  end if;

  select tournament_matches.*
  into old_match
  from public.tournament_matches
  where tournament_matches.id = p_match_id
  for update;

  if old_match.id is null then
    raise exception 'Match not found.' using errcode = 'P4203';
  end if;

  if old_match.status not in ('scheduled', 'pre_match') then
    raise exception 'Only a scheduled match can be recreated. Finish a live match first.'
      using errcode = '22023';
  end if;

  select coalesce(max(match_number), 0) + 1
  into new_match_number
  from public.tournament_matches
  where lobby_id = old_match.lobby_id;

  insert into public.tournament_matches (
    tournament_id, stage_id, lobby_id, match_number, map_code,
    scheduled_start_at, status
  )
  values (
    old_match.tournament_id, old_match.stage_id, old_match.lobby_id,
    new_match_number, old_match.map_code,
    coalesce(p_scheduled_start_at, now()), 'scheduled'
  )
  returning * into new_match;

  update public.tournament_matches
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_reason = 'Recreated as match ' || new_match_number::text || ': ' || notify_message,
      pre_match_closed_at = case when old_match.status = 'pre_match' then now() else pre_match_closed_at end,
      superseded_by = new_match.id
  where id = old_match.id;

  -- The teams stay in the same lobby, so they automatically belong to the
  -- new match. Every lobby player is told what happened, in the admin's words.
  perform public.levelledup_notify_lobby_teams(
    old_match.tournament_id,
    old_match.lobby_id,
    'match_recreated',
    'Match updated',
    notify_message,
    jsonb_build_object(
      'old_match_id', old_match.id::text,
      'new_match_id', new_match.id::text,
      'new_match_number', new_match_number,
      'recreated_by', actor_user_id::text
    )
  );

  return new_match;
end;
$$;

comment on function public.levelledup_admin_recreate_match(uuid, text, timestamptz) is
  'Replaces a scheduled match with a fresh one in the same lobby. Teams shift automatically; every lobby player is notified with the admin message.';

alter function public.levelledup_admin_recreate_match(uuid, text, timestamptz)
  owner to postgres;
revoke all on function public.levelledup_admin_recreate_match(uuid, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_recreate_match(uuid, text, timestamptz)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 10. Cancel & Recreate, manual variant (Haider's option B).
--
-- Haider creates the new tournament himself, then runs this: every team from
-- the CANCELLED tournament is registered into the new one, and all their
-- UNUSED paid value moves with them as one team-credit row in the new
-- tournament. No credit is ever paid out. Consumed entries stay as history
-- in the old tournament. Earned (free) entries do not move.
-- ----------------------------------------------------------------------------

-- The old status list had no word for "moved to a rebuilt tournament".
alter table public.tournament_registration_paid_entries
  drop constraint tournament_registration_paid_entries_status_valid;
alter table public.tournament_registration_paid_entries
  add constraint tournament_registration_paid_entries_status_valid
  check (status in ('paid', 'refund_pending', 'consumed', 'credited', 'refunded', 'migrated'));

create or replace function public.levelledup_admin_migrate_tournament_teams(
  p_from_tournament_id uuid,
  p_to_tournament_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_user_id uuid := auth.uid();
  from_tournament public.tournaments;
  to_tournament public.tournaments;
  reg record;
  paid_entry record;
  old_credit record;
  init_payment public.tournament_registration_payments;
  new_registration_id uuid;
  new_slot integer;
  migrated_teams integer := 0;
  skipped_teams integer := 0;
  migrated_value integer := 0;
  migrated_currency text := null;
  source_payment_id uuid := null;
  source_reference_id text := null;
  participated boolean;
  notification_id uuid;
begin
  perform public.levelledup_require_admin('admin');
  perform set_config('levelledup.paused_write_bypass', 'on', true);

  if p_from_tournament_id is null or p_to_tournament_id is null then
    raise exception 'Both tournaments are required.' using errcode = '22023';
  end if;

  if p_from_tournament_id = p_to_tournament_id then
    raise exception 'Cannot migrate a tournament into itself.' using errcode = '22023';
  end if;

  select tournament.*
  into from_tournament
  from public.tournaments as tournament
  where tournament.id = p_from_tournament_id
  for update;

  if from_tournament.id is null then
    raise exception 'Source tournament not found.' using errcode = 'P4301';
  end if;

  if from_tournament.status <> 'cancelled' then
    raise exception 'The source tournament must be cancelled first.'
      using errcode = 'P4303';
  end if;

  select tournament.*
  into to_tournament
  from public.tournaments as tournament
  where tournament.id = p_to_tournament_id
  for update;

  if to_tournament.id is null then
    raise exception 'Target tournament not found.' using errcode = 'P4301';
  end if;

  if to_tournament.status <> 'registration_open' then
    raise exception 'The new tournament must be open for registration.'
      using errcode = 'P4303';
  end if;

  if to_tournament.paused_at is not null then
    raise exception 'The new tournament is paused. Resume it first.'
      using errcode = 'P4408';
  end if;

  for reg in
    select current_registration.*
    from public.tournament_registrations as current_registration
    where current_registration.tournament_id = from_tournament.id
      and current_registration.status in ('pending', 'confirmed')
    order by current_registration.created_at, current_registration.id
  loop
    if exists (
      select 1
      from public.tournament_registrations as existing
      where existing.tournament_id = to_tournament.id
        and existing.team_id = reg.team_id
        and existing.status in ('pending', 'confirmed')
    ) then
      skipped_teams := skipped_teams + 1;
      continue;
    end if;

    select coalesce(max(slot_number), 0) + 1
    into new_slot
    from public.tournament_registrations
    where tournament_id = to_tournament.id
      and status = 'confirmed';

    insert into public.tournament_registrations (
      tournament_id, team_id, status, slot_number,
      reviewed_at, reviewed_by, confirmed_at
    )
    values (
      to_tournament.id, reg.team_id, 'confirmed', new_slot,
      now(), actor_user_id, now()
    )
    returning id into new_registration_id;

    migrated_value := 0;
    migrated_currency := null;
    source_payment_id := null;
    source_reference_id := null;

    -- Leg 1: team credit already issued in the old tournament.
    for old_credit in
      select credit.amount_minor, credit.currency,
             credit.source_payment_id, credit.source_reference_id
      from public.tournament_team_credits as credit
      where credit.registration_id = reg.id
        and credit.status = 'available'
      order by credit.created_at, credit.id
    loop
      if migrated_currency is null then
        migrated_currency := old_credit.currency;
      elsif old_credit.currency <> migrated_currency then
        raise exception 'Mixed currencies cannot be migrated for one team.'
          using errcode = '22023';
      end if;
      migrated_value := migrated_value + old_credit.amount_minor;
      if source_payment_id is null then
        source_payment_id := old_credit.source_payment_id;
        source_reference_id := old_credit.source_reference_id;
      end if;
    end loop;

    -- Leg 2: unused session paid entries move as value, marked migrated.
    for paid_entry in
      select paid_entry_row.amount_minor, paid_entry_row.currency,
             paid_entry_row.id as paid_entry_id,
             payment.id as payment_id, payment.reference_id
      from public.tournament_registration_paid_entries as paid_entry_row
      join public.tournament_registration_payments as payment
        on payment.id = paid_entry_row.source_payment_id
      where paid_entry_row.registration_id = reg.id
        and paid_entry_row.status = 'paid'
        and not exists (
          select 1
          from public.tournament_lobbies as lobby
          join public.tournament_matches as match
            on match.lobby_id = lobby.id
          where lobby.tournament_id = paid_entry_row.tournament_id
            and lobby.stage_id = paid_entry_row.stage_id
            and (
              paid_entry_row.entry_scope = 'stage'
              or lobby.session_id = paid_entry_row.session_id
            )
            and match.status in ('live', 'completed')
        )
      order by paid_entry_row.created_at, paid_entry_row.id
    loop
      if migrated_currency is null then
        migrated_currency := paid_entry.currency;
      elsif paid_entry.currency <> migrated_currency then
        raise exception 'Mixed currencies cannot be migrated for one team.'
          using errcode = '22023';
      end if;
      migrated_value := migrated_value + paid_entry.amount_minor;
      if source_payment_id is null then
        source_payment_id := paid_entry.payment_id;
        source_reference_id := paid_entry.reference_id;
      end if;

      update public.tournament_registration_paid_entries
      set status = 'migrated', updated_at = now()
      where id = paid_entry.paid_entry_id;
    end loop;

    -- Leg 3: the registration fee moves too, but ONLY if the team never
    -- participated in the old tournament and it was not already credited.
    select exists (
      select 1
      from public.tournament_session_entries as entry
      join public.tournament_stage_assignments as assignment
        on assignment.session_entry_id = entry.id
      join public.tournament_matches as match
        on match.lobby_id = assignment.lobby_id
       and match.stage_id = assignment.stage_id
       and match.tournament_id = assignment.tournament_id
      where entry.registration_id = reg.id
        and match.status in ('live', 'completed')
    ) into participated;

    if not participated then
      select payment.*
      into init_payment
      from public.tournament_registration_payments as payment
      where payment.registration_id = reg.id
        and payment.tournament_id = from_tournament.id
        and payment.team_id = reg.team_id
        and payment.status = 'verified'
        and (
          payment.session_id is null
          or (
            reg.initial_session_id = payment.session_id
            and payment.expected_amount_minor::bigint = from_tournament.entry_fee_minor
            and payment.currency = from_tournament.currency
          )
        )
        and not exists (
          select 1
          from public.tournament_team_credits as credit
          where credit.source_payment_id = payment.id
        )
      order by payment.submitted_at, payment.id
      limit 1;

      if init_payment.id is not null and from_tournament.entry_fee_minor > 0 then
        if migrated_currency is null then
          migrated_currency := init_payment.currency;
        elsif init_payment.currency <> migrated_currency then
          raise exception 'Mixed currencies cannot be migrated for one team.'
            using errcode = '22023';
        end if;
        migrated_value := migrated_value + from_tournament.entry_fee_minor;
        if source_payment_id is null then
          source_payment_id := init_payment.id;
          source_reference_id := init_payment.reference_id;
        end if;
      end if;
    end if;

    -- Land the moved money as one team-credit row in the NEW tournament.
    if migrated_value > 0 then
      insert into public.tournament_team_credits (
        tournament_id, registration_id, team_id, source_payment_id,
        source_reference_id, amount_minor, currency, status,
        created_by, status_updated_by
      )
      values (
        to_tournament.id, new_registration_id, reg.team_id,
        source_payment_id, source_reference_id,
        migrated_value, migrated_currency,
        'available', actor_user_id, actor_user_id
      );
    end if;

    -- Settle the old tournament: cancel whatever was never used there.
    perform public.levelledup_cancel_unused_session_entries_skip_consumed(
      reg.id, actor_user_id,
      'Team migrated to rebuilt tournament; unused participation cancelled'
    );

    insert into public.team_notifications
      (team_id, tournament_id, type, title, message, metadata)
    values (
      reg.team_id, to_tournament.id,
      'tournament_migrated',
      'Moved to the new tournament',
      'Your team was moved to ' || to_tournament.name
        || '. Unused payments moved with you as team credit.',
      jsonb_build_object(
        'from_tournament_id', from_tournament.id::text,
        'migrated_value_minor', migrated_value,
        'currency', migrated_currency
      )
    )
    returning id into notification_id;

    insert into public.team_notification_recipients (notification_id, user_id)
    select notification_id, member.profile_id
    from public.team_roster_members as member
    where member.team_id = reg.team_id
      and member.status = 'active'
      and member.profile_id is not null
    on conflict do nothing;

    migrated_teams := migrated_teams + 1;
  end loop;

  return jsonb_build_object(
    'from_tournament_id', from_tournament.id,
    'to_tournament_id', to_tournament.id,
    'migrated_teams', migrated_teams,
    'skipped_teams', skipped_teams
  );
end;
$$;

comment on function public.levelledup_admin_migrate_tournament_teams(uuid, uuid) is
  'Cancel & Recreate: moves teams from a cancelled tournament into a new open one. Unused paid value moves as team credit; no credit is paid out. Consumed entries stay as history.';

alter function public.levelledup_admin_migrate_tournament_teams(uuid, uuid)
  owner to postgres;
revoke all on function public.levelledup_admin_migrate_tournament_teams(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_migrate_tournament_teams(uuid, uuid)
  to authenticated;

commit;
