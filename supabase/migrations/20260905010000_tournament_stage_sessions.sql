begin;

create table public.tournament_stage_sessions (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null,
  stage_id uuid not null,
  session_number integer not null,
  display_name text not null,
  scheduled_start_at timestamptz,
  scheduled_end_at timestamptz,
  max_concurrent_lobbies integer,
  default_matches_per_lobby integer,
  status text not null default 'planned',
  is_legacy_backfill boolean not null default false,
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_stage_sessions_stage_fk
    foreign key(stage_id,tournament_id)
    references public.tournament_stages(id,tournament_id) on delete restrict,
  constraint tournament_stage_sessions_number_positive check(session_number >= 1),
  constraint tournament_stage_sessions_name_valid check(
    display_name = btrim(display_name) and char_length(display_name) between 2 and 120
  ),
  constraint tournament_stage_sessions_schedule_valid check(
    scheduled_end_at is null
    or (scheduled_start_at is not null and scheduled_end_at >= scheduled_start_at)
  ),
  constraint tournament_stage_sessions_status_valid check(
    status in ('planned','open','live','completed','cancelled')
  ),
  constraint tournament_stage_sessions_concurrency_valid check(
    max_concurrent_lobbies is null or max_concurrent_lobbies > 0
  ),
  constraint tournament_stage_sessions_match_default_valid check(
    default_matches_per_lobby is null or default_matches_per_lobby > 0
  ),
  constraint tournament_stage_sessions_order_unique unique(stage_id,session_number),
  constraint tournament_stage_sessions_scope_unique unique(id,stage_id,tournament_id)
);
create index tournament_stage_sessions_stage_status_idx
  on public.tournament_stage_sessions(stage_id,status,session_number);
comment on table public.tournament_stage_sessions is
  'Stable scheduled competition/attempt units beneath a named Stage. Existing Stage lobbies are adopted into one explicitly marked legacy Session.';
comment on column public.tournament_stage_sessions.max_concurrent_lobbies is
  'Authoritative runtime concurrency limit for this Session. The Stage value is only a legacy template copied when a Session is created.';
comment on column public.tournament_stage_sessions.default_matches_per_lobby is
  'Default Match count for each Lobby in this Session unless that Lobby stores an explicit override.';

create function public.levelledup_set_stage_session_updated_at()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin new.updated_at := now(); return new; end;
$$;
create trigger tournament_stage_sessions_set_updated_at
before update on public.tournament_stage_sessions
for each row execute function public.levelledup_set_stage_session_updated_at();

create function public.levelledup_guard_stage_session_history()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Tournament Session history cannot be deleted.' using errcode='22023';
  end if;
  if new.id is distinct from old.id or new.tournament_id is distinct from old.tournament_id
    or new.stage_id is distinct from old.stage_id or new.session_number is distinct from old.session_number
    or new.is_legacy_backfill is distinct from old.is_legacy_backfill
    or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Tournament Session identity and provenance cannot change.' using errcode='22023';
  end if;
  if new.status is distinct from old.status and not (
    (old.status='planned' and new.status in ('open','cancelled'))
    or (old.status='open' and new.status in ('live','cancelled'))
    or (old.status='live' and new.status in ('completed','cancelled'))
  ) then
    raise exception 'Invalid Tournament Session status transition.' using errcode='22023';
  end if;
  if old.status in ('live','completed','cancelled') and (
    new.display_name is distinct from old.display_name
    or new.scheduled_start_at is distinct from old.scheduled_start_at
    or new.scheduled_end_at is distinct from old.scheduled_end_at
    or new.max_concurrent_lobbies is distinct from old.max_concurrent_lobbies
    or new.default_matches_per_lobby is distinct from old.default_matches_per_lobby
  ) then
    raise exception 'Started or retired Tournament Session configuration is historical.' using errcode='22023';
  end if;
  if new.default_matches_per_lobby is distinct from old.default_matches_per_lobby
    and exists(
      select 1 from public.tournament_lobbies l
      where l.session_id=new.id and l.matches_per_lobby_override is null
        and exists(select 1 from public.tournament_matches m where m.lobby_id=l.id
          and (new.default_matches_per_lobby is null or m.match_number>new.default_matches_per_lobby))
    ) then
    raise exception 'Session default Match count conflicts with existing Lobby Match history.' using errcode='P4103';
  end if;
  return new;
end;
$$;
create trigger tournament_stage_sessions_guard_history
before update or delete on public.tournament_stage_sessions
for each row execute function public.levelledup_guard_stage_session_history();

-- Enrich legacy hierarchy without deleting, renumbering or changing a Lobby,
-- Match, assignment, payment or result identity.
insert into public.tournament_stage_sessions(
  tournament_id,stage_id,session_number,display_name,scheduled_start_at,scheduled_end_at,
  max_concurrent_lobbies,default_matches_per_lobby,status,is_legacy_backfill,created_at
)
select s.tournament_id,s.id,1,s.display_name || ' — Session 1',
  min(m.scheduled_start_at),max(m.scheduled_start_at),
  s.concurrent_lobby_capacity,s.matches_per_lobby,
  case s.status when 'active' then 'live' when 'completed' then 'completed'
    when 'cancelled' then 'cancelled' else 'planned' end,
  true,s.created_at
