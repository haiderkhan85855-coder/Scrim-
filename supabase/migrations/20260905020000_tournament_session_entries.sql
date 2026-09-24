begin;

-- A Session Entry is the stable participation identity. Payments, credits,
-- results and assignments are evidence or consumers of the right; none of
-- them is the identity itself.
create table public.tournament_session_entries (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null,
  stage_id uuid not null,
  session_id uuid not null,
  registration_id uuid not null,
  team_id uuid not null,
  source_type text not null,
  source_paid_entry_id uuid references public.tournament_registration_paid_entries(id) on delete restrict,
  earned_from_session_entry_id uuid references public.tournament_session_entries(id) on delete restrict,
  qualification_event_id uuid,
  source_credit_ledger_entry_id uuid references public.levelledup_credit_ledger_entries(id) on delete restrict,
  source_occurred_at timestamptz not null,
  source_provenance jsonb not null default '{}'::jsonb,
  reason text not null,
  request_id uuid not null unique,
  status text not null default 'active',
  is_legacy_backfill boolean not null default false,
  created_by uuid references auth.users(id) on delete restrict,
  created_by_role text not null,
  created_at timestamptz not null default now(),
  cancelled_by uuid references auth.users(id) on delete restrict,
  cancelled_at timestamptz,
  cancellation_reason text,
  cancellation_request_id uuid unique,
  constraint tournament_session_entries_session_fk
    foreign key(session_id,stage_id,tournament_id)
    references public.tournament_stage_sessions(id,stage_id,tournament_id) on delete restrict,
  constraint tournament_session_entries_registration_fk
    foreign key(registration_id,tournament_id,team_id)
    references public.tournament_registrations(id,tournament_id,team_id) on delete restrict,
  constraint tournament_session_entries_source_valid check(
    source_type in ('paid','earned','credit','admin_grant')
  ),
  constraint tournament_session_entries_source_exactly_one check(
    (source_type='paid' and source_paid_entry_id is not null
      and earned_from_session_entry_id is null and source_credit_ledger_entry_id is null)
    or (source_type='earned' and source_paid_entry_id is null
      and earned_from_session_entry_id is not null and source_credit_ledger_entry_id is null)
    or (source_type='credit' and source_paid_entry_id is null
      and earned_from_session_entry_id is null and source_credit_ledger_entry_id is not null)
    or (source_type='admin_grant' and source_paid_entry_id is null
      and earned_from_session_entry_id is null and source_credit_ledger_entry_id is null)
  ),
  constraint tournament_session_entries_status_valid check(status in ('active','cancelled')),
  constraint tournament_session_entries_role_valid check(
    created_by_role in ('system','admin','tournament_admin','super_admin')
  ),
  constraint tournament_session_entries_reason_valid check(
    reason=btrim(reason) and char_length(reason) between 10 and 1000
  ),
  constraint tournament_session_entries_provenance_object check(
    jsonb_typeof(source_provenance)='object'
  ),
  constraint tournament_session_entries_qualification_event_reserved check(
    qualification_event_id is null
  ),
  constraint tournament_session_entries_cancellation_state check(
    (status='active' and cancelled_by is null and cancelled_at is null
      and cancellation_reason is null and cancellation_request_id is null)
    or (status='cancelled' and cancelled_at is not null
      and cancellation_reason=btrim(cancellation_reason)
      and char_length(cancellation_reason) between 10 and 1000
      and cancellation_request_id is not null)
  ),
  constraint tournament_session_entries_scope_unique
    unique(id,session_id,stage_id,tournament_id,registration_id)
);
create unique index tournament_session_entries_one_active_registration_session_idx
  on public.tournament_session_entries(registration_id,session_id) where status='active';
create unique index tournament_session_entries_paid_source_unique
  on public.tournament_session_entries(source_paid_entry_id) where source_paid_entry_id is not null;
create unique index tournament_session_entries_credit_source_unique
  on public.tournament_session_entries(source_credit_ledger_entry_id)
  where source_credit_ledger_entry_id is not null;
create index tournament_session_entries_session_status_idx
  on public.tournament_session_entries(session_id,status,created_at);
comment on table public.tournament_session_entries is
  'Stable right for one registration/team to participate in one exact Tournament Session. Source evidence is immutable and is not the participation identity.';
comment on column public.tournament_session_entries.earned_from_session_entry_id is
  'Prior participation provenance only; it is not proof of qualification.';
comment on column public.tournament_session_entries.qualification_event_id is
  'Reserved for a future immutable advancement/qualification event FK. Must remain NULL until that model exists.';
comment on column public.tournament_session_entries.source_credit_ledger_entry_id is
  'Immutable applied-credit ledger row. Its related grant retains the original owner_profile_id/payer and operational team provenance.';

-- Existing assignment history becomes explicit Session participation without
-- changing an assignment ID, Lobby ID, registration ID or timestamp.
insert into public.tournament_session_entries(
  tournament_id,stage_id,session_id,registration_id,team_id,source_type,
  source_occurred_at,source_provenance,reason,request_id,status,is_legacy_backfill,
  created_by,created_by_role,created_at,cancelled_by,cancelled_at,
  cancellation_reason,cancellation_request_id
)
select a.tournament_id,a.stage_id,l.session_id,a.registration_id,r.team_id,'admin_grant',
  min(a.assigned_at),
  jsonb_build_object('legacy_assignment_ids',jsonb_agg(a.id order by a.created_at,a.id)),
  'Legacy Session participation reconstructed from preserved Lobby assignment history.',
  gen_random_uuid(),
  case when bool_or(a.status='assigned') then 'active' else 'cancelled' end,
  true,(array_agg(a.assigned_by order by a.assigned_at,a.id))[1],'system',min(a.created_at),
  null,
  case when bool_or(a.status='assigned') then null else max(a.released_at) end,
  case when bool_or(a.status='assigned') then null
    else 'Legacy Session participation was already released before Session Entries existed.' end,
  case when bool_or(a.status='assigned') then null else gen_random_uuid() end
from public.tournament_stage_assignments a
join public.tournament_lobbies l
  on l.id=a.lobby_id and l.stage_id=a.stage_id and l.tournament_id=a.tournament_id
join public.tournament_registrations r
  on r.id=a.registration_id and r.tournament_id=a.tournament_id
group by a.tournament_id,a.stage_id,l.session_id,a.registration_id,r.team_id;

alter table public.tournament_stage_assignments
  add column session_id uuid,
  add column session_entry_id uuid;
alter table public.tournament_stage_assignments
  disable trigger tournament_stage_assignments_set_updated_at;
