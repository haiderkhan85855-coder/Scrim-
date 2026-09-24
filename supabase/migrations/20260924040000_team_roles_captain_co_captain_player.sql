-- Fix 6: team roles become Captain / Co-Captain / Player.
--
-- Handoff-locked target roles are Captain / Co-Captain / Player; the old
-- Member/Substitute model is converted deliberately:
--   * existing 'member' and 'substitute' rows become 'player';
--   * 'substitute' is removed everywhere (DB, RPCs, UI);
--   * 'co_captain' is added, at most one active Co-Captain per team.
--
-- Co-Captain powers (handoff): accept recruitment/join requests, register for
-- tournaments, perform payment-related actions, finalize Squad.
-- Captain-only powers (unchanged): remove players, disband team, transfer
-- Captaincy / appoint Captain (and appoint/demote Co-Captain).

-- 1. Drop the old role checks FIRST. The data migration below writes
--    'player', which the old ('captain', 'member', 'substitute') checks
--    reject -- updating before dropping aborts the migration on any database
--    that already holds roster rows (e.g. live teams with members/substitutes).
alter table public.team_roster_members
  drop constraint if exists team_roster_members_role_valid;
alter table public.tournament_registration_roster
  drop constraint if exists tournament_registration_roster_role_valid;

-- 2. Data migration: Substitute and Member both become Player.
update public.team_roster_members
set role = 'player'
where role in ('member', 'substitute');

update public.tournament_registration_roster
set role = 'player'
where role in ('member', 'substitute');

-- 3. Role check constraints: Captain / Co-Captain / Player.
alter table public.team_roster_members
  drop constraint if exists team_roster_members_role_valid;
alter table public.team_roster_members
  add constraint team_roster_members_role_valid check (
    role in ('captain', 'co_captain', 'player')
  );

alter table public.tournament_registration_roster
  drop constraint if exists tournament_registration_roster_role_valid;
alter table public.tournament_registration_roster
  add constraint tournament_registration_roster_role_valid check (
    role in ('captain', 'co_captain', 'player')
  );

-- 4. At most one active Co-Captain per team (mirrors the captain rule).
create unique index if not exists team_roster_members_active_co_captain_unique
  on public.team_roster_members (team_id)
  where status = 'active' and role = 'co_captain';

-- 5. Manager helper: active Captain OR active Co-Captain.
create or replace function public.levelledup_is_team_manager(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.team_roster_members
    where team_roster_members.team_id = p_team_id
      and team_roster_members.profile_id = auth.uid()
      and team_roster_members.status = 'active'
      and team_roster_members.role in ('captain', 'co_captain')
  );
$$;

alter function public.levelledup_is_team_manager(uuid)
  owner to postgres;

