begin;

create function public.levelledup_random_tournament_id()
returns text
language sql
volatile
set search_path = ''
as $$
  select 'LU-T-' || string_agg(
    substr(
      'ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
      floor(random() * 32)::integer + 1,
      1
    ),
    ''
  )
  from generate_series(1, 8);
$$;

alter function public.levelledup_random_tournament_id()
  owner to postgres;

revoke all on function public.levelledup_random_tournament_id()
  from public, anon, authenticated;

create table public.tournaments (
  id uuid primary key default gen_random_uuid(),
  tournament_id text not null
    default public.levelledup_random_tournament_id(),
  name text not null,
  description text,
  status text not null default 'draft',
  scheduled_start_at timestamptz not null,
  scheduled_end_at timestamptz,
  registration_opens_at timestamptz not null,
  registration_closes_at timestamptz not null,
  max_team_slots integer not null,
  matches_per_day integer not null,
  number_of_days integer not null,
  game_mode text not null default 'squad',
  perspective text not null default 'tpp',
  entry_fee_minor bigint not null default 0,
  currency text not null,
  reward_model text not null,
  prize_pool_minor bigint,
  per_kill_reward_minor bigint,
  scoring_config jsonb not null default jsonb_build_object(
    'version', 1,
    'placement_points', jsonb_build_object(
      '1', 10,
      '2', 6,
      '3', 5,
      '4', 4,
      '5', 3,
      '6', 2,
      '7', 1,
      '8', 1,
      '9', 0,
      '10', 0,
      '11', 0,
      '12', 0,
      '13', 0,
      '14', 0,
      '15', 0,
      '16', 0
    ),
    'kill_points_per_kill', 1
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint tournaments_tournament_id_unique unique (tournament_id),
  constraint tournaments_tournament_id_format check (
    tournament_id ~ '^LU-T-[A-HJ-NP-Z2-9]{8}$'
  ),
  constraint tournaments_name_format check (
    name = btrim(name)
    and char_length(name) between 2 and 120
  ),
  constraint tournaments_description_format check (
    description is null
    or (
      description = btrim(description)
      and char_length(description) between 1 and 5000
    )
  ),
  constraint tournaments_status_valid check (
    status in (
      'draft',
      'registration_open',
      'registration_closed',
      'live',
      'completed',
      'cancelled'
    )
  ),
  constraint tournaments_schedule_valid check (
    scheduled_end_at is null
    or scheduled_end_at > scheduled_start_at
  ),
  constraint tournaments_registration_window_valid check (
    registration_opens_at < registration_closes_at
    and registration_closes_at <= scheduled_start_at
  ),
  constraint tournaments_max_team_slots_valid check (
    max_team_slots > 0
  ),
  constraint tournaments_matches_per_day_valid check (
    matches_per_day > 0
  ),
  constraint tournaments_number_of_days_valid check (
    number_of_days > 0
  ),
  constraint tournaments_game_mode_valid check (
    game_mode in ('solo', 'duo', 'squad')
  ),
  constraint tournaments_perspective_valid check (
    perspective in ('tpp', 'fpp')
  ),
  constraint tournaments_entry_fee_minor_valid check (
    entry_fee_minor >= 0
  ),
  constraint tournaments_currency_valid check (
    currency ~ '^[A-Z]{3}$'
  ),
  constraint tournaments_reward_model_valid check (
    reward_model in ('fixed_prize_pool', 'per_kill')
  ),
  constraint tournaments_reward_configuration_valid check (
    (
      reward_model = 'fixed_prize_pool'
      and prize_pool_minor is not null
      and prize_pool_minor >= 0
      and per_kill_reward_minor is null
    )
    or (
      reward_model = 'per_kill'
      and prize_pool_minor is null
      and per_kill_reward_minor is not null
      and per_kill_reward_minor > 0
    )
  ),
  constraint tournaments_scoring_config_valid check (
    jsonb_typeof(scoring_config) = 'object'
    and jsonb_typeof(scoring_config -> 'placement_points') = 'object'
    and jsonb_typeof(scoring_config -> 'kill_points_per_kill') = 'number'
    and scoring_config @> '{
      "version": 1,
      "placement_points": {
        "1": 10,
        "2": 6,
        "3": 5,
        "4": 4,
        "5": 3,
        "6": 2,
        "7": 1,
        "8": 1,
        "9": 0,
        "10": 0,
        "11": 0,
        "12": 0,
        "13": 0,
        "14": 0,
        "15": 0,
        "16": 0
      },
      "kill_points_per_kill": 1
    }'::jsonb
  ),
  constraint tournaments_completion_state_valid check (
    (
      status = 'completed'
      and completed_at is not null
      and completed_at >= scheduled_start_at
    )
    or (
      status <> 'completed'
      and completed_at is null
    )
  )
);

comment on table public.tournaments is
  'Persistent tournament definitions. Registrations, matches, results, and standings reference the internal UUID in later migrations.';

comment on column public.tournaments.tournament_id is
  'Permanent public LevelledUp tournament identifier; never reused or changed.';

comment on column public.tournaments.scoring_config is
  'Versioned tournament scoring contract. V1 awards approved placement points and one point per kill.';

comment on column public.tournaments.matches_per_day is
  'Admin-configured positive match count for each tournament day; not a hard-coded tournament type.';

comment on column public.tournaments.number_of_days is
  'Admin-configured positive tournament day count. Total scheduled matches are derived from matches_per_day multiplied by number_of_days.';

comment on column public.tournaments.entry_fee_minor is
  'Entry fee in the smallest currency unit. For PKR, 15000 represents PKR 150.';

comment on column public.tournaments.reward_model is
  'V1 cash reward model. Cash rewards remain independent from leaderboard scoring.';

comment on column public.tournaments.prize_pool_minor is
  'Fixed prize pool in minor units; populated only for fixed_prize_pool tournaments.';

comment on column public.tournaments.per_kill_reward_minor is
  'Cash paid per kill in minor units; never used as leaderboard kill points.';

comment on column public.tournaments.game_mode is
  'PUBG Mobile team format: solo, duo, or squad.';

comment on column public.tournaments.perspective is
  'PUBG Mobile camera perspective: TPP or FPP, stored lowercase.';

create index tournaments_status_start_idx
  on public.tournaments (status, scheduled_start_at);
create index tournaments_registration_window_idx
  on public.tournaments (registration_opens_at, registration_closes_at);

create function public.levelledup_set_tournament_updated_at()
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

alter function public.levelledup_set_tournament_updated_at()
  owner to postgres;

revoke all on function public.levelledup_set_tournament_updated_at()
  from public, anon, authenticated;

create trigger tournaments_set_updated_at
before update on public.tournaments
for each row
execute function public.levelledup_set_tournament_updated_at();

create function public.levelledup_keep_tournament_id()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.tournament_id is distinct from old.tournament_id then
    raise exception 'The permanent LevelledUp Tournament ID cannot be changed.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter function public.levelledup_keep_tournament_id()
  owner to postgres;

revoke all on function public.levelledup_keep_tournament_id()
  from public, anon, authenticated;

create trigger tournaments_keep_tournament_id
before update of tournament_id on public.tournaments
for each row
execute function public.levelledup_keep_tournament_id();

alter table public.tournaments enable row level security;

revoke all on table public.tournaments
  from public, anon, authenticated;
grant select on table public.tournaments
  to authenticated;

create policy "Authenticated users can read non-draft tournaments"
  on public.tournaments
  for select
  to authenticated
  using (status <> 'draft');

commit;