update public.tournament_stage_assignments a set
  session_id=l.session_id,
  session_entry_id=e.id
from public.tournament_lobbies l,public.tournament_session_entries e
where l.id=a.lobby_id and l.stage_id=a.stage_id and l.tournament_id=a.tournament_id
  and e.session_id=l.session_id and e.stage_id=a.stage_id
  and e.tournament_id=a.tournament_id and e.registration_id=a.registration_id
  and e.is_legacy_backfill;
alter table public.tournament_stage_assignments
  enable trigger tournament_stage_assignments_set_updated_at;
alter table public.tournament_stage_assignments
  alter column session_id set not null,
  alter column session_entry_id set not null,
  add constraint tournament_stage_assignments_lobby_session_fk
    foreign key(lobby_id,session_id,stage_id,tournament_id)
    references public.tournament_lobbies(id,session_id,stage_id,tournament_id) on delete restrict,
  add constraint tournament_stage_assignments_session_entry_fk
    foreign key(session_entry_id,session_id,stage_id,tournament_id,registration_id)
    references public.tournament_session_entries(id,session_id,stage_id,tournament_id,registration_id)
    on delete restrict;
drop index public.tournament_stage_assignments_active_registration_stage_idx;
create unique index tournament_stage_assignments_active_registration_session_idx
  on public.tournament_stage_assignments(registration_id,session_id) where status='assigned';
create unique index tournament_stage_assignments_one_active_per_session_entry_idx
  on public.tournament_stage_assignments(session_entry_id) where status='assigned';
comment on column public.tournament_stage_assignments.session_entry_id is
  'Authoritative participation right consumed by this Lobby assignment; one active assignment per Session Entry.';

create function public.levelledup_validate_assignment_session_entry()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare selected_session_id uuid; selected_entry public.tournament_session_entries;
begin
  select l.session_id into selected_session_id from public.tournament_lobbies l
  where l.id=new.lobby_id and l.stage_id=new.stage_id and l.tournament_id=new.tournament_id;
  if selected_session_id is null then
    raise exception 'Lobby assignment requires a Lobby in an exact Tournament Session.' using errcode='23503';
  end if;
  new.session_id:=selected_session_id;
  if new.session_entry_id is null then
    select e.* into selected_entry from public.tournament_session_entries e
    where e.registration_id=new.registration_id and e.session_id=new.session_id and e.status='active';
    new.session_entry_id:=selected_entry.id;
  else
    select e.* into selected_entry from public.tournament_session_entries e
    where e.id=new.session_entry_id;
  end if;
  if selected_entry.id is null or selected_entry.status<>'active'
    or selected_entry.registration_id<>new.registration_id
    or selected_entry.tournament_id<>new.tournament_id
    or selected_entry.stage_id<>new.stage_id
    or selected_entry.session_id<>new.session_id then
    raise exception 'Lobby assignment requires the active Session Entry for the same registration and Session.'
      using errcode='23503';
  end if;
  return new;
end;
$$;
create trigger tournament_stage_assignments_01_session_entry_scope
before insert or update of tournament_id,stage_id,lobby_id,registration_id,session_id,session_entry_id,status
on public.tournament_stage_assignments for each row
execute function public.levelledup_validate_assignment_session_entry();

-- Correct the historical Lobby-proxy meaning of entry_scope=session. Existing
-- rows retain their Lobby and ID, are marked legacy, and gain the real Session.
alter table public.tournament_registration_paid_entries
  add column session_id uuid,
  add column is_legacy_session_proxy boolean not null default false;
alter table public.tournament_registration_paid_entries
  disable trigger tournament_paid_entries_updated_at;
update public.tournament_registration_paid_entries p set
  session_id=l.session_id,is_legacy_session_proxy=true
from public.tournament_lobbies l
where p.entry_scope='session' and p.lobby_id=l.id
  and p.stage_id=l.stage_id and p.tournament_id=l.tournament_id;
alter table public.tournament_registration_paid_entries
  enable trigger tournament_paid_entries_updated_at;
do $$ begin
  if exists(select 1 from public.tournament_registration_paid_entries
    where entry_scope='session' and session_id is null) then
    raise exception 'A legacy session paid entry has no owning Tournament Session.';
  end if;
end $$;
alter table public.tournament_registration_paid_entries
  drop constraint tournament_registration_paid_entries_scope_valid,
  add constraint tournament_paid_entries_session_fk
    foreign key(session_id,stage_id,tournament_id)
    references public.tournament_stage_sessions(id,stage_id,tournament_id) on delete restrict,
  add constraint tournament_paid_entries_lobby_session_fk
    foreign key(lobby_id,session_id,stage_id,tournament_id)
    references public.tournament_lobbies(id,session_id,stage_id,tournament_id) on delete restrict,
  add constraint tournament_registration_paid_entries_scope_valid check(
    (entry_scope='stage' and session_id is null and lobby_id is null
      and not is_legacy_session_proxy)
    or (entry_scope='session' and session_id is not null
      and (not is_legacy_session_proxy or lobby_id is not null))
  );
create unique index tournament_paid_entries_exact_session_scope_unique
  on public.tournament_registration_paid_entries(registration_id,session_id)
  where entry_scope='session' and not is_legacy_session_proxy;
comment on column public.tournament_registration_paid_entries.session_id is
  'Exact paid Session. NULL only for Stage-wide entries; Lobby is optional routing/history and is never the Session identity.';
comment on column public.tournament_registration_paid_entries.is_legacy_session_proxy is
  'True only for preserved pre-Session rows whose old session scope used Lobby as a proxy.';

alter table public.tournament_stage_refund_cases add column session_id uuid;
alter table public.tournament_stage_refund_cases
  disable trigger tournament_stage_refund_cases_updated_at;
update public.tournament_stage_refund_cases c set session_id=p.session_id
from public.tournament_registration_paid_entries p where p.id=c.paid_entry_id;
alter table public.tournament_stage_refund_cases
  enable trigger tournament_stage_refund_cases_updated_at;
alter table public.tournament_stage_refund_cases
  add constraint tournament_stage_refund_cases_session_fk
    foreign key(session_id,stage_id,tournament_id)
    references public.tournament_stage_sessions(id,stage_id,tournament_id) on delete restrict,
  add constraint tournament_stage_refund_cases_lobby_session_fk
    foreign key(lobby_id,session_id,stage_id,tournament_id)
    references public.tournament_lobbies(id,session_id,stage_id,tournament_id) on delete restrict;

alter table public.tournament_stage_credit_entitlements
  add column stage_id uuid,
  add column session_id uuid;
