begin;

create policy "Admins can read all tournaments"
  on public.tournaments
  for select
  to authenticated
  using (public.levelledup_has_admin_role('admin'));

create function public.levelledup_admin_create_tournament(
  p_name text,
  p_description text,
  p_scheduled_start_at timestamptz,
  p_scheduled_end_at timestamptz,
  p_registration_opens_at timestamptz,
  p_registration_closes_at timestamptz,
  p_max_team_slots integer,
  p_matches_per_day integer,
  p_number_of_days integer,
  p_game_mode text,
  p_perspective text,
  p_entry_fee_minor bigint,
  p_currency text,
  p_reward_model text,
  p_prize_pool_minor bigint,
  p_per_kill_reward_minor bigint
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  created_tournament public.tournaments;
begin
  perform public.levelledup_require_admin('admin');

  insert into public.tournaments (
    name,
    description,
    status,
    scheduled_start_at,
    scheduled_end_at,
    registration_opens_at,
    registration_closes_at,
    max_team_slots,
    matches_per_day,
    number_of_days,
    game_mode,
    perspective,
    entry_fee_minor,
    currency,
    reward_model,
    prize_pool_minor,
    per_kill_reward_minor
  )
  values (
    btrim(p_name),
    nullif(btrim(p_description), ''),
    'draft',
    p_scheduled_start_at,
    p_scheduled_end_at,
    p_registration_opens_at,
    p_registration_closes_at,
    p_max_team_slots,
    p_matches_per_day,
    p_number_of_days,
    lower(p_game_mode),
    lower(p_perspective),
    p_entry_fee_minor,
    upper(p_currency),
    lower(p_reward_model),
    p_prize_pool_minor,
    p_per_kill_reward_minor
  )
  returning * into created_tournament;

  return created_tournament;
end;
$$;

alter function public.levelledup_admin_create_tournament(
  text,
  text,
  timestamptz,
  timestamptz,
  timestamptz,
  timestamptz,
  integer,
  integer,
  integer,
  text,
  text,
  bigint,
  text,
  text,
  bigint,
  bigint
)
  owner to postgres;

revoke all on function public.levelledup_admin_create_tournament(
  text,
  text,
  timestamptz,
  timestamptz,
  timestamptz,
  timestamptz,
  integer,
  integer,
  integer,
  text,
  text,
  bigint,
  text,
  text,
  bigint,
  bigint
)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_create_tournament(
  text,
  text,
  timestamptz,
  timestamptz,
  timestamptz,
  timestamptz,
  integer,
  integer,
  integer,
  text,
  text,
  bigint,
  text,
  text,
  bigint,
  bigint
)
  to authenticated;

create function public.levelledup_admin_update_draft_tournament(
  p_tournament_id uuid,
  p_name text,
  p_description text,
  p_scheduled_start_at timestamptz,
  p_scheduled_end_at timestamptz,
  p_registration_opens_at timestamptz,
  p_registration_closes_at timestamptz,
  p_max_team_slots integer,
  p_matches_per_day integer,
  p_number_of_days integer,
  p_game_mode text,
  p_perspective text,
  p_entry_fee_minor bigint,
  p_currency text,
  p_reward_model text,
  p_prize_pool_minor bigint,
  p_per_kill_reward_minor bigint
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
begin
  perform public.levelledup_require_admin('admin');

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4301';
  end if;

  if selected_tournament.status <> 'draft' then
    raise exception 'Only draft tournaments can be edited.'
      using errcode = 'P4302';
  end if;

  update public.tournaments
  set
    name = btrim(p_name),
    description = nullif(btrim(p_description), ''),
    scheduled_start_at = p_scheduled_start_at,
    scheduled_end_at = p_scheduled_end_at,
    registration_opens_at = p_registration_opens_at,
    registration_closes_at = p_registration_closes_at,
    max_team_slots = p_max_team_slots,
    matches_per_day = p_matches_per_day,
    number_of_days = p_number_of_days,
    game_mode = lower(p_game_mode),
    perspective = lower(p_perspective),
    entry_fee_minor = p_entry_fee_minor,
    currency = upper(p_currency),
    reward_model = lower(p_reward_model),
    prize_pool_minor = p_prize_pool_minor,
    per_kill_reward_minor = p_per_kill_reward_minor
  where id = selected_tournament.id
  returning * into selected_tournament;

  return selected_tournament;
end;
$$;

alter function public.levelledup_admin_update_draft_tournament(
  uuid,
  text,
  text,
  timestamptz,
  timestamptz,
  timestamptz,
  timestamptz,
  integer,
  integer,
  integer,
  text,
  text,
  bigint,
  text,
  text,
  bigint,
  bigint
)
  owner to postgres;

revoke all on function public.levelledup_admin_update_draft_tournament(
  uuid,
  text,
  text,
  timestamptz,
  timestamptz,
  timestamptz,
  timestamptz,
  integer,
  integer,
  integer,
  text,
  text,
  bigint,
  text,
  text,
  bigint,
  bigint
)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_update_draft_tournament(
  uuid,
  text,
  text,
  timestamptz,
  timestamptz,
  timestamptz,
  timestamptz,
  integer,
  integer,
  integer,
  text,
  text,
  bigint,
  text,
  text,
  bigint,
  bigint
)
  to authenticated;

create function public.levelledup_admin_transition_tournament(
  p_tournament_id uuid,
  p_action text
)
returns public.tournaments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  selected_tournament public.tournaments;
  normalized_action text := lower(btrim(p_action));
begin
  perform public.levelledup_require_admin('admin');

  select tournaments.*
  into selected_tournament
  from public.tournaments
  where tournaments.id = p_tournament_id
  for update;

  if selected_tournament.id is null then
    raise exception 'Tournament not found.'
      using errcode = 'P4301';
  end if;

  if normalized_action = 'open_registration' then
    if selected_tournament.status <> 'draft' then
      raise exception 'Only a draft tournament can open registration.'
        using errcode = 'P4303';
    end if;

    if now() < selected_tournament.registration_opens_at
      or now() >= selected_tournament.registration_closes_at
      or now() >= selected_tournament.scheduled_start_at then
      raise exception 'Registration can open only inside its configured registration window.'
        using errcode = 'P4304';
    end if;

    update public.tournaments
    set status = 'registration_open'
    where id = selected_tournament.id
    returning * into selected_tournament;
  elsif normalized_action = 'close_registration' then
    if selected_tournament.status <> 'registration_open' then
      raise exception 'Only an open registration can be closed.'
        using errcode = 'P4303';
    end if;

    update public.tournaments
    set status = 'registration_closed'
    where id = selected_tournament.id
    returning * into selected_tournament;
  elsif normalized_action = 'cancel' then
    if selected_tournament.status in ('completed', 'cancelled') then
      raise exception 'Completed or cancelled tournaments cannot be cancelled again.'
        using errcode = 'P4303';
    end if;

    update public.tournaments
    set status = 'cancelled'
    where id = selected_tournament.id
    returning * into selected_tournament;
  else
    raise exception 'Unsupported tournament lifecycle action.'
      using errcode = 'P4303';
  end if;

  return selected_tournament;
end;
$$;

alter function public.levelledup_admin_transition_tournament(uuid, text)
  owner to postgres;

revoke all on function public.levelledup_admin_transition_tournament(uuid, text)
  from public, anon, authenticated;

grant execute on function public.levelledup_admin_transition_tournament(uuid, text)
  to authenticated;

comment on function public.levelledup_admin_transition_tournament(uuid, text) is
  'Allows only draft-to-registration_open, registration_open-to-registration_closed, and cancellation of nonterminal tournaments.';

commit;