revoke all on function public.levelledup_is_team_manager(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_is_team_manager(uuid)
  to authenticated;


-- Co-Captain widened: levelledup_approve_team_join_request

create or replace function public.levelledup_approve_team_join_request(
  p_request_id uuid,
  p_role text default 'player'
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  request_team_id uuid;
  join_request public.team_join_requests;
  applicant_pubg_uid text;
  applicant_pubg_ign text;
  applicant_display_name text;
  active_team_count integer;
  unclaimed_roster_id uuid;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to approve a join request.'
      using errcode = '42501';
  end if;

  if p_role <> 'player' then
    raise exception 'Approved role must be Player.'
      using errcode = '22023';
  end if;

  select team_join_requests.team_id
  into request_team_id
  from public.team_join_requests
  where team_join_requests.id = p_request_id;

  if request_team_id is null then
    raise exception 'Pending join request not found.'
      using errcode = 'P3005';
  end if;

  perform 1
  from public.teams
  where teams.id = request_team_id
    and teams.status = 'active'
  for update;

  if not found then
    raise exception 'The team is no longer active.'
      using errcode = 'P3020';
  end if;

  select team_join_requests.*
  into join_request
  from public.team_join_requests
  where team_join_requests.id = p_request_id
  for update;

  if join_request.id is null or join_request.status <> 'pending' then
    raise exception 'Pending join request not found.'
      using errcode = 'P3005';
  end if;

  if not public.levelledup_is_team_manager(join_request.team_id) then
    raise exception 'Only the team Captain or Co-Captain can approve this request.'
      using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(join_request.profile_id::text, 0)
  );

  select count(distinct team_roster_members.team_id)::integer
  into active_team_count
  from public.team_roster_members
  where team_roster_members.profile_id = join_request.profile_id
    and team_roster_members.status = 'active';

  if active_team_count >= 3 then
    raise exception 'Maximum of 3 teams reached.'
      using errcode = 'P3001';
  end if;

  if exists (
    select 1
    from public.team_roster_members
    where team_roster_members.team_id = join_request.team_id
      and team_roster_members.profile_id = join_request.profile_id
      and team_roster_members.status = 'active'
  ) then
    raise exception 'This player already belongs to the team.'
      using errcode = 'P3002';
  end if;

  select
    nullif(btrim(profiles.pubg_uid), ''),
    nullif(btrim(profiles.pubg_ign), ''),
    nullif(btrim(profiles.display_name), '')
  into
    applicant_pubg_uid,
    applicant_pubg_ign,
    applicant_display_name
  from public.profiles
  where profiles.id = join_request.profile_id;

  if applicant_pubg_uid is null or applicant_display_name is null then
    raise exception 'The player must complete Display Name and PUBG UID before joining.'
      using errcode = 'P3006';
  end if;

  select team_roster_members.id
  into unclaimed_roster_id
  from public.team_roster_members
  where team_roster_members.team_id = join_request.team_id
    and team_roster_members.pubg_uid = applicant_pubg_uid
    and team_roster_members.profile_id is null
    and team_roster_members.status = 'active'
  for update;

  if unclaimed_roster_id is not null then
    update public.team_roster_members
    set
      profile_id = join_request.profile_id,
      pubg_ign = applicant_pubg_ign,
      display_name = applicant_display_name,
      linked_at = now(),
      linked_by = authenticated_user_id
    where id = unclaimed_roster_id;
  else
    begin
      insert into public.team_roster_members (
        team_id,
        profile_id,
        pubg_uid,
        pubg_ign,
        display_name,
        role,
        status,
        linked_at,
        linked_by,
        created_by
      )
      values (
        join_request.team_id,
        join_request.profile_id,
        applicant_pubg_uid,
        applicant_pubg_ign,
        applicant_display_name,
        p_role,
        'active',
        now(),
        authenticated_user_id,
        authenticated_user_id
      );
    exception
      when unique_violation then
        raise exception 'This player already occupies an active roster slot in the team.'
          using errcode = 'P3002';
    end;
  end if;

  update public.team_join_requests
  set
    status = 'approved',
    reviewed_at = now(),
    reviewed_by = authenticated_user_id
  where id = join_request.id;

  return true;
end;
$$;
;

-- Co-Captain widened: levelledup_reject_team_join_request

create or replace function public.levelledup_reject_team_join_request(
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
  join_request public.team_join_requests;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to reject a join request.'
      using errcode = '42501';
  end if;

  select team_join_requests.*
  into join_request
  from public.team_join_requests
  where team_join_requests.id = p_request_id
  for update;

  if join_request.id is null or join_request.status <> 'pending' then
    raise exception 'Pending join request not found.'
      using errcode = 'P3005';
  end if;

  if not public.levelledup_is_team_manager(join_request.team_id) then
    raise exception 'Only the team Captain or Co-Captain can reject this request.'
      using errcode = '42501';
  end if;

  update public.team_join_requests
  set
    status = 'rejected',
    reviewed_at = now(),
    reviewed_by = authenticated_user_id
  where id = join_request.id;

  return true;
end;
$$;
;

-- Co-Captain widened: levelledup_get_pending_join_requests

create or replace function public.levelledup_get_pending_join_requests()
returns table (
  request_id uuid,
  team_id uuid,
  display_name text,
  pubg_ign text,
  pubg_uid text,
  requested_at timestamptz
)
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select
    team_join_requests.id,
    team_join_requests.team_id,
    profiles.display_name,
    profiles.pubg_ign,
    profiles.pubg_uid,
    team_join_requests.created_at
  from public.team_join_requests
  join public.profiles
    on profiles.id = team_join_requests.profile_id
  where team_join_requests.status = 'pending'
    and public.levelledup_is_team_manager(
      team_join_requests.team_id
    )
  order by team_join_requests.created_at;
$$;
;

-- Co-Captain widened: levelledup_save_team_recruitment

create or replace function public.levelledup_save_team_recruitment(
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

  if not public.levelledup_is_team_manager(p_team_id) then
    raise exception 'Only the team Captain or Co-Captain can manage recruitment.'
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
;

-- Co-Captain widened: levelledup_set_team_recruitment_status

create or replace function public.levelledup_set_team_recruitment_status(
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

  if not public.levelledup_is_team_manager(p_team_id) then
    raise exception 'Only the team Captain or Co-Captain can manage recruitment.'
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
;

-- Co-Captain widened: levelledup_register_team_for_tournament

create or replace function public.levelledup_register_team_for_tournament(
  p_tournament_id uuid,
  p_team_id uuid
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  created_registration public.tournament_registrations;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to register a team.'
      using errcode = '42501';
  end if;

  if not public.levelledup_is_team_manager(p_team_id) then
    raise exception 'Only the team Captain or Co-Captain can register this team.'
      using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_tournament_id::text || ':team:' || p_team_id::text,
      0
    )
  );

  if exists (
    select 1
    from public.tournament_registrations
    where tournament_registrations.tournament_id = p_tournament_id
      and tournament_registrations.team_id = p_team_id
      and tournament_registrations.status in ('pending', 'confirmed')
  ) then
    raise exception 'This team already has an active tournament registration.'
      using errcode = 'P4017';
  end if;

  insert into public.tournament_registrations (
    tournament_id,
    team_id,
    status,
    roster_status
  )
  values (
    p_tournament_id,
    p_team_id,
    'pending',
    'draft'
  )
  returning * into created_registration;

  return created_registration;
end;
$$;
;

-- Co-Captain widened: levelledup_finalize_tournament_roster

create or replace function public.levelledup_finalize_tournament_roster(
  p_registration_id uuid,
  p_roster_member_ids uuid[]
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
  selected_member record;
  requested_squad_count integer;
  eligible_squad_count integer;
  inserted_squad_count integer;
  next_revision integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to finalize a tournament Squad.'
      using errcode = '42501';
  end if;

  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id
  for update;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.'
      using errcode = 'P4001';
  end if;

  if not public.levelledup_is_team_manager(selected_registration.team_id) then
    raise exception 'Only the active team Captain can finalize this Squad.'
      using errcode = '42501';
  end if;

  if selected_registration.status not in ('pending', 'confirmed')
    or selected_registration.roster_status not in ('draft', 'finalized') then
    raise exception 'Only an active unlocked tournament Squad can be finalized.'
      using errcode = 'P4015';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_registration.tournament_id
  for share;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4001';
  end if;

  if selected_tournament.status not in ('registration_open', 'registration_closed')
    or now() >= selected_tournament.roster_lock_at then
    raise exception 'The tournament Squad-lock deadline has passed.'
      using errcode = 'P4016';
  end if;

  requested_squad_count := cardinality(p_roster_member_ids);

  if requested_squad_count is null
    or requested_squad_count < 1
    or requested_squad_count > 6 then
    raise exception 'Select between 1 and 6 eligible Squad members.'
      using errcode = 'P4012';
  end if;

  if requested_squad_count <> (
    select count(distinct selected_member_id)::integer
    from unnest(p_roster_member_ids) as selected(selected_member_id)
  ) then
    raise exception 'The submitted tournament Squad contains duplicate selections.'
      using errcode = 'P4012';
  end if;

  select count(*)::integer
  into eligible_squad_count
  from public.team_roster_members as members
  where members.id = any(p_roster_member_ids)
    and members.team_id = selected_registration.team_id
    and members.status = 'active';

  if eligible_squad_count <> requested_squad_count then
    raise exception 'Every selected player must be an active member of the registering team.'
      using errcode = 'P4010';
  end if;

  for selected_member in
    select members.profile_id, members.pubg_uid
    from public.team_roster_members as members
    where members.id = any(p_roster_member_ids)
    order by coalesce(members.profile_id::text, ''), members.pubg_uid
  loop
    if selected_member.profile_id is not null then
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
          selected_registration.tournament_id::text
            || ':profile:' || selected_member.profile_id::text,
          0
        )
      );
    end if;

    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        selected_registration.tournament_id::text
          || ':pubg:' || selected_member.pubg_uid,
        0
      )
    );
  end loop;

  next_revision := selected_registration.roster_revision + 1;

  insert into public.tournament_registration_roster (
    registration_id,
    tournament_id,
    team_id,
    source_roster_member_id,
    profile_id,
    display_name,
    pubg_uid,
    pubg_ign,
    role,
    roster_number,
    revision_number
  )
  select
    selected_registration.id,
    selected_registration.tournament_id,
    selected_registration.team_id,
    members.id,
    members.profile_id,
    members.display_name,
    members.pubg_uid,
    members.pubg_ign,
    members.role,
    members.roster_number,
    next_revision
  from public.team_roster_members as members
  where members.id = any(p_roster_member_ids)
    and members.team_id = selected_registration.team_id
    and members.status = 'active'
  order by members.roster_number;

  get diagnostics inserted_squad_count = row_count;

  if inserted_squad_count <> requested_squad_count then
    raise exception 'Every selected player must remain active until Squad finalization completes.'
      using errcode = 'P4010';
  end if;

  update public.tournament_registrations
  set
    roster_revision = next_revision,
    roster_status = 'finalized',
    roster_finalized_at = now(),
    roster_locked_at = null
  where id = selected_registration.id
  returning * into selected_registration;

  return selected_registration;