alter table public.tournament_stage_credit_entitlements
  disable trigger tournament_stage_credit_entitlements_updated_at;
update public.tournament_stage_credit_entitlements c set
  stage_id=p.stage_id,session_id=p.session_id
from public.tournament_registration_paid_entries p where p.id=c.paid_entry_id;
alter table public.tournament_stage_credit_entitlements
  enable trigger tournament_stage_credit_entitlements_updated_at;
alter table public.tournament_stage_credit_entitlements
  alter column stage_id set not null,
  add constraint tournament_stage_credit_entitlements_stage_fk
    foreign key(stage_id,tournament_id)
    references public.tournament_stages(id,tournament_id) on delete restrict,
  add constraint tournament_stage_credit_entitlements_session_fk
    foreign key(session_id,stage_id,tournament_id)
    references public.tournament_stage_sessions(id,stage_id,tournament_id) on delete restrict;
comment on column public.tournament_stage_refund_cases.session_id is
  'Exact refunded Session copied from the immutable paid entry; NULL only for Stage-wide entries.';
comment on column public.tournament_stage_credit_entitlements.session_id is
  'Exact credited Session copied through the refund case and paid entry; NULL only for Stage-wide entries.';

create function public.levelledup_validate_paid_entry_session_scope()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
begin
  if new.entry_scope='stage' then
    if new.session_id is not null or new.lobby_id is not null then
      raise exception 'A Stage paid entry cannot identify a Session or Lobby.' using errcode='22023';
    end if;
  elsif new.entry_scope='session' then
    if new.session_id is null or not exists(select 1 from public.tournament_stage_sessions s
      where s.id=new.session_id and s.stage_id=new.stage_id and s.tournament_id=new.tournament_id) then
      raise exception 'A Session paid entry requires its exact Session in the same Stage and Tournament.'
        using errcode='23503';
    end if;
    if new.lobby_id is not null and not exists(select 1 from public.tournament_lobbies l
      where l.id=new.lobby_id and l.session_id=new.session_id
        and l.stage_id=new.stage_id and l.tournament_id=new.tournament_id) then
      raise exception 'Paid-entry Lobby must belong to its exact Session.' using errcode='23503';
    end if;
  else raise exception 'Paid-entry scope must be stage or session.' using errcode='22023';
  end if;
  return new;
end;
$$;
create trigger tournament_paid_entries_00_validate_session_scope
before insert or update on public.tournament_registration_paid_entries for each row
execute function public.levelledup_validate_paid_entry_session_scope();

create function public.levelledup_validate_refund_session_scope()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare p public.tournament_registration_paid_entries;
begin
  select x.* into p from public.tournament_registration_paid_entries x where x.id=new.paid_entry_id;
  if p.id is null then raise exception 'Refund case paid entry not found.' using errcode='23503'; end if;
  if new.session_id is null then new.session_id:=p.session_id; end if;
  if new.registration_id<>p.registration_id or new.tournament_id<>p.tournament_id
    or new.team_id<>p.team_id or new.stage_id<>p.stage_id
    or new.session_id is distinct from p.session_id or new.lobby_id is distinct from p.lobby_id
    or new.source_payment_id<>p.source_payment_id or new.amount_minor<>p.amount_minor
    or new.currency<>p.currency then
    raise exception 'Refund case must preserve the exact paid-entry Tournament, Stage and Session identity.'
      using errcode='23503';
  end if;
  return new;
end;
$$;
create trigger tournament_stage_refund_cases_00_validate_session_scope
before insert or update on public.tournament_stage_refund_cases for each row
execute function public.levelledup_validate_refund_session_scope();

create function public.levelledup_validate_credit_session_scope()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare p public.tournament_registration_paid_entries; c public.tournament_stage_refund_cases;
begin
  select x.* into p from public.tournament_registration_paid_entries x where x.id=new.paid_entry_id;
  select x.* into c from public.tournament_stage_refund_cases x where x.id=new.refund_case_id;
  if p.id is null or c.id is null then
    raise exception 'Stage credit requires its paid entry and refund case.' using errcode='23503';
  end if;
  if new.stage_id is null then new.stage_id:=p.stage_id; end if;
  if new.session_id is null then new.session_id:=p.session_id; end if;
  if c.paid_entry_id<>p.id or new.registration_id<>p.registration_id
    or new.tournament_id<>p.tournament_id or new.team_id<>p.team_id
    or new.stage_id<>p.stage_id or new.session_id is distinct from p.session_id
    or c.session_id is distinct from p.session_id
    or new.source_payment_id<>p.source_payment_id or new.amount_minor<>p.amount_minor
    or new.currency<>p.currency then
    raise exception 'Stage credit must preserve the exact refund and paid-entry Session identity.'
      using errcode='23503';
  end if;
  return new;
end;
$$;
create trigger tournament_stage_credit_entitlements_00_validate_session_scope
before insert or update on public.tournament_stage_credit_entitlements for each row
execute function public.levelledup_validate_credit_session_scope();

create or replace function public.levelledup_guard_paid_entry_history()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if tg_op='DELETE' then raise exception 'Paid-entry history cannot be deleted.' using errcode='22023'; end if;
  if new.registration_id is distinct from old.registration_id
    or new.tournament_id is distinct from old.tournament_id or new.team_id is distinct from old.team_id
    or new.stage_id is distinct from old.stage_id or new.session_id is distinct from old.session_id
    or new.lobby_id is distinct from old.lobby_id or new.entry_scope is distinct from old.entry_scope
    or new.is_legacy_session_proxy is distinct from old.is_legacy_session_proxy
    or new.source_payment_id is distinct from old.source_payment_id
    or new.amount_minor is distinct from old.amount_minor or new.currency is distinct from old.currency
    or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Paid-entry identity, exact Session and value are immutable.' using errcode='22023';
  end if;
  if new.status is distinct from old.status and not(
    (old.status='paid' and new.status in ('refund_pending','consumed'))
    or (old.status='refund_pending' and new.status in ('paid','credited','refunded'))) then
    raise exception 'Invalid paid-entry status transition.' using errcode='22023';
  end if;
  return new;
