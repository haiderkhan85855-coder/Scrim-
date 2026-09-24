begin;

-- Never choose an owner or silently demote staff during deployment.
lock table public.admin_users in access exclusive mode;
do $$ begin
  if (select count(*) from public.admin_users where role = 'super_admin') <> 1 then
    raise exception 'Exactly one existing super_admin must be explicitly bootstrapped before applying this migration.';
  end if;
  if (select count(*) from public.admin_users where role = 'admin') > 2 then
    raise exception 'Review existing admin accounts: at most two Tournament Admins are allowed.';
  end if;
end $$;

alter table public.admin_users
  drop constraint admin_users_role_valid,
  add column is_active boolean not null default true,
  add column tournament_admin_seat integer;
-- Keep authorization-grant timestamps intact during the terminology migration.
alter table public.admin_users disable trigger admin_users_set_updated_at;
with seats as (
  select user_id, row_number() over (order by created_at, user_id)::integer as seat
  from public.admin_users where role = 'admin'
)
update public.admin_users a set role = 'tournament_admin', tournament_admin_seat = s.seat
from seats s where s.user_id = a.user_id;
alter table public.admin_users enable trigger admin_users_set_updated_at;
alter table public.admin_users
  add constraint admin_users_role_valid check (role in ('tournament_admin', 'super_admin')),
  add constraint admin_users_active_seat_valid check (
    (role = 'super_admin' and is_active and tournament_admin_seat is null)
    or (role = 'tournament_admin' and (
      (is_active and tournament_admin_seat is not null and tournament_admin_seat in (1, 2))
      or (not is_active and tournament_admin_seat is null)
    ))
  ),
  drop constraint admin_users_granted_by_fkey,
  add constraint admin_users_granted_by_fkey foreign key(granted_by) references auth.users(id) on delete restrict;
create unique index admin_users_one_super_admin on public.admin_users(role) where role = 'super_admin';
create unique index admin_users_two_active_tournament_admins on public.admin_users(tournament_admin_seat)
  where role = 'tournament_admin' and is_active;

create or replace function public.levelledup_has_admin_role(p_required_role text default 'admin')
returns boolean language plpgsql stable security definer set search_path = '' set row_security = off as $$
begin
  if auth.uid() is null then return false; end if;
  if p_required_role is null or p_required_role not in ('admin', 'tournament_admin', 'super_admin') then
    raise exception 'Unknown LevelledUp admin role.' using errcode = '22023';
  end if;
  return exists(select 1 from public.admin_users a where a.user_id = auth.uid() and a.is_active
    and (a.role = 'super_admin' or (a.role = 'tournament_admin' and p_required_role in ('admin', 'tournament_admin'))));
end;
$$;
create or replace function public.levelledup_current_admin_role()
returns text language sql stable security definer set search_path = '' set row_security = off as $$
  select case a.role when 'tournament_admin' then 'admin' else a.role end
  from public.admin_users a where a.user_id = auth.uid() and a.is_active;
$$;
comment on function public.levelledup_current_admin_role() is
  'Legacy application-role projection: active tournament_admin returns admin for existing Header/login/server helpers. Canonical staff role remains tournament_admin. Inactive staff return null.';

-- Existing ledger functions sometimes read the canonical role directly.
-- Accept the new label without rewriting any existing financial entry.
alter table public.levelledup_credit_ledger_entries
  drop constraint levelledup_credit_ledger_actor_role_valid,
  add constraint levelledup_credit_ledger_actor_role_valid check (
    actor_role in ('system', 'payer', 'team_captain', 'admin', 'tournament_admin', 'super_admin')
  );