end;
$$;
;

-- Co-Captain widened: levelledup_withdraw_tournament_registration

create or replace function public.levelledup_withdraw_tournament_registration(
  p_registration_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_registration public.tournament_registrations;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to withdraw a registration.'
      using errcode = '42501';
  end if;

  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id
  for update;

  if selected_registration.id is null
    or selected_registration.status not in ('pending', 'confirmed') then
    raise exception 'Active tournament registration not found.'
      using errcode = 'P4013';
  end if;

  if not public.levelledup_is_team_manager(selected_registration.team_id) then
    raise exception 'Only the team Captain or Co-Captain can withdraw this registration.'
      using errcode = '42501';
  end if;

  perform public.levelledup_credit_unused_entries_before_registration_close(
    selected_registration.id,
    authenticated_user_id,
    'Team registration withdrawn by Captain before registration close'
  );

  update public.tournament_registrations
  set status = 'withdrawn'
  where id = selected_registration.id;

  return true;
end;
$$;
;

-- Co-Captain widened: levelledup_submit_manual_tournament_payment

create or replace function public.levelledup_submit_manual_tournament_payment(
  p_registration_id uuid,
  p_reference_id text
)
returns public.tournament_registration_payments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_reference text := btrim(coalesce(p_reference_id, ''));
  registration public.tournament_registrations;
  tournament public.tournaments;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
  created_payment public.tournament_registration_payments;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to submit payment.'
      using errcode = '42501';
  end if;

  if char_length(normalized_reference) not between 3 and 120 then
    raise exception 'Enter a valid transaction or reference ID.'
      using errcode = 'P4501';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4502';
  end if;

  if not public.levelledup_is_team_manager(registration.team_id) then
    raise exception 'Only the active team Captain can submit payment.'
      using errcode = '42501';
  end if;

  if registration.status <> 'pending'
    or registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the pending tournament Squad before submitting payment.'
      using errcode = 'P4503';
  end if;

  select current_tournament.* into tournament
  from public.tournaments as current_tournament
  where current_tournament.id = registration.tournament_id
  for share;

  select current_session.* into selected_session
  from public.tournament_stage_sessions as current_session
  where current_session.id = registration.initial_session_id
  for share;

  select current_stage.* into selected_stage
  from public.tournament_stages as current_stage
  where current_stage.id = selected_session.stage_id
  for share;

  if tournament.id is null or selected_session.id is null
    or selected_session.tournament_id <> registration.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> registration.tournament_id
    or selected_stage.stage_number <> 1
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'Select an exact Stage 1 Session before submitting payment.'
      using errcode = 'P4420';
  end if;

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Payment requires a future selected Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  if tournament.entry_fee_minor = 0 then
    raise exception 'This Tournament has no initial registration fee; payment is not required.'
      using errcode = 'P4504';
  end if;

  if tournament.entry_fee_minor > 2147483647 then
    raise exception 'The Tournament initial registration fee exceeds the existing payment amount range.'
      using errcode = '22003';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(registration.id::text || ':payment', 0)
  );

  if exists (
    select 1
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.status in ('pending', 'verified')
  ) then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
  end if;

  insert into public.tournament_registration_payments (
    registration_id, tournament_id, team_id, session_id,
    payment_method, status, expected_amount_minor, currency,
    reference_id, submitted_by
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    selected_session.id, 'manual', 'pending',
    tournament.entry_fee_minor::integer, tournament.currency,
    normalized_reference, authenticated_user_id
  ) returning * into created_payment;

  return created_payment;
