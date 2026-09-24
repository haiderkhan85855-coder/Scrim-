begin;

drop policy if exists "Team members can read their tournament credits"
  on public.tournament_team_credits;

create function public.levelledup_get_my_tournament_credits()
returns table (
  registration_id uuid,
  amount_minor integer,
  currency text,
  status text,
  tournament_public_id text,
  tournament_name text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to view tournament credits.'
      using errcode = '42501';
  end if;

  return query
  select
    credits.registration_id,
    credits.amount_minor,
    credits.currency,
    credits.status,
    tournaments.tournament_id,
    tournaments.name,
    credits.created_at
  from public.tournament_team_credits as credits
  join public.tournaments as tournaments
    on tournaments.id = credits.tournament_id
  where exists (
    select 1
    from public.team_roster_members as members
    where members.team_id = credits.team_id
      and members.profile_id = auth.uid()
      and members.status = 'active'
  )
  or exists (
    select 1
    from public.tournament_registration_payments as payments
    where payments.id = credits.source_payment_id
      and payments.submitted_by = auth.uid()
  )
  order by credits.created_at desc;
end;
$$;

alter function public.levelledup_get_my_tournament_credits()
  owner to postgres;
revoke all on function public.levelledup_get_my_tournament_credits()
  from public, anon, authenticated;
grant execute on function public.levelledup_get_my_tournament_credits()
  to authenticated;

comment on function public.levelledup_get_my_tournament_credits() is
  'Member-facing cancellation-credit projection. Returns safe credit and tournament fields without payment references or Admin provenance.';

commit;