from public.tournament_stages s
left join public.tournament_lobbies l on l.stage_id=s.id and l.tournament_id=s.tournament_id
left join public.tournament_matches m on m.lobby_id=l.id and m.stage_id=s.id and m.tournament_id=s.tournament_id
group by s.id,s.tournament_id,s.display_name,s.status,s.created_at;

alter table public.tournament_lobbies
  add column session_id uuid,
  add column scheduled_start_at timestamptz,
  add column scheduled_end_at timestamptz,
  add column matches_per_lobby_override integer,
  add column operator_user_id uuid references public.admin_users(user_id) on delete restrict;

update public.tournament_lobbies l set
  session_id=sess.id,
  scheduled_start_at=(select min(m.scheduled_start_at) from public.tournament_matches m where m.lobby_id=l.id),
  scheduled_end_at=(select max(m.scheduled_start_at) from public.tournament_matches m where m.lobby_id=l.id)
from public.tournament_stage_sessions sess
where sess.stage_id=l.stage_id and sess.tournament_id=l.tournament_id and sess.session_number=1;

alter table public.tournament_lobbies
  alter column session_id set not null,
  add constraint tournament_lobbies_session_fk
    foreign key(session_id,stage_id,tournament_id)
    references public.tournament_stage_sessions(id,stage_id,tournament_id) on delete restrict,
  add constraint tournament_lobbies_schedule_valid check(
    scheduled_end_at is null
    or (scheduled_start_at is not null and scheduled_end_at >= scheduled_start_at)
  ),
  add constraint tournament_lobbies_match_override_valid check(
    matches_per_lobby_override is null or matches_per_lobby_override > 0
  ),
  drop constraint tournament_lobbies_order_unique,
  drop constraint tournament_lobbies_code_unique,
  add constraint tournament_lobbies_session_order_unique unique(session_id,lobby_order),
  add constraint tournament_lobbies_session_code_unique unique(session_id,lobby_code);
create index tournament_lobbies_session_status_idx
  on public.tournament_lobbies(session_id,status,lobby_order);
comment on column public.tournament_lobbies.session_id is
  'Owning scheduled Session. Stable for the lifetime of the Lobby.';
comment on column public.tournament_lobbies.operator_user_id is
  'Current active LevelledUp operator; every assignment change is preserved in tournament_lobby_operator_events.';
comment on column public.tournament_lobbies.matches_per_lobby_override is
  'Optional Lobby-local Match count. NULL inherits tournament_stage_sessions.default_matches_per_lobby.';

-- Retain the existing (id,stage_id,tournament_id) key because assignments and
-- matches already reference it; add the richer Session scope alongside it.
alter table public.tournament_lobbies
  add constraint tournament_lobbies_session_scope_unique
  unique(id,session_id,stage_id,tournament_id);

create function public.levelledup_validate_lobby_session_scope()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
declare selected_session public.tournament_stage_sessions; session_count integer;
begin
  if tg_op='UPDATE' and (new.id is distinct from old.id
    or new.tournament_id is distinct from old.tournament_id
    or new.stage_id is distinct from old.stage_id
    or new.session_id is distinct from old.session_id) then
    raise exception 'Lobby identity and owning Tournament, Stage and Session cannot change.' using errcode='22023';
  end if;
  if tg_op='DELETE' then
    raise exception 'Tournament Lobby history cannot be deleted.' using errcode='22023';
  end if;
  if new.session_id is null then
    select count(*)::integer,min(s.id) into session_count,new.session_id
    from public.tournament_stage_sessions s
    where s.stage_id=new.stage_id and s.tournament_id=new.tournament_id;
    if session_count<>1 then
      raise exception 'Choose the exact Tournament Session for this Lobby.' using errcode='22023';
    end if;
  end if;
  select s.* into selected_session from public.tournament_stage_sessions s
  where s.id=new.session_id and s.stage_id=new.stage_id and s.tournament_id=new.tournament_id for share;
  if selected_session.id is null then
    raise exception 'Lobby Session must belong to the same Stage and Tournament.' using errcode='23503';
  end if;
  if tg_op='UPDATE' and new.matches_per_lobby_override is distinct from old.matches_per_lobby_override
    and exists(select 1 from public.tournament_matches m where m.lobby_id=new.id
      and (coalesce(new.matches_per_lobby_override,selected_session.default_matches_per_lobby) is null
        or m.match_number>coalesce(new.matches_per_lobby_override,selected_session.default_matches_per_lobby))) then
    raise exception 'Lobby Match override conflicts with existing Match history.' using errcode='P4103';
  end if;
  return new;
end;
$$;
create trigger tournament_lobbies_00_validate_session_scope
before insert or update or delete
on public.tournament_lobbies for each row
execute function public.levelledup_validate_lobby_session_scope();