exception
  when unique_violation then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
end;
$$;
;

-- Co-Captain widened: levelledup_select_registration_initial_session

create or replace function public.levelledup_select_registration_initial_session(
  p_registration_id uuid,
  p_session_id uuid
)
returns public.tournament_registrations
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  registration public.tournament_registrations;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to select an initial Session.'
      using errcode = '42501';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4402';
  end if;

  if not public.levelledup_is_team_manager(registration.team_id) then
    raise exception 'Only the current active team Captain can select the initial Session.'
      using errcode = '42501';
  end if;

  if registration.status <> 'pending' then
    raise exception 'Only a pending registration can select its initial Session.'
      using errcode = 'P4420';
  end if;

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = p_session_id
  for share;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = selected_session.stage_id
  for share;

  if selected_session.id is null
    or selected_session.tournament_id <> registration.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> registration.tournament_id
    or selected_stage.stage_number <> 1
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'The initial Session must belong to Stage 1 of the registration Tournament.'
      using errcode = '23503';
  end if;

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Select a future Stage 1 Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  if registration.initial_session_id is not distinct from selected_session.id then
    return registration;
  end if;

  update public.tournament_registrations
  set initial_session_id = selected_session.id
  where id = registration.id
  returning * into registration;

  return registration;
end;
$$;
;