create table public.levelledup_admin_payment_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check (event_type in ('staff_baseline','staff_changed','destination_changed','payment_submitted','payment_reviewed','nonpaid_entry_recorded')),
  entity_id uuid not null,
  request_id uuid unique,
  actor_id uuid references auth.users(id) on delete restrict,
  actor_role text,
  database_role text not null default session_user,
  before_data jsonb not null default '{}'::jsonb,
  after_data jsonb not null,
  reason text not null check (char_length(btrim(reason)) between 10 and 1000),
  created_at timestamptz not null default clock_timestamp(),
  check(jsonb_typeof(before_data) = 'object' and jsonb_typeof(after_data) = 'object')
);
create index levelledup_admin_payment_events_entity_idx on public.levelledup_admin_payment_events(entity_id,created_at);
insert into public.levelledup_admin_payment_events(event_type,entity_id,after_data,reason)
select 'staff_baseline',user_id,to_jsonb(a),'Existing staff authorization baseline; no automatic promotion' from public.admin_users a;

create function public.levelledup_preserve_admin_payment_history()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'Permanent Admin/payment history cannot be updated or deleted.' using errcode = '22023';
end;
$$;
create trigger levelledup_admin_payment_events_append_only before update or delete on public.levelledup_admin_payment_events
for each row execute function public.levelledup_preserve_admin_payment_history();

create function public.levelledup_guard_staff_ownership()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Staff history cannot be deleted; deactivate Tournament Admin access.' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and (new.role is distinct from old.role
    or new.created_at is distinct from old.created_at
    or (old.role = 'super_admin' and new is distinct from old)) then
    raise exception 'Super Admin ownership and existing staff identities cannot be changed.' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger admin_users_00_guard_staff_ownership before update or delete on public.admin_users
for each row execute function public.levelledup_guard_staff_ownership();

create function public.levelledup_super_admin_set_tournament_admin(
  p_user_id uuid, p_active boolean, p_reason text, p_request_id uuid
)
returns void language plpgsql security definer set search_path = '' set row_security = off as $$
declare
  previous public.admin_users; updated public.admin_users;
  old_event public.levelledup_admin_payment_events; available_seat integer;
begin
  -- Serialize staff grants/revocations and make duplicate submissions no-ops.
  perform pg_advisory_xact_lock(hashtextextended('levelledup-staff-management',0));
  perform public.levelledup_require_admin('super_admin');
  if p_user_id is null or p_active is null or p_request_id is null
    or p_reason is null or char_length(btrim(p_reason)) not between 10 and 1000 then
    raise exception 'User, active state, request ID and a 10-1000 character reason are required.' using errcode = '22023';
  end if;
  select * into old_event from public.levelledup_admin_payment_events where request_id = p_request_id;
  if found then
    if old_event.event_type <> 'staff_changed' or old_event.entity_id <> p_user_id or old_event.actor_id <> auth.uid()
      or (old_event.after_data->>'is_active')::boolean <> p_active or old_event.reason <> btrim(p_reason) then
      raise exception 'Request ID already belongs to a different operation.' using errcode = '22023';
    end if;
    return;
  end if;
  select * into previous from public.admin_users where user_id = p_user_id for update;
  if previous.role = 'super_admin' then
    raise exception 'Super Admin cannot be removed, demoted or recreated through this operation.' using errcode = '42501';
  end if;
  if p_active then
    available_seat := previous.tournament_admin_seat;
    if available_seat is null then
      select n into available_seat from generate_series(1,2) n
      where not exists(select 1 from public.admin_users a where a.is_active and a.tournament_admin_seat = n)
      order by n limit 1;
    end if;
    if available_seat is null then raise exception 'Maximum of two active Tournament Admins reached.' using errcode = '22023'; end if;
    insert into public.admin_users(user_id,role,is_active,tournament_admin_seat,granted_by)
    values(p_user_id,'tournament_admin',true,available_seat,auth.uid())
    on conflict(user_id) do update set is_active = true, tournament_admin_seat = excluded.tournament_admin_seat,
      granted_by = excluded.granted_by returning * into updated;
  else
    if previous.user_id is null then raise exception 'Tournament Admin not found.' using errcode = '22023'; end if;
    update public.admin_users set is_active = false,tournament_admin_seat = null
    where user_id = p_user_id returning * into updated;
  end if;
  insert into public.levelledup_admin_payment_events(event_type,entity_id,request_id,actor_id,actor_role,before_data,after_data,reason)
  values('staff_changed',p_user_id,p_request_id,auth.uid(),'super_admin',
    case when previous.user_id is null then '{}'::jsonb else to_jsonb(previous) end,to_jsonb(updated),btrim(p_reason));