create table public.tournament_lobby_operator_events (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null,
  stage_id uuid not null,
  session_id uuid not null,
  lobby_id uuid not null,
  previous_operator_user_id uuid references public.admin_users(user_id) on delete restrict,
  operator_user_id uuid references public.admin_users(user_id) on delete restrict,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  assigned_by_role text not null,
  reason text not null,
  request_id uuid not null unique,
  created_at timestamptz not null default clock_timestamp(),
  constraint tournament_lobby_operator_events_lobby_fk
    foreign key(lobby_id,session_id,stage_id,tournament_id)
    references public.tournament_lobbies(id,session_id,stage_id,tournament_id) on delete restrict,
  constraint tournament_lobby_operator_events_role_valid check(
    assigned_by_role in ('admin','tournament_admin','super_admin')
  ),
  constraint tournament_lobby_operator_events_reason_valid check(
    reason=btrim(reason) and char_length(reason) between 10 and 1000
  ),
  constraint tournament_lobby_operator_events_change_valid check(
    previous_operator_user_id is distinct from operator_user_id
  )
);
create index tournament_lobby_operator_events_lobby_history_idx
  on public.tournament_lobby_operator_events(lobby_id,created_at);
comment on table public.tournament_lobby_operator_events is
  'Immutable audit history for assigning, reassigning or clearing a Lobby operator.';

create function public.levelledup_preserve_lobby_operator_events()
returns trigger language plpgsql security invoker set search_path='' as $$
begin raise exception 'Lobby operator assignment history is append-only.' using errcode='22023'; end;
$$;
create trigger tournament_lobby_operator_events_append_only
before update or delete on public.tournament_lobby_operator_events
for each row execute function public.levelledup_preserve_lobby_operator_events();

create function public.levelledup_require_lobby_operator_audit()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
begin
  if new.operator_user_id is distinct from old.operator_user_id and not exists(
    select 1 from public.tournament_lobby_operator_events e
    where e.lobby_id=new.id
      and e.previous_operator_user_id is not distinct from old.operator_user_id
      and e.operator_user_id is not distinct from new.operator_user_id
      and e.assigned_by=auth.uid()
      and e.created_at>=transaction_timestamp()
  ) then
    raise exception 'Lobby operator changes require the trusted audited Admin operation.' using errcode='42501';
  end if;
  return new;
end;
$$;
create trigger tournament_lobbies_require_operator_audit
before update of operator_user_id on public.tournament_lobbies
for each row execute function public.levelledup_require_lobby_operator_audit();

create function public.levelledup_admin_create_tournament_session(
  p_stage_id uuid,p_display_name text,p_scheduled_start_at timestamptz default null,
  p_scheduled_end_at timestamptz default null
)
returns public.tournament_stage_sessions language plpgsql security definer
set search_path='' set row_security=off as $$
declare stage public.tournament_stages; created public.tournament_stage_sessions; next_number integer;
begin
  perform public.levelledup_require_admin('admin');
  select s.* into stage from public.tournament_stages s where s.id=p_stage_id for update;
  if stage.id is null or stage.status in ('completed','cancelled') then
    raise exception 'An active Tournament Stage is required.' using errcode='22023';
  end if;
  select coalesce(max(s.session_number),0)+1 into next_number
  from public.tournament_stage_sessions s where s.stage_id=stage.id;
  insert into public.tournament_stage_sessions(
    tournament_id,stage_id,session_number,display_name,scheduled_start_at,scheduled_end_at,
    max_concurrent_lobbies,default_matches_per_lobby,created_by
  ) values(stage.tournament_id,stage.id,next_number,btrim(p_display_name),
    p_scheduled_start_at,p_scheduled_end_at,stage.concurrent_lobby_capacity,
    stage.matches_per_lobby,auth.uid()) returning * into created;
  return created;
end;
$$;

create function public.levelledup_admin_configure_tournament_session(
  p_session_id uuid,p_max_concurrent_lobbies integer,
  p_default_matches_per_lobby integer
)
returns public.tournament_stage_sessions language plpgsql security definer
set search_path='' set row_security=off as $$
declare configured public.tournament_stage_sessions;
begin
  perform public.levelledup_require_admin('admin');
  select s.* into configured from public.tournament_stage_sessions s
  where s.id=p_session_id for update;
  if configured.id is null or configured.status in ('live','completed','cancelled') then
    raise exception 'A configurable Tournament Session is required.' using errcode='22023';
  end if;
  update public.tournament_stage_sessions set
    max_concurrent_lobbies=p_max_concurrent_lobbies,
    default_matches_per_lobby=p_default_matches_per_lobby
  where id=configured.id returning * into configured;
  return configured;
end;
$$;

create function public.levelledup_admin_create_session_lobby(
  p_session_id uuid,p_capacity integer default null,p_scheduled_start_at timestamptz default null,
  p_scheduled_end_at timestamptz default null
)
returns public.tournament_lobbies language plpgsql security definer
set search_path='' set row_security=off as $$
declare sess public.tournament_stage_sessions; tournament public.tournaments;
  next_order integer; code text; created public.tournament_lobbies;