end;
$$;
create or replace function public.levelledup_guard_refund_case_history()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if tg_op='DELETE' then raise exception 'Refund-case history cannot be deleted.' using errcode='22023'; end if;
  if new.paid_entry_id is distinct from old.paid_entry_id
    or new.registration_id is distinct from old.registration_id
    or new.tournament_id is distinct from old.tournament_id or new.team_id is distinct from old.team_id
    or new.stage_id is distinct from old.stage_id or new.session_id is distinct from old.session_id
    or new.lobby_id is distinct from old.lobby_id or new.source_payment_id is distinct from old.source_payment_id
    or new.amount_minor is distinct from old.amount_minor or new.currency is distinct from old.currency
    or new.processing_mode is distinct from old.processing_mode or new.reason is distinct from old.reason
    or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Refund-case source, exact Session, value and mode are immutable.' using errcode='22023';
  end if;
  if new.status is distinct from old.status and not(
    (old.status='pending_review' and new.status in ('approved','rejected'))
    or (old.status='approved' and new.status in ('credited','refunded'))) then
    raise exception 'Invalid refund-case status transition.' using errcode='22023';
  end if;
  return new;
end;
$$;
create or replace function public.levelledup_guard_stage_credit_history()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if tg_op='DELETE' then raise exception 'Stage credit history cannot be deleted.' using errcode='22023'; end if;
  if new.refund_case_id is distinct from old.refund_case_id or new.paid_entry_id is distinct from old.paid_entry_id
    or new.registration_id is distinct from old.registration_id
    or new.tournament_id is distinct from old.tournament_id or new.team_id is distinct from old.team_id
    or new.stage_id is distinct from old.stage_id or new.session_id is distinct from old.session_id
    or new.source_payment_id is distinct from old.source_payment_id
    or new.amount_minor is distinct from old.amount_minor or new.currency is distinct from old.currency
    or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Stage credit source, exact Session and value are immutable.' using errcode='22023';
  end if;
  if new.status is distinct from old.status and not(
    old.status='available' and new.status in ('used','refunded')) then
    raise exception 'Invalid stage-credit status transition.' using errcode='22023';
  end if;
  return new;
end;
$$;

create function public.levelledup_validate_session_entry_source()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare r public.tournament_registrations; s public.tournament_stage_sessions;
  selected_team public.teams; selected_tournament public.tournaments;
  selected_stage public.tournament_stages;
  p public.tournament_registration_paid_entries; e public.tournament_session_entries;
  c public.levelledup_credit_ledger_entries;
begin
  select x.* into r from public.tournament_registrations x where x.id=new.registration_id;
  select x.* into s from public.tournament_stage_sessions x where x.id=new.session_id;
  if r.id is null or s.id is null or r.tournament_id<>new.tournament_id or r.team_id<>new.team_id
    or s.tournament_id<>new.tournament_id or s.stage_id<>new.stage_id then
    raise exception 'Session Entry parents must share the same Tournament, Stage, Session and registration/team.'
      using errcode='23503';
  end if;
  select x.* into selected_team from public.teams x where x.id=new.team_id;
  select x.* into selected_tournament from public.tournaments x where x.id=new.tournament_id;
  select x.* into selected_stage from public.tournament_stages x where x.id=new.stage_id;
  if selected_team.id is null or selected_team.status<>'active'
    or r.status<>'confirmed' or r.roster_status not in ('finalized','locked')
    or selected_tournament.id is null or selected_tournament.status in ('completed','cancelled')
    or selected_stage.id is null or selected_stage.status in ('completed','cancelled')
    or s.status not in ('planned','open') then
    raise exception 'A new Session Entry requires an active eligible team, confirmed Squad, and a future permitted Session.'
      using errcode='P4417';
  end if;
  if exists(select 1 from public.tournament_registration_roster squad
    left join public.team_roster_members current_member
      on current_member.id=squad.source_roster_member_id
    where squad.registration_id=r.id and squad.revision_number=r.roster_revision
      and (current_member.id is null or current_member.status<>'active')) then
    raise exception 'The current Tournament Squad contains a player who is no longer eligible for a future Session Entry.'
      using errcode='P4418';
  end if;
  if new.source_type='paid' then
    select x.* into p from public.tournament_registration_paid_entries x where x.id=new.source_paid_entry_id;
    if p.id is null or p.entry_scope<>'session' or p.status<>'paid'
      or p.registration_id<>new.registration_id or p.team_id<>new.team_id
      or p.tournament_id<>new.tournament_id or p.stage_id<>new.stage_id or p.session_id<>new.session_id then
      raise exception 'Paid Session Entry requires an unused paid entry for the exact registration and Session.'
        using errcode='22023';
    end if;
    new.source_occurred_at:=p.created_at;
  elsif new.source_type='earned' then
    select x.* into e from public.tournament_session_entries x where x.id=new.earned_from_session_entry_id;
    if e.id is null or e.status<>'active'
      or e.registration_id<>new.registration_id or e.team_id<>new.team_id
      or e.tournament_id<>new.tournament_id or e.session_id=new.session_id then
      raise exception 'Earned Session Entry requires trusted prior-participation provenance for the same registration/team; this does not prove qualification.'
        using errcode='22023';
    end if;
    new.source_occurred_at:=e.created_at;
  elsif new.source_type='credit' then
    select x.* into c from public.levelledup_credit_ledger_entries x where x.id=new.source_credit_ledger_entry_id;
    if c.id is null or c.event_type<>'apply' or c.amount_delta_minor>=0
      or c.operational_team_id<>new.team_id or selected_team.status<>'active'
      or exists(select 1 from public.levelledup_credit_ledger_entries x
        where x.related_entry_id=c.id and x.event_type='reversal') then
      raise exception 'Credit Session Entry requires an unreversed applied credit scoped to the active operational team.'
        using errcode='22023';
    end if;
    new.source_occurred_at:=c.created_at;
  else
    new.source_occurred_at:=coalesce(new.source_occurred_at,now());
  end if;
  return new;
end;
$$;
create trigger tournament_session_entries_00_validate_source
before insert on public.tournament_session_entries for each row
execute function public.levelledup_validate_session_entry_source();