end;
$$;

-- Immutable destination versions plus a single DB-owned active pointer.
create table public.levelledup_payment_destinations (
  id uuid primary key default gen_random_uuid(),
  provider text not null check(char_length(btrim(provider)) between 2 and 80 and provider = btrim(provider)),
  account_label text not null check(char_length(btrim(account_label)) between 1 and 100 and account_label = btrim(account_label)),
  account_holder text not null check(char_length(btrim(account_holder)) between 1 and 120 and account_holder = btrim(account_holder)),
  receiving_account text not null check(char_length(btrim(receiving_account)) between 3 and 120 and receiving_account = btrim(receiving_account)),
  request_id uuid not null unique,
  changed_by uuid not null references auth.users(id) on delete restrict,
  reason text not null check(char_length(btrim(reason)) between 10 and 1000),
  created_at timestamptz not null default clock_timestamp()
);
create table public.levelledup_payment_destination_settings (
  singleton boolean primary key default true check(singleton),
  destination_id uuid references public.levelledup_payment_destinations(id) on delete restrict
);
insert into public.levelledup_payment_destination_settings(singleton) values(true);
create trigger levelledup_payment_destinations_append_only before update or delete on public.levelledup_payment_destinations
for each row execute function public.levelledup_preserve_admin_payment_history();

create function public.levelledup_admin_set_payment_destination(
  p_provider text, p_account_label text, p_account_holder text, p_receiving_account text,
  p_reason text, p_request_id uuid
)
returns uuid language plpgsql security definer set search_path = '' set row_security = off as $$
declare
  old_id uuid; destination public.levelledup_payment_destinations;
begin
  perform public.levelledup_require_admin('admin');
  select destination_id into old_id from public.levelledup_payment_destination_settings where singleton for update;
  select * into destination from public.levelledup_payment_destinations where request_id = p_request_id;
  if found then
    if destination.changed_by <> auth.uid() or destination.provider is distinct from btrim(p_provider)
      or destination.account_label is distinct from btrim(p_account_label)
      or destination.account_holder is distinct from btrim(p_account_holder)
      or destination.receiving_account is distinct from btrim(p_receiving_account)
      or destination.reason is distinct from btrim(p_reason) then
      raise exception 'Request ID already belongs to another destination change.' using errcode = '22023';
    end if;
    -- Never reactivate an old destination on a retry after a newer change.
    return destination.id;
  end if;
  insert into public.levelledup_payment_destinations(provider,account_label,account_holder,receiving_account,request_id,changed_by,reason)
  values(btrim(p_provider),btrim(p_account_label),btrim(p_account_holder),btrim(p_receiving_account),p_request_id,auth.uid(),btrim(p_reason))
  returning * into destination;
  update public.levelledup_payment_destination_settings set destination_id = destination.id where singleton;
  insert into public.levelledup_admin_payment_events(event_type,entity_id,request_id,actor_id,actor_role,before_data,after_data,reason)
  values('destination_changed',destination.id,p_request_id,auth.uid(),
    (select role from public.admin_users where user_id = auth.uid()),
    jsonb_build_object('destination_id',old_id),to_jsonb(destination),btrim(p_reason));
  return destination.id;
end;
$$;

-- Payer-facing instructions exclude staff UUIDs, reasons and version history.
create function public.levelledup_get_payment_destination()
returns table(destination_id uuid,provider text,account_label text,account_holder text,receiving_account text)
language plpgsql stable security definer set search_path = '' set row_security = off as $$
begin
  if auth.uid() is null then raise exception 'Authentication required.' using errcode = '42501'; end if;
  return query select d.id,d.provider,d.account_label,d.account_holder,d.receiving_account
  from public.levelledup_payment_destination_settings s
  join public.levelledup_payment_destinations d on d.id = s.destination_id where s.singleton;
