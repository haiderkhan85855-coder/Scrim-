begin;

-- A voluntary withdrawal before the exact registration-close instant credits
-- only paid stage/session entries that are still unused. This is an internal
-- primitive: callers must authenticate and authorize the Captain separately.
-- The existing credit-entitlement trigger records the payer-owned ledger grant.
create function public.levelledup_credit_unused_entries_before_registration_close(
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
  selected_registration public.tournament_registrations;
  selected_tournament public.tournaments;
  selected_entry public.tournament_registration_paid_entries;
  created_case public.tournament_stage_refund_cases;
  credited_count integer := 0;
  normalized_reason text := btrim(coalesce(p_reason, ''));
  decision_at timestamptz;
begin
  if p_actor_user_id is null then
    raise exception 'A trusted credit actor is required.' using errcode = '42501';
  end if;

  if char_length(normalized_reason) not between 3 and 500 then
    raise exception 'Provide a credit reason between 3 and 500 characters.'
      using errcode = '22023';
  end if;

  select registrations.*
  into selected_registration
  from public.tournament_registrations as registrations
  where registrations.id = p_registration_id
  for update;

  if selected_registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4013';
  end if;

  select tournaments.*
  into selected_tournament
  from public.tournaments as tournaments
  where tournaments.id = selected_registration.tournament_id
  for share;

  decision_at := clock_timestamp();
  if selected_tournament.id is null
    or decision_at >= selected_tournament.registration_closes_at then
    return 0;
  end if;

  for selected_entry in
    select entries.*
    from public.tournament_registration_paid_entries as entries
    where entries.registration_id = selected_registration.id
      and entries.status in ('paid', 'refund_pending')
    order by entries.created_at, entries.id
  loop
    -- Match-live transitions use the same advisory-lock order. Re-read the
    -- paid entry only after taking those locks so play and credit cannot win
    -- the same entry concurrently.
    perform pg_advisory_xact_lock(
      hashtextextended('financial-stage:' || selected_entry.stage_id::text, 0)
    );
    if selected_entry.entry_scope = 'session' then
      perform pg_advisory_xact_lock(
        hashtextextended('financial-session:' || selected_entry.lobby_id::text, 0)
      );
    end if;

    select entries.*
    into selected_entry
    from public.tournament_registration_paid_entries as entries
    where entries.id = selected_entry.id
    for update;

    if selected_entry.status not in ('paid', 'refund_pending') then
      continue;
    end if;

    if exists (
      select 1
      from public.tournament_matches as matches
      where matches.stage_id = selected_entry.stage_id
        and (
          selected_entry.entry_scope = 'stage'
          or matches.lobby_id = selected_entry.lobby_id
        )
        and matches.status in ('live', 'completed')
    ) then
      continue;
    end if;

    if selected_entry.status = 'paid' then
      insert into public.tournament_stage_refund_cases (
        paid_entry_id,
        registration_id,
        tournament_id,
        team_id,
        stage_id,
        lobby_id,
        source_payment_id,
        amount_minor,
        currency,
        processing_mode,
        status,
        reason,
        created_by,
        reviewed_by,
        reviewed_at
      ) values (
        selected_entry.id,
        selected_entry.registration_id,
        selected_entry.tournament_id,
        selected_entry.team_id,
        selected_entry.stage_id,
        selected_entry.lobby_id,
        selected_entry.source_payment_id,
        selected_entry.amount_minor,
        selected_entry.currency,
        'automatic',
        'approved',
        normalized_reason,
        p_actor_user_id,
        p_actor_user_id,
        decision_at
      )
      returning * into created_case;

      update public.tournament_registration_paid_entries
      set status = 'refund_pending', updated_at = decision_at
      where id = selected_entry.id;
    else
      select cases.*
      into created_case
      from public.tournament_stage_refund_cases as cases
      where cases.paid_entry_id = selected_entry.id
        and cases.status <> 'rejected'
      for update;

      if created_case.id is null
        or created_case.status not in ('pending_review', 'approved') then
        raise exception 'Unused paid entry has no creditable refund case.'
          using errcode = '22023';
      end if;

      if created_case.status = 'pending_review' then
        update public.tournament_stage_refund_cases
        set
          status = 'approved',
          reviewed_by = p_actor_user_id,
          reviewed_at = decision_at,
          updated_at = decision_at
        where id = created_case.id
        returning * into created_case;
      end if;
    end if;

    insert into public.tournament_stage_credit_entitlements (
      refund_case_id,
      paid_entry_id,
      registration_id,
      tournament_id,
      team_id,
      source_payment_id,
      amount_minor,
      currency,
      created_by,
      status_updated_by,
      status_updated_at,
      created_at,
      updated_at
    ) values (
      created_case.id,
      selected_entry.id,
      selected_entry.registration_id,
      selected_entry.tournament_id,
      selected_entry.team_id,
      selected_entry.source_payment_id,
      selected_entry.amount_minor,
      selected_entry.currency,
      p_actor_user_id,
      p_actor_user_id,
      decision_at,
      decision_at,
      decision_at
    );

    update public.tournament_registration_paid_entries
    set status = 'credited', updated_at = decision_at
    where id = selected_entry.id;

    update public.tournament_stage_refund_cases
    set
      status = 'credited',
      credit_issued_at = decision_at,
      updated_at = decision_at
    where id = created_case.id;

    credited_count := credited_count + 1;
  end loop;

  return credited_count;
end;
$$;

alter function public.levelledup_credit_unused_entries_before_registration_close(uuid, uuid, text)
  owner to postgres;
revoke all on function public.levelledup_credit_unused_entries_before_registration_close(uuid, uuid, text)
  from public, anon, authenticated;

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

  if not public.levelledup_is_active_team_captain(selected_registration.team_id) then
    raise exception 'Only the active team captain can withdraw this registration.'
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

alter function public.levelledup_withdraw_tournament_registration(uuid)
  owner to postgres;
revoke all on function public.levelledup_withdraw_tournament_registration(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_withdraw_tournament_registration(uuid)
  to authenticated;

create or replace function public.levelledup_disband_team(
  p_team_id uuid,
  p_confirmation_team_id text
)
returns boolean
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  selected_team public.teams;
  selected_registration record;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to disband a team.'
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
    raise exception 'Only the active captain can disband this team.'
      using errcode = '42501';
  end if;

  if upper(btrim(coalesce(p_confirmation_team_id, ''))) <> selected_team.team_id then
    raise exception 'Team ID confirmation does not match.' using errcode = 'P3022';
  end if;

  -- Credit eligible unused entries while Captain authorization and active-team
  -- identity still exist. The existing team-status trigger performs the
  -- historical registration withdrawal after the team is archived.
  for selected_registration in
    select registrations.id
    from public.tournament_registrations as registrations
    join public.tournaments as tournaments
      on tournaments.id = registrations.tournament_id
    where registrations.team_id = selected_team.id
      and registrations.status in ('pending', 'confirmed')
      and clock_timestamp() < tournaments.registration_closes_at
    order by registrations.created_at, registrations.id
    for update of registrations
  loop
    perform public.levelledup_credit_unused_entries_before_registration_close(
      selected_registration.id,
      authenticated_user_id,
      'Team disbanded by Captain before registration close'
    );
  end loop;

  update public.teams
  set
    status = 'disbanded',
    disbanded_at = now(),
    disbanded_by = authenticated_user_id
  where id = selected_team.id;

  update public.team_roster_members
  set status = 'disbanded'
  where team_id = selected_team.id
    and status = 'active';

  update public.team_join_requests
  set
    status = 'rejected',
    reviewed_at = now(),
    reviewed_by = authenticated_user_id
  where team_id = selected_team.id
    and status = 'pending';

  return true;
end;
$$;

alter function public.levelledup_disband_team(uuid, text) owner to postgres;
revoke all on function public.levelledup_disband_team(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_disband_team(uuid, text)
  to authenticated;

commit;
