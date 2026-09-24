begin;

drop policy "Authenticated users can read teams" on public.teams;

create policy "Active team members can read their team"
  on public.teams
  for select
  to authenticated
  using (public.levelledup_is_active_team_member(id));

create function public.levelledup_lookup_team_id(p_team_id text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  normalized_team_id text := upper(btrim(coalesce(p_team_id, '')));
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to look up a team.'
      using errcode = '42501';
  end if;

  if normalized_team_id !~ '^LU-[A-HJ-NP-Z2-9]{6}$' then
    return false;
  end if;

  return exists (
    select 1
    from public.teams
    where teams.team_id = normalized_team_id
  );
end;
$$;

comment on function public.levelledup_lookup_team_id(text) is
  'Authenticated existence-only lookup for a normalized LevelledUp Team ID.';

revoke all on function public.levelledup_lookup_team_id(text)
  from public, anon, authenticated;
grant execute on function public.levelledup_lookup_team_id(text)
  to authenticated;

commit;