end;
$$;

alter table public.tournament_registration_payments
  add column receiving_destination_id uuid references public.levelledup_payment_destinations(id) on delete restrict,
  add column receiving_account_snapshot jsonb,
  add constraint tournament_payments_destination_snapshot_valid check (
    (receiving_destination_id is null and receiving_account_snapshot is null)
    or (receiving_destination_id is not null and receiving_account_snapshot is not null
      and jsonb_typeof(receiving_account_snapshot) = 'object')
  ),
  drop constraint tournament_registration_payments_reviewed_by_fkey,
  add constraint tournament_registration_payments_reviewed_by_fkey foreign key(reviewed_by) references auth.users(id) on delete restrict;
comment on column public.tournament_registration_payments.receiving_account_snapshot is
  'Immutable receiving provider/label/holder/account captured by DB at submission. NULL on legacy payments means historically unknown, never infer it from the current account. Payer remains submitted_by; stage/session allocations remain linked through paid_entries.source_payment_id.';

create function public.levelledup_snapshot_payment_destination()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
declare destination public.levelledup_payment_destinations;
begin
  if tg_op = 'INSERT' then
    -- SHARE conflicts with destination replacement until this submission commits.
    perform 1 from public.levelledup_payment_destination_settings where singleton for share;
    select d.* into destination from public.levelledup_payment_destination_settings s
    join public.levelledup_payment_destinations d on d.id = s.destination_id where s.singleton;
    if destination.id is null then
      raise exception 'Payment receiving account is not configured. Contact a Tournament Admin before submitting payment.' using errcode = '22023';
    end if;
    new.receiving_destination_id := destination.id;
    new.receiving_account_snapshot := jsonb_build_object('provider',destination.provider,'account_label',destination.account_label,
      'account_holder',destination.account_holder,'receiving_account',destination.receiving_account);
  else
    if new.id is distinct from old.id or new.receiving_destination_id is distinct from old.receiving_destination_id
      or new.receiving_account_snapshot is distinct from old.receiving_account_snapshot
      or (old.status <> 'pending' and (new.reviewed_by is distinct from old.reviewed_by
        or new.reviewed_at is distinct from old.reviewed_at or new.verification_source is distinct from old.verification_source)) then
      raise exception 'Payment destination, identity and completed review provenance are immutable.' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger tournament_payments_snapshot_destination before insert or update on public.tournament_registration_payments
for each row execute function public.levelledup_snapshot_payment_destination();

create function public.levelledup_audit_payment_submission_review()
returns trigger language plpgsql security definer set search_path = '' set row_security = off as $$
begin
  if tg_op = 'INSERT' then
    insert into public.levelledup_admin_payment_events(event_type,entity_id,actor_id,actor_role,after_data,reason)
    values('payment_submitted',new.id,new.submitted_by,'payer',to_jsonb(new),'Payment submitted with immutable destination snapshot');
  elsif new.status is distinct from old.status then
    insert into public.levelledup_admin_payment_events(event_type,entity_id,actor_id,actor_role,before_data,after_data,reason)
    values('payment_reviewed',new.id,new.reviewed_by,
      coalesce((select role from public.admin_users where user_id = new.reviewed_by),'provider_callback'),
      to_jsonb(old),to_jsonb(new),'Payment decision recorded: ' || new.status);
  end if;
  return new;
end;
$$;
create trigger tournament_payments_audit_submission_review after insert or update on public.tournament_registration_payments
for each row execute function public.levelledup_audit_payment_submission_review();