-- Captain-only role changes now target Player / Co-Captain.

create or replace function public.levelledup_set_team_member_role(
  p_roster_member_id uuid,
  p_role text
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  roster_member public.team_roster_members;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to change a roster role.'
      using errcode = '42501';
  end if;

  if p_role not in ('player', 'co_captain') then
    raise exception 'Role must be Player or Co-Captain.'
      using errcode = '22023';
  end if;

  select team_roster_members.*
  into roster_member
  from public.team_roster_members
  where team_roster_members.id = p_roster_member_id
  for update;

  if roster_member.id is null or roster_member.status <> 'active' then
    raise exception 'Active roster member not found.'
      using errcode = 'P3011';
  end if;

  if roster_member.role = 'captain' then
    raise exception 'The captain role cannot be changed here.'
      using errcode = 'P3012';
  end if;

  if not public.levelledup_is_active_team_captain(roster_member.team_id) then
    raise exception 'Only the active team captain can change member roles.'
      using errcode = '42501';
  end if;

  update public.team_roster_members
  set role = p_role
  where id = roster_member.id;

  return true;
end;
$$;
;

-- Transfer captaincy: role literals updated, still captain-only.

create or replace function public.levelledup_transfer_team_captaincy(
  p_team_id uuid,
  p_target_roster_member_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  current_captain_id uuid;
  target_member public.team_roster_members;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to transfer captaincy.'
      using errcode = '42501';
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

  select team_roster_members.id
  into current_captain_id
  from public.team_roster_members
  where team_roster_members.team_id = p_team_id
    and team_roster_members.profile_id = authenticated_user_id
    and team_roster_members.role = 'captain'
    and team_roster_members.status = 'active'
  for update;

  if current_captain_id is null then
    raise exception 'Only the active captain can transfer leadership.'
      using errcode = '42501';
  end if;

  select team_roster_members.*
  into target_member
  from public.team_roster_members
  where team_roster_members.id = p_target_roster_member_id
    and team_roster_members.team_id = p_team_id
    and team_roster_members.profile_id is not null
    and team_roster_members.role in ('player', 'co_captain')
    and team_roster_members.status = 'active'
  for update;

  if target_member.id is null then
    raise exception 'Select an active claimed Player or Co-Captain.'
      using errcode = 'P3021';
  end if;

  update public.team_roster_members
  set role = 'player'
  where id = current_captain_id;

  update public.team_roster_members
  set role = 'captain'
  where id = target_member.id;

  return true;
end;
$$;
;

-- 8a. Co-Captains can read their team join requests.
drop policy if exists "Active captains can read their team join requests"
  on public.team_join_requests;
drop policy if exists "Captains and Co-Captains can read their team join requests" on public.team_join_requests;
create policy "Captains and Co-Captains can read their team join requests"
  on public.team_join_requests
  for select
  to authenticated
  using (public.levelledup_is_team_manager(team_id));

-- 8b. Co-Captains can read their tournament payment history.
drop policy if exists "Captains can read their tournament payment history"
  on public.tournament_registration_payments;
drop policy if exists "Captains and Co-Captains can read their tournament payment history" on public.tournament_registration_payments;
create policy "Captains and Co-Captains can read their tournament payment history"
  on public.tournament_registration_payments
  for select
  to authenticated
  using (public.levelledup_is_team_manager(team_id));

-- 8c. Unclaimed-roster insert policy: role literals (still captain-only;
-- adding unclaimed members is not a Co-Captain power).
drop policy if exists "Captains can add unclaimed roster members"
  on public.team_roster_members;
drop policy if exists "Captains can add unclaimed roster members" on public.team_roster_members;
create policy "Captains can add unclaimed roster members"
  on public.team_roster_members
  for insert
  to authenticated
  with check (
    public.levelledup_is_active_team_captain(team_id)
    and profile_id is null
    and role = 'player'
    and status = 'active'
    and created_by = (select auth.uid())
  );