create function public.levelledup_guard_session_entry_history()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
begin
  if tg_op='DELETE' then raise exception 'Session Entry history cannot be deleted.' using errcode='22023'; end if;
  if new.id is distinct from old.id or new.tournament_id is distinct from old.tournament_id
    or new.stage_id is distinct from old.stage_id or new.session_id is distinct from old.session_id
    or new.registration_id is distinct from old.registration_id or new.team_id is distinct from old.team_id
    or new.source_type is distinct from old.source_type
    or new.source_paid_entry_id is distinct from old.source_paid_entry_id
    or new.earned_from_session_entry_id is distinct from old.earned_from_session_entry_id
    or new.qualification_event_id is distinct from old.qualification_event_id
    or new.source_credit_ledger_entry_id is distinct from old.source_credit_ledger_entry_id
    or new.source_occurred_at is distinct from old.source_occurred_at
    or new.source_provenance is distinct from old.source_provenance
    or new.reason is distinct from old.reason or new.request_id is distinct from old.request_id
    or new.is_legacy_backfill is distinct from old.is_legacy_backfill
    or new.created_by is distinct from old.created_by or new.created_by_role is distinct from old.created_by_role
    or new.created_at is distinct from old.created_at then
    raise exception 'Session Entry identity and source provenance are immutable.' using errcode='22023';
  end if;
  if new.status is distinct from old.status and not(old.status='active' and new.status='cancelled') then
    raise exception 'Invalid Session Entry status transition.' using errcode='22023';
  end if;
  if new.status='cancelled' and exists(select 1 from public.tournament_stage_assignments a
    where a.session_entry_id=old.id and a.status='assigned') then
    raise exception 'Release the active Lobby assignment before cancelling its Session Entry.' using errcode='22023';
  end if;
  if new.status='cancelled' and exists(select 1 from public.tournament_session_entries child
    where child.earned_from_session_entry_id=old.id and child.status='active') then
    raise exception 'A Session Entry backing active earned participation cannot be cancelled.' using errcode='22023';
  end if;
  return new;
end;
$$;
create trigger tournament_session_entries_guard_history
before update or delete on public.tournament_session_entries for each row
execute function public.levelledup_guard_session_entry_history();

create function public.levelledup_admin_create_session_entry(
  p_session_id uuid,p_registration_id uuid,p_source_type text,
  p_source_paid_entry_id uuid,p_earned_from_session_entry_id uuid,
  p_source_credit_grant_entry_id uuid,p_credit_amount_minor bigint,
  p_reason text,p_request_id uuid,p_source_provenance jsonb
)
returns public.tournament_session_entries language plpgsql security definer
set search_path='' set row_security=off as $$
declare s public.tournament_stage_sessions; r public.tournament_registrations;
  existing public.tournament_session_entries; created public.tournament_session_entries;
  existing_credit public.levelledup_credit_ledger_entries;
  applied_credit public.levelledup_credit_ledger_entries;
  normalized_source text:=lower(btrim(coalesce(p_source_type,'')));
  normalized_reason text:=btrim(coalesce(p_reason,'')); actor_role text;
begin
  perform public.levelledup_require_admin('admin');
  if p_request_id is null or char_length(normalized_reason) not between 10 and 1000
    or coalesce(jsonb_typeof(p_source_provenance),'null')<>'object' then
    raise exception 'Request ID, object provenance and a 10-1000 character reason are required.' using errcode='22023';
  end if;
  if normalized_source not in ('paid','earned','credit','admin_grant')
    or (normalized_source='paid' and (p_source_paid_entry_id is null
      or p_earned_from_session_entry_id is not null or p_source_credit_grant_entry_id is not null
      or p_credit_amount_minor is not null))
    or (normalized_source='earned' and (p_source_paid_entry_id is not null
      or p_earned_from_session_entry_id is null or p_source_credit_grant_entry_id is not null
      or p_credit_amount_minor is not null))
    or (normalized_source='credit' and (p_source_paid_entry_id is not null
      or p_earned_from_session_entry_id is not null or p_source_credit_grant_entry_id is null
      or p_credit_amount_minor is null or p_credit_amount_minor<=0))
    or (normalized_source='admin_grant' and (p_source_paid_entry_id is not null
      or p_earned_from_session_entry_id is not null or p_source_credit_grant_entry_id is not null
      or p_credit_amount_minor is not null)) then
    raise exception 'Provide exactly the source fields required by the selected Session Entry source.' using errcode='22023';
  end if;
  if normalized_source='credit' and char_length(normalized_reason)>500 then
    raise exception 'Credit-backed Session Entry reason cannot exceed the ledger limit of 500 characters.' using errcode='22023';
  end if;
  -- Serializing the request before either the ledger application or Entry
  -- insert makes simultaneous identical requests return the same identity.
  perform pg_advisory_xact_lock(hashtextextended('session-entry-request:'||p_request_id::text,0));
  select x.* into existing from public.tournament_session_entries x where x.request_id=p_request_id;
  if existing.id is not null then
    if existing.session_id<>p_session_id or existing.registration_id<>p_registration_id
      or existing.source_type<>normalized_source
      or existing.source_paid_entry_id is distinct from p_source_paid_entry_id
      or existing.earned_from_session_entry_id is distinct from p_earned_from_session_entry_id
      or existing.reason<>normalized_reason
      or existing.source_provenance<>p_source_provenance then
      raise exception 'Request ID is already used by another Session Entry.' using errcode='23505';
    end if;
    if normalized_source='credit' then
      select x.* into existing_credit from public.levelledup_credit_ledger_entries x
      where x.id=existing.source_credit_ledger_entry_id;
      if existing_credit.related_entry_id is distinct from p_source_credit_grant_entry_id
        or existing_credit.amount_delta_minor is distinct from -p_credit_amount_minor then
        raise exception 'Request ID is already used with a different credit application.' using errcode='23505';
      end if;
    elsif existing.source_credit_ledger_entry_id is not null then
      raise exception 'Request ID source provenance is inconsistent.' using errcode='23505';
    end if;
    return existing;
  end if;
  select x.* into s from public.tournament_stage_sessions x where x.id=p_session_id for update;
  select x.* into r from public.tournament_registrations x where x.id=p_registration_id for update;
  if s.id is null or r.id is null or s.tournament_id<>r.tournament_id then
    raise exception 'Session and registration must belong to the same Tournament.' using errcode='23503';
  end if;
  actor_role:=public.levelledup_current_admin_role();
  if normalized_source='credit' then
    -- The existing ledger function locks the immutable grant, recomputes its
    -- remaining balance, and appends an idempotent apply row. Because this is
    -- the same transaction, a later Entry failure rolls the apply row back.
    applied_credit:=public.levelledup_admin_record_credit_debit(
      p_source_credit_grant_entry_id,'apply',p_credit_amount_minor,normalized_reason,
      'session-entry:'||p_request_id::text||':credit-apply'
    );
  end if;
  insert into public.tournament_session_entries(
    tournament_id,stage_id,session_id,registration_id,team_id,source_type,
    source_paid_entry_id,earned_from_session_entry_id,source_credit_ledger_entry_id,
    source_occurred_at,source_provenance,reason,request_id,created_by,created_by_role
  ) values(s.tournament_id,s.stage_id,s.id,r.id,r.team_id,normalized_source,
    p_source_paid_entry_id,p_earned_from_session_entry_id,applied_credit.id,
    now(),p_source_provenance,normalized_reason,p_request_id,auth.uid(),actor_role)
  returning * into created;
  return created;
