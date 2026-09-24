begin;

create function public.levelledup_public_tournaments()
returns table (
  tournament_id text,
  name text,
  description text,
  status text,
  scheduled_start_at timestamptz,
  scheduled_end_at timestamptz,
  registration_opens_at timestamptz,
  registration_closes_at timestamptz,
  max_team_slots integer,
  matches_per_day integer,
  number_of_days integer,
  game_mode text,
  perspective text,
  entry_fee_minor bigint,
  currency text,
  reward_model text,
  prize_pool_minor bigint,
  per_kill_reward_minor bigint,
  confirmed_team_count bigint
)
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select
    tournaments.tournament_id,
    tournaments.name,
    tournaments.description,
    tournaments.status,
    tournaments.scheduled_start_at,
    tournaments.scheduled_end_at,
    tournaments.registration_opens_at,
    tournaments.registration_closes_at,
    tournaments.max_team_slots,
    tournaments.matches_per_day,
    tournaments.number_of_days,
    tournaments.game_mode,
    tournaments.perspective,
    tournaments.entry_fee_minor,
    tournaments.currency,
    tournaments.reward_model,
    tournaments.prize_pool_minor,
    tournaments.per_kill_reward_minor,
    (
      select count(*)
      from public.tournament_registrations
      where tournament_registrations.tournament_id = tournaments.id
        and tournament_registrations.status = 'confirmed'
    ) as confirmed_team_count
  from public.tournaments
  where tournaments.archived_at is null
    and tournaments.status in (
      'live',
      'registration_open',
      'registration_closed'
    )
  order by tournaments.scheduled_start_at;
$$;

alter function public.levelledup_public_tournaments()
  owner to postgres;

revoke all on function public.levelledup_public_tournaments()
  from public, anon, authenticated;
grant execute on function public.levelledup_public_tournaments()
  to anon, authenticated;

comment on function public.levelledup_public_tournaments() is
  'Existence-independent public tournament projection. Exposes only publishable tournament configuration and aggregate confirmed capacity; never drafts, archived/cancelled/completed tournaments, internal UUIDs, registration identities, rosters, provenance, or credentials.';

commit;