begin
  perform public.levelledup_require_admin('admin');
  select s.* into sess from public.tournament_stage_sessions s where s.id=p_session_id for update;
  if sess.id is null or sess.status in ('live','completed','cancelled') then
    raise exception 'A configurable Tournament Session is required.' using errcode='22023';
  end if;
  select t.* into tournament from public.tournaments t where t.id=sess.tournament_id for share;
  select coalesce(max(l.lobby_order),0)+1 into next_order
  from public.tournament_lobbies l where l.session_id=sess.id;
  if next_order>26 then raise exception 'A Session supports at most 26 named Lobbies.' using errcode='22023'; end if;
  code:=chr(64+next_order);
  insert into public.tournament_lobbies(
    tournament_id,stage_id,session_id,lobby_code,display_label,lobby_order,capacity,status,
    scheduled_start_at,scheduled_end_at
  ) values(sess.tournament_id,sess.stage_id,sess.id,code,'Lobby '||code,next_order,
    coalesce(p_capacity,tournament.default_lobby_capacity),'planned',
    p_scheduled_start_at,p_scheduled_end_at) returning * into created;
  return created;
end;
$$;

create function public.levelledup_admin_set_lobby_match_override(
  p_lobby_id uuid,p_matches_per_lobby_override integer
)
returns public.tournament_lobbies language plpgsql security definer
set search_path='' set row_security=off as $$
declare configured public.tournament_lobbies; session_status text;
begin
  perform public.levelledup_require_admin('admin');
  select l.* into configured from public.tournament_lobbies l
  where l.id=p_lobby_id for update;
  select s.status into session_status from public.tournament_stage_sessions s
  where s.id=configured.session_id for share;
  if configured.id is null or session_status in ('live','completed','cancelled')
    or configured.status in ('locked','completed','cancelled') then
    raise exception 'A configurable Tournament Lobby is required.' using errcode='22023';
  end if;
  update public.tournament_lobbies
  set matches_per_lobby_override=p_matches_per_lobby_override
  where id=configured.id returning * into configured;
  return configured;
end;
$$;

-- Runtime Match limits now resolve from Lobby -> Session. Stage values remain
-- templates for creating Sessions and no longer constrain existing history.
drop trigger if exists tournament_stages_15_guard_match_count on public.tournament_stages;
drop function if exists public.levelledup_guard_stage_match_count();
comment on column public.tournament_stages.matches_per_lobby is
  'Legacy/default template copied into new Sessions. Runtime Match limits use the Lobby override or Session default.';
comment on column public.tournament_stages.concurrent_lobby_capacity is
  'Legacy/default template copied into new Sessions. Runtime concurrency belongs to each Session.';

create or replace function public.levelledup_validate_tournament_match()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare
  selected_tournament public.tournaments;
  selected_stage public.tournament_stages;
  configured_match_count bigint;