-- Free/earned access is NON-FINANCIAL. Never insert zero-value fake payments,
-- paid_entries or refundable credits. This records an award, not advancement.
create table public.tournament_nonpaid_stage_entries (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null,
  tournament_id uuid not null,
  team_id uuid not null,
  stage_id uuid not null,
  lobby_id uuid,
  entry_kind text not null check(entry_kind in ('free','earned')),
  entry_scope text not null check(entry_scope in ('stage','session')),
  revenue_minor bigint generated always as (0::bigint) stored,
  is_payment boolean generated always as (false) stored,
  request_id uuid not null unique,
  granted_by uuid not null references auth.users(id) on delete restrict,
  reason text not null check(char_length(btrim(reason)) between 10 and 1000),
  created_at timestamptz not null default clock_timestamp(),
  foreign key(registration_id,tournament_id,team_id) references public.tournament_registrations(id,tournament_id,team_id) on delete restrict,
  foreign key(stage_id,tournament_id) references public.tournament_stages(id,tournament_id) on delete restrict,
  foreign key(lobby_id,stage_id,tournament_id) references public.tournament_lobbies(id,stage_id,tournament_id) on delete restrict,
  check((entry_scope='stage' and lobby_id is null) or (entry_scope='session' and lobby_id is not null))
);
create unique index tournament_nonpaid_stage_scope_unique on public.tournament_nonpaid_stage_entries(registration_id,stage_id) where entry_scope='stage';
create unique index tournament_nonpaid_session_scope_unique on public.tournament_nonpaid_stage_entries(registration_id,lobby_id) where entry_scope='session';
create trigger tournament_nonpaid_stage_entries_append_only before update or delete on public.tournament_nonpaid_stage_entries
for each row execute function public.levelledup_preserve_admin_payment_history();

create function public.levelledup_admin_record_nonpaid_stage_entry(
  p_registration_id uuid,p_stage_id uuid,p_entry_kind text,p_reason text,p_request_id uuid,p_lobby_id uuid default null
)
returns public.tournament_nonpaid_stage_entries
language plpgsql security definer set search_path = '' set row_security = off as $$
declare
  registration public.tournament_registrations; stage public.tournament_stages;
  entry public.tournament_nonpaid_stage_entries; parent public.tournaments;
begin
  perform public.levelledup_require_admin('admin');
  perform pg_advisory_xact_lock(hashtextextended('nonpaid-stage-entry:' || coalesce(p_request_id::text,''),0));
  select * into entry from public.tournament_nonpaid_stage_entries where request_id = p_request_id;
  if found then
    if entry.registration_id is distinct from p_registration_id or entry.stage_id is distinct from p_stage_id
      or entry.entry_kind is distinct from p_entry_kind or entry.reason is distinct from btrim(p_reason)
      or entry.lobby_id is distinct from p_lobby_id or entry.granted_by <> auth.uid() then
      raise exception 'Request ID already belongs to another entry.' using errcode = '22023';
    end if;
    return entry;
  end if;
  select t.* into parent from public.tournaments t join public.tournament_registrations r on r.tournament_id=t.id
  where r.id=p_registration_id for update of t;
  select * into registration from public.tournament_registrations where id=p_registration_id for update;
  select * into stage from public.tournament_stages where id=p_stage_id and tournament_id=registration.tournament_id for share;
  if registration.id is null or registration.status <> 'confirmed' or stage.id is null
    or stage.status <> 'planned' or stage.rules_locked_at is not null
    or parent.status in ('cancelled','completed') or parent.archived_at is not null then
    raise exception 'A confirmed registration and an unstarted stage in the same active tournament are required.' using errcode='22023';
  end if;
  perform 1 from public.teams where id=registration.team_id and status='active' for share;
  if not found then raise exception 'Disbanded teams cannot receive new stage entries.' using errcode='22023'; end if;
  if p_entry_kind='free' and stage.stage_fee_minor is distinct from 0 then
    raise exception 'Free entry requires a stage explicitly configured with zero fee; use earned for an authorized award.' using errcode='22023';
  end if;
  insert into public.tournament_nonpaid_stage_entries(registration_id,tournament_id,team_id,stage_id,lobby_id,
    entry_kind,entry_scope,request_id,granted_by,reason)
  values(registration.id,registration.tournament_id,registration.team_id,stage.id,p_lobby_id,p_entry_kind,
    case when p_lobby_id is null then 'stage' else 'session' end,p_request_id,auth.uid(),btrim(p_reason)) returning * into entry;
  insert into public.levelledup_admin_payment_events(event_type,entity_id,request_id,actor_id,actor_role,after_data,reason)
  values('nonpaid_entry_recorded',entry.id,p_request_id,auth.uid(),
    (select role from public.admin_users where user_id=auth.uid()),to_jsonb(entry),btrim(p_reason));
  return entry;