end;
$$;

create function public.levelledup_admin_cancel_session_entry(
  p_session_entry_id uuid,p_reason text,p_request_id uuid
)
returns public.tournament_session_entries language plpgsql security definer
set search_path='' set row_security=off as $$
declare e public.tournament_session_entries; normalized_reason text:=btrim(coalesce(p_reason,''));
begin
  perform public.levelledup_require_admin('admin');
  if p_request_id is null or char_length(normalized_reason) not between 10 and 1000 then
    raise exception 'Request ID and a 10-1000 character cancellation reason are required.' using errcode='22023';
  end if;
  select x.* into e from public.tournament_session_entries x where x.id=p_session_entry_id for update;
  if e.id is null then raise exception 'Session Entry not found.' using errcode='22023'; end if;
  if e.status='cancelled' then
    if e.cancellation_request_id<>p_request_id or e.cancellation_reason<>normalized_reason then
      raise exception 'Session Entry is already cancelled by another request.' using errcode='23505';
    end if;
    return e;
  end if;
  update public.tournament_session_entries set status='cancelled',cancelled_by=auth.uid(),
    cancelled_at=now(),cancellation_reason=normalized_reason,cancellation_request_id=p_request_id
  where id=e.id returning * into e;
  return e;
end;
$$;

-- New paid Session allocations name the real Session explicitly. Lobby is
-- optional routing context and must belong to that Session when supplied.
drop function public.levelledup_admin_create_stage_paid_entry(uuid,uuid,text,uuid,integer,uuid);
create function public.levelledup_admin_create_stage_paid_entry(
  p_registration_id uuid,p_stage_id uuid,p_entry_scope text,p_source_payment_id uuid,
  p_amount_minor integer,p_session_id uuid,p_lobby_id uuid default null
)
returns public.tournament_registration_paid_entries language plpgsql security definer
set search_path='' set row_security=off as $$
declare r public.tournament_registrations; s public.tournament_stages;
  sess public.tournament_stage_sessions; pay public.tournament_registration_payments;
  scope text:=lower(btrim(coalesce(p_entry_scope,''))); allocated bigint;
  created public.tournament_registration_paid_entries;
begin
  perform public.levelledup_require_admin('admin');
  if scope not in ('stage','session') or (scope='stage' and (p_session_id is not null or p_lobby_id is not null))
    or (scope='session' and p_session_id is null) then
    raise exception 'Select a Stage scope or an exact Session scope.' using errcode='22023';
  end if;
  if p_amount_minor is null or p_amount_minor<=0 then raise exception 'Paid-entry amount must be positive.' using errcode='22023'; end if;
  select x.* into r from public.tournament_registrations x where x.id=p_registration_id for update;
  select x.* into s from public.tournament_stages x where x.id=p_stage_id for share;
  select x.* into pay from public.tournament_registration_payments x where x.id=p_source_payment_id for update;
  if r.id is null or s.id is null or s.tournament_id<>r.tournament_id then
    raise exception 'Registration and Stage must belong to the same Tournament.' using errcode='23503';
  end if;
  if pay.id is null or pay.status<>'verified' or pay.registration_id<>r.id
    or pay.tournament_id<>r.tournament_id or pay.team_id<>r.team_id then
    raise exception 'Paid entry requires the matching verified source payment.' using errcode='22023';
  end if;
  if scope='session' then
    select x.* into sess from public.tournament_stage_sessions x where x.id=p_session_id for share;
    if sess.id is null or sess.stage_id<>s.id or sess.tournament_id<>r.tournament_id then
      raise exception 'Paid Session must belong to the selected Stage and Tournament.' using errcode='23503';
    end if;
    if p_lobby_id is not null and not exists(select 1 from public.tournament_lobbies l
      where l.id=p_lobby_id and l.session_id=sess.id and l.stage_id=s.id and l.tournament_id=r.tournament_id) then
      raise exception 'Paid-entry Lobby must belong to the selected Session.' using errcode='23503';
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('financial-stage:'||s.id::text,0));
  if scope='session' then perform pg_advisory_xact_lock(hashtextextended('financial-session:'||sess.id::text,0)); end if;
  if exists(select 1 from public.tournament_matches m
    join public.tournament_lobbies l on l.id=m.lobby_id
    where m.stage_id=s.id and (scope='stage' or l.session_id=sess.id)
      and m.status in ('live','completed')) then
    raise exception 'A paid entry cannot be added after its Stage/Session has begun.' using errcode='22023';
  end if;
  select coalesce(sum(x.amount_minor),0) into allocated from public.tournament_registration_paid_entries x
  where x.source_payment_id=pay.id;
  if allocated+p_amount_minor>pay.expected_amount_minor then
    raise exception 'Paid-entry allocations exceed the verified source payment.' using errcode='22023';
  end if;
  insert into public.tournament_registration_paid_entries(
    registration_id,tournament_id,team_id,stage_id,session_id,lobby_id,entry_scope,
    source_payment_id,amount_minor,currency,created_by
  ) values(r.id,r.tournament_id,r.team_id,s.id,p_session_id,p_lobby_id,scope,
    pay.id,p_amount_minor,pay.currency,auth.uid()) returning * into created;
  return created;
end;
$$;

create or replace function public.levelledup_admin_create_stage_refund_case(
  p_paid_entry_id uuid,p_reason text
)
returns public.tournament_stage_refund_cases language plpgsql security definer
set search_path='' set row_security=off as $$
declare e public.tournament_registration_paid_entries; selected_mode text;
  normalized_reason text:=btrim(coalesce(p_reason,'')); created public.tournament_stage_refund_cases;