begin
  if tg_op='UPDATE' and (new.id is distinct from old.id
    or new.tournament_id is distinct from old.tournament_id
    or new.stage_id is distinct from old.stage_id or new.lobby_id is distinct from old.lobby_id) then
    raise exception 'Match identity and owning tournament, stage and lobby cannot change.' using errcode='22023';
  end if;
  select t.* into selected_tournament from public.tournaments t
  where t.id=new.tournament_id for update;
  if selected_tournament.id is null then raise exception 'Tournament not found.' using errcode='P4101'; end if;
  if selected_tournament.status='completed' then
    raise exception 'Matches cannot be changed after tournament completion.' using errcode='P4102';
  end if;
  if tg_op='INSERT' and selected_tournament.status='cancelled' then
    raise exception 'Matches cannot be added to a cancelled tournament.' using errcode='P4102';
  end if;
  select s.* into selected_stage from public.tournament_stages s
  where s.id=new.stage_id and s.tournament_id=new.tournament_id for share;
  select coalesce(l.matches_per_lobby_override,sess.default_matches_per_lobby)
  into configured_match_count
  from public.tournament_lobbies l
  join public.tournament_stage_sessions sess on sess.id=l.session_id
    and sess.stage_id=l.stage_id and sess.tournament_id=l.tournament_id
  where l.id=new.lobby_id and l.stage_id=new.stage_id and l.tournament_id=new.tournament_id;
  if selected_stage.id is null or not found then
    raise exception 'Match must belong to a Lobby, Session and Stage in the same Tournament.' using errcode='23503';
  end if;
  if selected_stage.status in ('completed','cancelled')
    and (tg_op='INSERT' or new.status<>'cancelled') then
    raise exception 'Matches cannot be added or played in a retired stage.' using errcode='P4102';
  end if;
  if tg_op='INSERT' or new.status<>'cancelled' or new.match_number is distinct from old.match_number then
    if configured_match_count is null then
      raise exception 'Configure the Session default or Lobby Match override before scheduling Matches.' using errcode='P4103';
    end if;
    if new.match_number::bigint>configured_match_count then
      raise exception 'Match number exceeds this Lobby effective Match count.' using errcode='P4103';
    end if;
  end if;
  if new.scheduled_start_at<selected_tournament.scheduled_start_at
    or (selected_tournament.scheduled_end_at is not null
      and new.scheduled_start_at>selected_tournament.scheduled_end_at) then
    raise exception 'Match schedule falls outside the tournament schedule.' using errcode='P4104';
  end if;
  if tg_op='INSERT' or new.map_code is distinct from old.map_code then
    if not exists(select 1 from public.pubg_maps where code=new.map_code and is_active) then
      raise exception 'Select an active canonical PUBG map.' using errcode='P4105';
    end if;
  end if;
  if tg_op='INSERT' then
    if new.status<>'scheduled' then raise exception 'A new match must begin as scheduled.' using errcode='P4106'; end if;
  elsif old.status in ('completed','cancelled') then
    raise exception 'Completed and cancelled matches are historically immutable.' using errcode='P4102';
  elsif new.status is distinct from old.status and not (
    (old.status='scheduled' and new.status in ('live','cancelled'))
    or (old.status='live' and new.status in ('completed','cancelled'))
  ) then raise exception 'Invalid match status transition.' using errcode='P4106';
  end if;
  if tg_op='UPDATE' and old.status='live' and (
    new.match_number is distinct from old.match_number
    or new.map_code is distinct from old.map_code
    or new.scheduled_start_at is distinct from old.scheduled_start_at
  ) then raise exception 'Live match identity and schedule cannot be changed.' using errcode='22023';
  end if;
  if new.status='live' and selected_tournament.status<>'live' then
    raise exception 'A match can go live only while its tournament is live.' using errcode='P4107';
  end if;
  if new.status='completed' and selected_tournament.status<>'live' then
    raise exception 'A match can be completed only while its tournament is live.' using errcode='P4107';
  end if;
  if selected_tournament.status='cancelled' and new.status<>'cancelled' then
    raise exception 'Matches in a cancelled tournament must be cancelled.' using errcode='P4107';
  end if;
  if new.status='completed' then new.completed_at:=coalesce(new.completed_at,now());
  else new.completed_at:=null; end if;
  return new;
end;
$$;

create function public.levelledup_admin_assign_lobby_operator(
  p_lobby_id uuid,p_operator_user_id uuid,p_reason text,p_request_id uuid
)
returns public.tournament_lobbies language plpgsql security definer
set search_path='' set row_security=off as $$
declare lobby public.tournament_lobbies; existing public.tournament_lobby_operator_events;
  actor_role text; normalized_reason text:=btrim(coalesce(p_reason,''));
begin
  perform public.levelledup_require_admin('admin');
  if p_request_id is null or char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'Request ID and a 10-1000 character reason are required.' using errcode='22023';
  end if;
  select e.* into existing from public.tournament_lobby_operator_events e where e.request_id=p_request_id;
  if existing.id is not null then
    if existing.lobby_id<>p_lobby_id or existing.operator_user_id is distinct from p_operator_user_id
      or existing.assigned_by<>auth.uid() or existing.reason<>normalized_reason then
      raise exception 'Request ID is already used for another operator action.' using errcode='23505';
    end if;
    select l.* into lobby from public.tournament_lobbies l where l.id=p_lobby_id;
    return lobby;
  end if;
  select l.* into lobby from public.tournament_lobbies l where l.id=p_lobby_id for update;
  if lobby.id is null then raise exception 'Tournament Lobby not found.' using errcode='22023'; end if;
  if p_operator_user_id is not null and not exists(
    select 1 from public.admin_users a where a.user_id=p_operator_user_id and a.is_active
      and a.role in ('tournament_admin','super_admin')
  ) then raise exception 'Operator must be an active Tournament Admin or Super Admin.' using errcode='22023'; end if;
  if lobby.operator_user_id is not distinct from p_operator_user_id then return lobby; end if;
  actor_role:=public.levelledup_current_admin_role();
  insert into public.tournament_lobby_operator_events(
    tournament_id,stage_id,session_id,lobby_id,previous_operator_user_id,operator_user_id,
    assigned_by,assigned_by_role,reason,request_id
  ) values(lobby.tournament_id,lobby.stage_id,lobby.session_id,lobby.id,lobby.operator_user_id,
    p_operator_user_id,auth.uid(),actor_role,normalized_reason,p_request_id);
  update public.tournament_lobbies set operator_user_id=p_operator_user_id
  where id=lobby.id returning * into lobby;
  return lobby;
end;
$$;

-- Existing lobby creators remain compatible only while their Stage has one
-- Session. Once multiple Sessions exist they fail closed instead of attaching
-- a Lobby to an arbitrary attempt.