end;
$$;

-- No new sensitive direct writes. Raw destination/event history is staff-only;
-- payers receive safe current instructions and their existing payment projection.
alter table public.levelledup_admin_payment_events enable row level security;
alter table public.levelledup_payment_destinations enable row level security;
alter table public.levelledup_payment_destination_settings enable row level security;
alter table public.tournament_nonpaid_stage_entries enable row level security;
revoke all on public.admin_users,public.levelledup_admin_payment_events,public.levelledup_payment_destinations,
  public.levelledup_payment_destination_settings,public.tournament_nonpaid_stage_entries from public,anon,authenticated;
grant select on public.levelledup_admin_payment_events,public.levelledup_payment_destinations,public.tournament_nonpaid_stage_entries to authenticated;
create policy admin_payment_events_staff_read on public.levelledup_admin_payment_events for select to authenticated using(public.levelledup_has_admin_role('admin'));
create policy payment_destinations_staff_read on public.levelledup_payment_destinations for select to authenticated using(public.levelledup_has_admin_role('admin'));
create policy nonpaid_entries_staff_read on public.tournament_nonpaid_stage_entries for select to authenticated using(public.levelledup_has_admin_role('admin'));

alter function public.levelledup_has_admin_role(text) owner to postgres;
alter function public.levelledup_current_admin_role() owner to postgres;
alter function public.levelledup_preserve_admin_payment_history() owner to postgres;
alter function public.levelledup_guard_staff_ownership() owner to postgres;
alter function public.levelledup_super_admin_set_tournament_admin(uuid,boolean,text,uuid) owner to postgres;
alter function public.levelledup_admin_set_payment_destination(text,text,text,text,text,uuid) owner to postgres;
alter function public.levelledup_get_payment_destination() owner to postgres;
alter function public.levelledup_snapshot_payment_destination() owner to postgres;
alter function public.levelledup_audit_payment_submission_review() owner to postgres;
alter function public.levelledup_admin_record_nonpaid_stage_entry(uuid,uuid,text,text,uuid,uuid) owner to postgres;
revoke all on function public.levelledup_has_admin_role(text),public.levelledup_current_admin_role(),
  public.levelledup_preserve_admin_payment_history(),public.levelledup_guard_staff_ownership(),
  public.levelledup_super_admin_set_tournament_admin(uuid,boolean,text,uuid),
  public.levelledup_admin_set_payment_destination(text,text,text,text,text,uuid),public.levelledup_get_payment_destination(),
  public.levelledup_snapshot_payment_destination(),public.levelledup_audit_payment_submission_review(),
  public.levelledup_admin_record_nonpaid_stage_entry(uuid,uuid,text,text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.levelledup_has_admin_role(text),public.levelledup_current_admin_role(),
  public.levelledup_super_admin_set_tournament_admin(uuid,boolean,text,uuid),
  public.levelledup_admin_set_payment_destination(text,text,text,text,text,uuid),public.levelledup_get_payment_destination(),
  public.levelledup_admin_record_nonpaid_stage_entry(uuid,uuid,text,text,uuid,uuid) to authenticated;

-- Existing refund-mode mutation still requires require_admin('super_admin').
-- No payment, paid-entry, credit, match, lobby or progression operation is replaced.
commit;