begin
  perform public.levelledup_require_admin('admin');
  if char_length(normalized_reason) not between 3 and 500 then
    raise exception 'Provide a refund reason between 3 and 500 characters.' using errcode='22023';
  end if;
  select x.* into e from public.tournament_registration_paid_entries x where x.id=p_paid_entry_id;
  if e.id is null or e.status<>'paid' then
    raise exception 'Only an unused paid entry can enter refund processing.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('financial-stage:'||e.stage_id::text,0));
  if e.entry_scope='session' then
    perform pg_advisory_xact_lock(hashtextextended('financial-session:'||e.session_id::text,0));
  end if;
  select x.* into e from public.tournament_registration_paid_entries x where x.id=p_paid_entry_id for update;
  if e.id is null or e.status<>'paid' then
    raise exception 'Only an unused paid entry can enter refund processing.' using errcode='22023';
  end if;
  if exists(select 1 from public.tournament_matches m
    join public.tournament_lobbies l on l.id=m.lobby_id
    where m.stage_id=e.stage_id and (e.entry_scope='stage' or l.session_id=e.session_id)
      and m.status in ('live','completed')) then
    raise exception 'Played Stage/Session entries cannot be refunded or credited.' using errcode='22023';
  end if;
  select x.refund_mode into selected_mode from public.levelledup_financial_settings x
  where x.singleton for update;
  insert into public.tournament_stage_refund_cases(
    paid_entry_id,registration_id,tournament_id,team_id,stage_id,session_id,lobby_id,
    source_payment_id,amount_minor,currency,processing_mode,status,reason,
    created_by,reviewed_by,reviewed_at
  ) values(e.id,e.registration_id,e.tournament_id,e.team_id,e.stage_id,e.session_id,e.lobby_id,
    e.source_payment_id,e.amount_minor,e.currency,selected_mode,
    case when selected_mode='automatic' then 'approved' else 'pending_review' end,
    normalized_reason,auth.uid(),case when selected_mode='automatic' then auth.uid() else null end,
    case when selected_mode='automatic' then now() else null end) returning * into created;
  update public.tournament_registration_paid_entries set status='refund_pending',updated_at=now()
  where id=e.id;
  if selected_mode='automatic' then
    perform public.levelledup_issue_stage_refund_credit(created.id);
    select x.* into created from public.tournament_stage_refund_cases x where x.id=created.id;
  end if;
  return created;
end;
$$;

create or replace function public.levelledup_credit_unused_entries_before_registration_close(
  p_registration_id uuid,p_actor_user_id uuid,p_reason text
)
returns integer language plpgsql security definer set search_path='' set row_security=off as $$
declare r public.tournament_registrations; t public.tournaments;
  e public.tournament_registration_paid_entries; c public.tournament_stage_refund_cases;
  credited_count integer:=0; normalized_reason text:=btrim(coalesce(p_reason,''));
  decision_at timestamptz;
begin
  if p_actor_user_id is null then raise exception 'A trusted credit actor is required.' using errcode='42501'; end if;
  if char_length(normalized_reason) not between 3 and 500 then
    raise exception 'Provide a credit reason between 3 and 500 characters.' using errcode='22023';
  end if;
  select x.* into r from public.tournament_registrations x where x.id=p_registration_id for update;
  if r.id is null then raise exception 'Tournament registration not found.' using errcode='P4013'; end if;
  select x.* into t from public.tournaments x where x.id=r.tournament_id for share;
  decision_at:=clock_timestamp();
  if t.id is null or decision_at>=t.registration_closes_at then return 0; end if;
  for e in select x.* from public.tournament_registration_paid_entries x
    where x.registration_id=r.id and x.status in ('paid','refund_pending')
    order by x.created_at,x.id
  loop
    perform pg_advisory_xact_lock(hashtextextended('financial-stage:'||e.stage_id::text,0));
    if e.entry_scope='session' then
      perform pg_advisory_xact_lock(hashtextextended('financial-session:'||e.session_id::text,0));
    end if;
    select x.* into e from public.tournament_registration_paid_entries x where x.id=e.id for update;
    if e.status not in ('paid','refund_pending') then continue; end if;
    if exists(select 1 from public.tournament_matches m
      join public.tournament_lobbies l on l.id=m.lobby_id
      where m.stage_id=e.stage_id and (e.entry_scope='stage' or l.session_id=e.session_id)
        and m.status in ('live','completed')) then continue; end if;
    if e.status='paid' then
      insert into public.tournament_stage_refund_cases(
        paid_entry_id,registration_id,tournament_id,team_id,stage_id,session_id,lobby_id,
        source_payment_id,amount_minor,currency,processing_mode,status,reason,
        created_by,reviewed_by,reviewed_at
      ) values(e.id,e.registration_id,e.tournament_id,e.team_id,e.stage_id,e.session_id,e.lobby_id,
        e.source_payment_id,e.amount_minor,e.currency,'automatic','approved',normalized_reason,
        p_actor_user_id,p_actor_user_id,decision_at) returning * into c;
      update public.tournament_registration_paid_entries set status='refund_pending',updated_at=decision_at
      where id=e.id;
    else
      select x.* into c from public.tournament_stage_refund_cases x
      where x.paid_entry_id=e.id and x.status<>'rejected' for update;
      if c.id is null or c.status not in ('pending_review','approved') then
        raise exception 'Unused paid entry has no creditable refund case.' using errcode='22023';
      end if;
      if c.status='pending_review' then
        update public.tournament_stage_refund_cases set status='approved',reviewed_by=p_actor_user_id,
          reviewed_at=decision_at,updated_at=decision_at where id=c.id returning * into c;
      end if;
    end if;
    insert into public.tournament_stage_credit_entitlements(
      refund_case_id,paid_entry_id,registration_id,tournament_id,team_id,stage_id,session_id,
      source_payment_id,amount_minor,currency,created_by,status_updated_by,
      status_updated_at,created_at,updated_at
    ) values(c.id,e.id,e.registration_id,e.tournament_id,e.team_id,e.stage_id,e.session_id,
      e.source_payment_id,e.amount_minor,e.currency,p_actor_user_id,p_actor_user_id,
      decision_at,decision_at,decision_at);
    update public.tournament_registration_paid_entries set status='credited',updated_at=decision_at
    where id=e.id;
    update public.tournament_stage_refund_cases set status='credited',credit_issued_at=decision_at,
      updated_at=decision_at where id=c.id;
    credited_count:=credited_count+1;
  end loop;
  return credited_count;
end;
$$;

create or replace function public.levelledup_guard_paid_entries_before_match_live()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare match_session_id uuid;
begin
  if old.status is distinct from 'live' and new.status='live' then
    select l.session_id into match_session_id from public.tournament_lobbies l where l.id=new.lobby_id;
    perform pg_advisory_xact_lock(hashtextextended('financial-stage:'||new.stage_id::text,0));
    perform pg_advisory_xact_lock(hashtextextended('financial-session:'||match_session_id::text,0));
    if exists(select 1 from public.tournament_registration_paid_entries e
      where e.status='refund_pending' and e.stage_id=new.stage_id
        and (e.entry_scope='stage' or e.session_id=match_session_id)) then
      raise exception 'Resolve pending Stage/Session refund cases before starting this Match.' using errcode='22023';
    end if;
  end if;
  return new;