create function public.levelledup_admin_get_stage_session_setup_checks(p_tournament_id uuid)
returns table(
  stage_id uuid,stage_name text,session_id uuid,session_name text,
  setup_complete boolean,issues text[],lobby_checks jsonb
)
language plpgsql stable security definer set search_path='' set row_security=off as $$
declare s public.tournament_stages; sess public.tournament_stage_sessions;
  issues text[]; lobby_details jsonb; lobby_count integer;
begin
  perform public.levelledup_require_admin('admin');
  for s in select st.* from public.tournament_stages st where st.tournament_id=p_tournament_id order by st.stage_number loop
    if not exists(select 1 from public.tournament_stage_sessions x where x.stage_id=s.id) then
      return query select s.id,s.display_name,null::uuid,null::text,false,array['sessions_missing']::text[],'[]'::jsonb;
    end if;
    for sess in select x.* from public.tournament_stage_sessions x where x.stage_id=s.id order by x.session_number loop
      issues:='{}'::text[]; lobby_details:='[]'::jsonb;
      if sess.scheduled_start_at is null then issues:=array_append(issues,'session_schedule_missing'); end if;
      if sess.max_concurrent_lobbies is null then issues:=array_append(issues,'max_concurrent_lobbies_missing'); end if;
      if s.advancement_count is null or (s.advancement_count>0 and coalesce(s.advancement_rule,'{}'::jsonb)='{}'::jsonb) then
        issues:=array_append(issues,'advancement_configuration_missing');
      end if;
      select count(*)::integer into lobby_count from public.tournament_lobbies l
      where l.session_id=sess.id and l.status<>'cancelled';
      if lobby_count=0 then issues:=array_append(issues,'lobbies_missing'); end if;
      select coalesce(jsonb_agg(jsonb_build_object(
        'lobby_id',l.id,'lobby_label',l.display_label,'scheduled_start_at',l.scheduled_start_at,
        'operator_assigned',l.operator_user_id is not null,'match_count',coalesce(mc.match_count,0),
        'matches_per_lobby_override',l.matches_per_lobby_override,
        'effective_matches_per_lobby',coalesce(l.matches_per_lobby_override,sess.default_matches_per_lobby),
        'issues',array_remove(array[
          case when l.scheduled_start_at is null then 'lobby_schedule_missing' end,
          case when l.operator_user_id is null then 'operator_missing' end,
          case when coalesce(l.matches_per_lobby_override,sess.default_matches_per_lobby) is null then 'effective_match_count_missing' end,
          case when coalesce(mc.match_count,0)<>coalesce(l.matches_per_lobby_override,sess.default_matches_per_lobby) then 'matches_incomplete' end,
          case when coalesce(ac.assignment_count,0)=0 then 'assignments_missing' end
        ],null)
      ) order by l.lobby_order),'[]'::jsonb),
      coalesce(array_agg(distinct issue) filter(where issue is not null),'{}'::text[])
      into lobby_details,issues
      from public.tournament_lobbies l
      left join lateral(select count(*)::integer match_count from public.tournament_matches m
        where m.lobby_id=l.id and m.status<>'cancelled') mc on true
      left join lateral(select count(*)::integer assignment_count from public.tournament_stage_assignments a
        where a.lobby_id=l.id and a.status='assigned') ac on true
      left join lateral unnest(array[
        case when l.scheduled_start_at is null then 'lobby_schedule_missing' end,
        case when l.operator_user_id is null then 'operator_missing' end,
        case when coalesce(l.matches_per_lobby_override,sess.default_matches_per_lobby) is null then 'effective_match_count_missing' end,
        case when coalesce(mc.match_count,0)<>coalesce(l.matches_per_lobby_override,sess.default_matches_per_lobby) then 'matches_incomplete' end,
        case when coalesce(ac.assignment_count,0)=0 then 'assignments_missing' end
      ]) issue on true
      where l.session_id=sess.id and l.status<>'cancelled';
      if sess.scheduled_start_at is null then issues:=array_append(issues,'session_schedule_missing'); end if;
      if sess.max_concurrent_lobbies is null then issues:=array_append(issues,'max_concurrent_lobbies_missing'); end if;
      if s.advancement_count is null or (s.advancement_count>0 and coalesce(s.advancement_rule,'{}'::jsonb)='{}'::jsonb) then
        issues:=array_append(issues,'advancement_configuration_missing');
      end if;
      if lobby_count=0 then issues:=array_append(issues,'lobbies_missing'); end if;
      if sess.max_concurrent_lobbies is not null and exists(
        select 1 from public.tournament_matches m
        join public.tournament_lobbies l on l.id=m.lobby_id
        where l.session_id=sess.id and l.status<>'cancelled' and m.status<>'cancelled'
        group by m.scheduled_start_at
        having count(distinct m.lobby_id)>sess.max_concurrent_lobbies
      ) then issues:=array_append(issues,'concurrent_lobby_starts_exceed_limit'); end if;
      select coalesce(array_agg(distinct x order by x),'{}'::text[]) into issues from unnest(issues) x;
      return query select s.id,s.display_name,sess.id,sess.display_name,cardinality(issues)=0,issues,lobby_details;
    end loop;
  end loop;