end;
$$;
create or replace function public.levelledup_consume_paid_entries_after_match_live()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare match_session_id uuid;
begin
  if old.status is distinct from 'live' and new.status='live' then
    select l.session_id into match_session_id from public.tournament_lobbies l where l.id=new.lobby_id;
    update public.tournament_registration_paid_entries e set status='consumed',
      consumed_match_id=new.id,consumed_at=now(),updated_at=now()
    where e.status='paid' and e.stage_id=new.stage_id
      and (e.entry_scope='stage' or e.session_id=match_session_id);
  end if;
  return new;
end;
$$;

create function public.levelledup_guard_active_session_entry_finance()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
begin
  if new.status in ('refund_pending','credited','refunded')
    and new.status is distinct from old.status
    and exists(select 1 from public.tournament_session_entries e
      where e.source_paid_entry_id=old.id and e.status='active') then
    raise exception 'Cancel the active paid Session Entry before refunding or crediting its source.'
      using errcode='22023';
  end if;
  return new;
end;
$$;
create trigger tournament_paid_entries_05_guard_active_session_entry
before update of status on public.tournament_registration_paid_entries for each row
execute function public.levelledup_guard_active_session_entry_finance();

create function public.levelledup_guard_session_entry_credit_reversal()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
begin
  if new.event_type='reversal' and exists(select 1 from public.tournament_session_entries e
    where e.source_credit_ledger_entry_id=new.related_entry_id and e.status='active') then
    raise exception 'Cancel the active credit Session Entry before reversing its applied credit.'
      using errcode='22023';
  end if;
  return new;
end;
$$;
create trigger levelledup_credit_ledger_zz_session_entry_reversal_guard
before insert on public.levelledup_credit_ledger_entries for each row
execute function public.levelledup_guard_session_entry_credit_reversal();

-- Fail the migration rather than accept a partial or cross-parent backfill.
do $$
begin
  if exists(select 1 from public.tournament_stage_assignments a
    join public.tournament_lobbies l on l.id=a.lobby_id
    join public.tournament_session_entries e on e.id=a.session_entry_id
    where a.session_id<>l.session_id or a.session_id<>e.session_id
      or a.stage_id<>e.stage_id or a.tournament_id<>e.tournament_id
      or a.registration_id<>e.registration_id) then
    raise exception 'Session Entry assignment backfill failed scope validation.';
  end if;
  if exists(select 1 from public.tournament_registration_paid_entries p
    where (p.entry_scope='stage' and (p.session_id is not null or p.lobby_id is not null))
      or (p.entry_scope='session' and p.session_id is null)) then
    raise exception 'Paid-entry Session backfill failed scope validation.';
  end if;
  if exists(select 1 from public.tournament_stage_refund_cases c
    join public.tournament_registration_paid_entries p on p.id=c.paid_entry_id
    where c.session_id is distinct from p.session_id or c.stage_id<>p.stage_id
      or c.tournament_id<>p.tournament_id or c.registration_id<>p.registration_id) then
    raise exception 'Refund-case Session backfill failed scope validation.';
  end if;
  if exists(select 1 from public.tournament_stage_credit_entitlements c
    join public.tournament_registration_paid_entries p on p.id=c.paid_entry_id
    where c.session_id is distinct from p.session_id or c.stage_id<>p.stage_id
      or c.tournament_id<>p.tournament_id or c.registration_id<>p.registration_id) then
    raise exception 'Credit-entitlement Session backfill failed scope validation.';
  end if;
end;
$$;

-- Session Entry access is readable by its team and Admins, but all browser
-- writes remain denied. Trusted writes are Admin RPCs with internal checks.
alter table public.tournament_session_entries enable row level security;
revoke all on table public.tournament_session_entries from public,anon,authenticated;
grant select on table public.tournament_session_entries to authenticated;
create policy tournament_session_entries_authorized_read on public.tournament_session_entries
for select to authenticated using(
  public.levelledup_has_admin_role('admin')
  or exists(select 1 from public.tournament_registrations r
    where r.id=registration_id and public.levelledup_is_active_team_member(r.team_id))
);

alter function public.levelledup_validate_assignment_session_entry() owner to postgres;
alter function public.levelledup_validate_paid_entry_session_scope() owner to postgres;
alter function public.levelledup_validate_refund_session_scope() owner to postgres;
alter function public.levelledup_validate_credit_session_scope() owner to postgres;
alter function public.levelledup_validate_session_entry_source() owner to postgres;
alter function public.levelledup_guard_session_entry_history() owner to postgres;
alter function public.levelledup_guard_active_session_entry_finance() owner to postgres;
alter function public.levelledup_guard_session_entry_credit_reversal() owner to postgres;
alter function public.levelledup_guard_paid_entry_history() owner to postgres;
alter function public.levelledup_guard_refund_case_history() owner to postgres;
alter function public.levelledup_guard_stage_credit_history() owner to postgres;
alter function public.levelledup_admin_create_session_entry(uuid,uuid,text,uuid,uuid,uuid,bigint,text,uuid,jsonb) owner to postgres;
alter function public.levelledup_admin_cancel_session_entry(uuid,text,uuid) owner to postgres;
alter function public.levelledup_admin_create_stage_paid_entry(uuid,uuid,text,uuid,integer,uuid,uuid) owner to postgres;

revoke all on function public.levelledup_validate_assignment_session_entry(),
  public.levelledup_validate_paid_entry_session_scope(),public.levelledup_validate_refund_session_scope(),
  public.levelledup_validate_credit_session_scope(),public.levelledup_validate_session_entry_source(),
  public.levelledup_guard_session_entry_history(),public.levelledup_guard_active_session_entry_finance(),
  public.levelledup_guard_session_entry_credit_reversal(),
  public.levelledup_admin_create_session_entry(uuid,uuid,text,uuid,uuid,uuid,bigint,text,uuid,jsonb),
  public.levelledup_admin_cancel_session_entry(uuid,text,uuid),
  public.levelledup_admin_create_stage_paid_entry(uuid,uuid,text,uuid,integer,uuid,uuid)
  from public,anon,authenticated;
grant execute on function
  public.levelledup_admin_create_session_entry(uuid,uuid,text,uuid,uuid,uuid,bigint,text,uuid,jsonb),
  public.levelledup_admin_cancel_session_entry(uuid,text,uuid),
  public.levelledup_admin_create_stage_paid_entry(uuid,uuid,text,uuid,integer,uuid,uuid)
  to authenticated;

comment on function public.levelledup_admin_create_session_entry(uuid,uuid,text,uuid,uuid,uuid,bigint,text,uuid,jsonb) is
  'Admin-only idempotent creation of paid, earned, credit or Admin-granted exact Session participation. Credit application and Entry creation are one transaction. Earned provenance is not proof of qualification and no advancement is performed.';

commit;