end;
$$;

-- Preserve the legacy Admin readiness RPC signatures, but make their computed
-- state Session-aware. Stage-level Match/concurrency values remain visible as
-- templates only and never drive runtime readiness.
create or replace function public.levelledup_admin_get_stage_setup(p_tournament_id uuid)
returns table (
  stage_id uuid, stage_name text, stage_number integer, stage_status text,
  planned_lobby_count integer, matches_per_lobby integer, concurrent_lobby_capacity integer,
  advancement_count integer, advancement_rule jsonb, configuration_ready boolean,
  actual_lobby_count bigint, scheduled_lobby_count bigint, setup_state text
)
language plpgsql stable security definer set search_path = '' set row_security = off as $$
begin
  perform public.levelledup_require_admin('admin');
  return query
  select stage.id, stage.display_name, stage.stage_number, stage.status,
    stage.planned_lobby_count, counts.default_matches_per_lobby,
    counts.max_concurrent_lobbies,
    stage.advancement_count, stage.advancement_rule, stage.configuration_ready,
    counts.lobbies, counts.scheduled,
    case
      when not stage.configuration_ready then 'configuration_incomplete'
      when counts.sessions = 0 or counts.unconfigured_sessions > 0 then 'planning_incomplete'
      when stage.planned_lobby_count is not null and counts.lobbies <> stage.planned_lobby_count
        then 'lobbies_incomplete'
      when counts.scheduled <> counts.lobbies then 'matches_incomplete'
      else 'ready'
    end
  from public.tournament_stages stage
  cross join lateral (
    select
      (select count(*) from public.tournament_stage_sessions sess
        where sess.stage_id = stage.id and sess.status <> 'cancelled') as sessions,
      (select count(*) from public.tournament_stage_sessions sess
        where sess.stage_id = stage.id and sess.status <> 'cancelled'
          and (sess.max_concurrent_lobbies is null
            or sess.default_matches_per_lobby is null)) as unconfigured_sessions,
      (select case when count(distinct sess.default_matches_per_lobby) = 1
          then min(sess.default_matches_per_lobby) end
        from public.tournament_stage_sessions sess
        where sess.stage_id = stage.id and sess.status <> 'cancelled') as default_matches_per_lobby,
      (select case when count(distinct sess.max_concurrent_lobbies) = 1
          then min(sess.max_concurrent_lobbies) end
        from public.tournament_stage_sessions sess
        where sess.stage_id = stage.id and sess.status <> 'cancelled') as max_concurrent_lobbies,
      count(*) filter (where lobby.id is not null) as lobbies,
      count(*) filter (
        where lobby.id is not null
          and effective.match_count is not null
          and schedule.match_count = effective.match_count
          and schedule.last_number = effective.match_count
          and schedule.scheduled_count = effective.match_count
      ) as scheduled
    from public.tournament_stage_sessions sess
    left join public.tournament_lobbies lobby
      on lobby.session_id = sess.id and lobby.status <> 'cancelled'
    left join lateral (
      select coalesce(lobby.matches_per_lobby_override,
        sess.default_matches_per_lobby)::bigint as match_count
    ) effective on true
    left join lateral (
      select count(*)::bigint as match_count, max(match.match_number)::bigint as last_number,
        count(match.scheduled_start_at)::bigint as scheduled_count
      from public.tournament_matches match
      where match.lobby_id = lobby.id and match.status <> 'cancelled'
    ) schedule on true
    where sess.stage_id = stage.id and sess.status <> 'cancelled'
  ) counts
  where stage.tournament_id = p_tournament_id
  order by stage.stage_number;
end;
$$;

create or replace function public.levelledup_admin_get_stage_setup_checks(p_tournament_id uuid)
returns table (
  stage_id uuid, stage_name text, stage_number integer, max_concurrent_lobbies integer,
  setup_complete boolean, issues text[], lobby_checks jsonb
)
language plpgsql stable security definer set search_path = '' set row_security = off as $$
begin
  perform public.levelledup_require_admin('admin');
  return query
  select stage.id, stage.display_name, stage.stage_number,
    case when count(distinct sess.max_concurrent_lobbies) = 1
      then min(sess.max_concurrent_lobbies) end,
    coalesce(bool_and(checks.setup_complete), false),
    coalesce((
      select array_agg(distinct issue order by issue)
      from public.levelledup_admin_get_stage_session_setup_checks(p_tournament_id) detail
      cross join lateral unnest(detail.issues) issue
      where detail.stage_id = stage.id
    ), '{}'::text[]),
    coalesce(jsonb_agg(jsonb_build_object(
      'session_id', checks.session_id,
      'session_name', checks.session_name,
      'max_concurrent_lobbies', sess.max_concurrent_lobbies,
      'default_matches_per_lobby', sess.default_matches_per_lobby,
      'setup_complete', checks.setup_complete,
      'issues', checks.issues,
      'lobbies', checks.lobby_checks
    ) order by sess.session_number) filter (where checks.session_id is not null), '[]'::jsonb)
  from public.tournament_stages stage
  left join public.levelledup_admin_get_stage_session_setup_checks(p_tournament_id) checks
    on checks.stage_id = stage.id
  left join public.tournament_stage_sessions sess on sess.id = checks.session_id
  where stage.tournament_id = p_tournament_id
  group by stage.id, stage.display_name, stage.stage_number
  order by stage.stage_number;
end;
$$;

comment on function public.levelledup_admin_get_stage_setup(uuid) is
  'Compatibility setup summary. Match completeness resolves each Lobby override before its owning Session default; Stage Match/concurrency columns are templates only.';
comment on function public.levelledup_admin_get_stage_setup_checks(uuid) is
  'Compatibility Stage diagnostic aggregating authoritative per-Session readiness. Mixed Session concurrency is represented by NULL in the legacy scalar field and detailed per Session in lobby_checks.';

alter table public.tournament_stage_sessions enable row level security;
alter table public.tournament_lobby_operator_events enable row level security;
revoke all on table public.tournament_stage_sessions,public.tournament_lobby_operator_events
  from public,anon,authenticated;
grant select(id,tournament_id,stage_id,session_number,display_name,scheduled_start_at,
  scheduled_end_at,max_concurrent_lobbies,default_matches_per_lobby,status,
  is_legacy_backfill,created_at,updated_at)
  on public.tournament_stage_sessions to authenticated;
grant select on table public.tournament_lobby_operator_events to authenticated;
create policy tournament_stage_sessions_authorized_read on public.tournament_stage_sessions
  for select to authenticated using(
    public.levelledup_has_admin_role('admin')
    or public.levelledup_stage_visible_to_player(stage_id)
  );
create policy tournament_lobby_operator_events_admin_read on public.tournament_lobby_operator_events
  for select to authenticated using(public.levelledup_has_admin_role('admin'));

alter function public.levelledup_set_stage_session_updated_at() owner to postgres;
alter function public.levelledup_guard_stage_session_history() owner to postgres;
alter function public.levelledup_validate_lobby_session_scope() owner to postgres;
alter function public.levelledup_preserve_lobby_operator_events() owner to postgres;
alter function public.levelledup_require_lobby_operator_audit() owner to postgres;
alter function public.levelledup_admin_create_tournament_session(uuid,text,timestamptz,timestamptz) owner to postgres;
alter function public.levelledup_admin_configure_tournament_session(uuid,integer,integer) owner to postgres;
alter function public.levelledup_admin_create_session_lobby(uuid,integer,timestamptz,timestamptz) owner to postgres;
alter function public.levelledup_admin_set_lobby_match_override(uuid,integer) owner to postgres;
alter function public.levelledup_admin_assign_lobby_operator(uuid,uuid,text,uuid) owner to postgres;
alter function public.levelledup_admin_get_stage_session_setup_checks(uuid) owner to postgres;
alter function public.levelledup_admin_get_stage_setup(uuid) owner to postgres;
alter function public.levelledup_admin_get_stage_setup_checks(uuid) owner to postgres;
revoke all on function public.levelledup_set_stage_session_updated_at(),
  public.levelledup_guard_stage_session_history(),public.levelledup_validate_lobby_session_scope(),
  public.levelledup_preserve_lobby_operator_events(),public.levelledup_require_lobby_operator_audit(),
  public.levelledup_admin_create_tournament_session(uuid,text,timestamptz,timestamptz),
  public.levelledup_admin_configure_tournament_session(uuid,integer,integer),
  public.levelledup_admin_create_session_lobby(uuid,integer,timestamptz,timestamptz),
  public.levelledup_admin_set_lobby_match_override(uuid,integer),
  public.levelledup_admin_assign_lobby_operator(uuid,uuid,text,uuid),
  public.levelledup_admin_get_stage_session_setup_checks(uuid),
  public.levelledup_admin_get_stage_setup(uuid),
  public.levelledup_admin_get_stage_setup_checks(uuid)
  from public,anon,authenticated;
grant execute on function public.levelledup_admin_create_tournament_session(uuid,text,timestamptz,timestamptz),
  public.levelledup_admin_configure_tournament_session(uuid,integer,integer),
  public.levelledup_admin_create_session_lobby(uuid,integer,timestamptz,timestamptz),
  public.levelledup_admin_set_lobby_match_override(uuid,integer),
  public.levelledup_admin_assign_lobby_operator(uuid,uuid,text,uuid),
  public.levelledup_admin_get_stage_session_setup_checks(uuid),
  public.levelledup_admin_get_stage_setup(uuid),
  public.levelledup_admin_get_stage_setup_checks(uuid) to authenticated;

comment on column public.tournament_matches.match_number is
  'Stable Match order local to its owning Lobby. Effective cap is Lobby override then Session default; Stage/tournament-wide totals are not runtime-authoritative.';

commit;
