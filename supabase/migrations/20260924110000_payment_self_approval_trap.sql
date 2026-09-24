-- Scrims — payment self-approval trap + staff notifications (2026-09-24)
--
-- Rules implemented (Haider-approved):
--  1. A Tournament Admin can never verify or reject a payment for a team where
--     they are an ACTIVE roster member. The attempt is blocked, the payment
--     stays pending, and the admin sees a funny message instead of a dry error.
--  2. The blocked attempt is reported ONLY to the Super Admin (who tried, which
--     team, which payment, when). No other admin sees the attempt.
--  3. So the payment does not get stuck, the Super Admin AND every other active
--     Tournament Admin get an actionable "payment needs verification" notice
--     (with no mention of the attempt).
--  4. Rejecting a payment now REQUIRES a reason message. The reason is stored
--     on the payment and sent to everyone except the rejector.
--  5. The Super Admin is exempt: only he may approve anyone's payment,
--     including his own squad's.
--  6. Payment screenshots are mandatory on payment entry (enforced when the
--     screenshot upload feature is built); rejection/verification notices
--     reference the payment the screenshot will attach to.
--
-- Design note: the blocked attempt must NOT raise an exception, because the
-- notifications are written in the same transaction and a raise would roll
-- them back. The function therefore returns a jsonb envelope:
--   {status: 'blocked', message: '<funny message>'}   -- self-approval attempt
--   {status: 'verified'|'rejected', payment_id: uuid} -- normal outcome
-- The admin UI reads the envelope and shows the message.

begin;

-- 1. Staff notification inbox. Recipients are individual staff members
--    (Super Admin / Tournament Admins), never teams.
create table if not exists public.staff_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null
    references auth.users (id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null,
  payment_id uuid
    references public.tournament_registration_payments (id) on delete cascade,
  team_id uuid
    references public.teams (id) on delete set null,
  tournament_id uuid
    references public.tournaments (id) on delete cascade,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'staff_notifications_kind_valid'
  ) then
    alter table public.staff_notifications
      add constraint staff_notifications_kind_valid check (
        kind in ('self_approval_attempt', 'payment_needs_verification', 'payment_rejected')
      );
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'staff_notifications_title_valid'
  ) then
    alter table public.staff_notifications
      add constraint staff_notifications_title_valid check (
        char_length(title) between 1 and 200
      );
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'staff_notifications_body_valid'
  ) then
    alter table public.staff_notifications
      add constraint staff_notifications_body_valid check (
        char_length(body) between 1 and 2000
      );
  end if;
end;
$$;

create index if not exists staff_notifications_recipient_created_idx
  on public.staff_notifications (recipient_user_id, created_at desc);

comment on table public.staff_notifications is
  'Staff-only inbox. self_approval_attempt is addressed to the Super Admin alone; payment_needs_verification and payment_rejected go to every active staff member except the actor.';

alter table public.staff_notifications enable row level security;

revoke all on table public.staff_notifications
  from public, anon, authenticated;

-- 2. Rejection reason lives on the payment itself for audit.
alter table public.tournament_registration_payments
  add column if not exists review_reason text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'tournament_registration_payments_review_reason_valid'
  ) then
    alter table public.tournament_registration_payments
      add constraint tournament_registration_payments_review_reason_valid check (
        review_reason is null
        or char_length(btrim(review_reason)) between 1 and 1000
      );
  end if;
end;
$$;

-- 3. Rebuild the review function: new reason parameter, self-approval trap,
--    jsonb envelope instead of raising on a blocked attempt.
--    (create or replace cannot change the return type, so drop first.)
drop function if exists public.levelledup_admin_review_tournament_payment(uuid, text);
drop function if exists public.levelledup_admin_review_tournament_payment(uuid, text, text);

create function public.levelledup_admin_review_tournament_payment(
  p_payment_id uuid,
  p_decision text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_decision text := lower(btrim(coalesce(p_decision, '')));
  trimmed_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  actor_id uuid := auth.uid();
  actor_role text;
  selected_payment public.tournament_registration_payments;
  registration_status text;
  team_name text;
  tournament_name text;
  actor_display text;
  super_admin_id uuid;
  other_staff_id uuid;
  blocked_message constant text :=
    'Nice try 😄 — you can’t approve your own team’s payment. The boss has been notified. Haha.';
begin
  perform public.levelledup_require_admin('admin');

  if normalized_decision not in ('verify', 'reject') then
    raise exception 'Unsupported payment review decision.'
      using errcode = 'P4506';
  end if;

  if normalized_decision = 'reject' and trimmed_reason is null then
    raise exception 'A reason is required to reject a payment.'
      using errcode = 'P4509';
  end if;

  if trimmed_reason is not null and char_length(trimmed_reason) > 1000 then
    raise exception 'The rejection reason is too long.'
      using errcode = '22023';
  end if;

  select payments.*
  into selected_payment
  from public.tournament_registration_payments as payments
  where payments.id = p_payment_id
  for update;

  if selected_payment.id is null
    or selected_payment.status <> 'pending'
    or selected_payment.payment_method <> 'manual' then
    raise exception 'Pending payment submission not found.'
      using errcode = 'P4507';
  end if;

  select admin_users.role
  into actor_role
  from public.admin_users as admin_users
  where admin_users.user_id = actor_id
    and admin_users.is_active;

  -- Self-approval trap: everyone except the Super Admin is completely hands-off
  -- on payments for teams where they are an active roster member.
  if actor_role is distinct from 'super_admin'
    and exists (
      select 1
      from public.team_roster_members as members
      where members.team_id = selected_payment.team_id
        and members.profile_id = actor_id
        and members.status = 'active'
    ) then
    select teams.name
    into team_name
    from public.teams as teams
    where teams.id = selected_payment.team_id;

    select tournaments.name
    into tournament_name
    from public.tournaments as tournaments
    where tournaments.id = selected_payment.tournament_id;

    select coalesce(profiles.display_name, 'An admin')
    into actor_display
    from public.profiles as profiles
    where profiles.id = actor_id;

    select admin_users.user_id
    into super_admin_id
    from public.admin_users as admin_users
    where admin_users.role = 'super_admin'
      and admin_users.is_active
    limit 1;

    -- The attempt itself is visible to the Super Admin ONLY.
    if super_admin_id is not null then
      insert into public.staff_notifications (
        recipient_user_id, kind, title, body,
        payment_id, team_id, tournament_id
      ) values (
        super_admin_id,
        'self_approval_attempt',
        'Self-approval attempt blocked',
        actor_display || ' tried to ' || normalized_decision ||
          ' the payment for their own team "' || coalesce(team_name, '?') ||
          '" (' || coalesce(tournament_name, '?') ||
          '). Blocked automatically; the payment is still pending.',
        selected_payment.id,
        selected_payment.team_id,
        selected_payment.tournament_id
      );
    end if;

    -- Everyone else on staff (except the actor) just gets a work item:
    -- this payment still needs a legitimate review. No mention of the attempt.
    for other_staff_id in
      select admin_users.user_id
      from public.admin_users as admin_users
      where admin_users.is_active
        and admin_users.user_id is distinct from actor_id
    loop
      insert into public.staff_notifications (
        recipient_user_id, kind, title, body,
        payment_id, team_id, tournament_id
      ) values (
        other_staff_id,
        'payment_needs_verification',
        'Payment needs verification',
        'The payment for team "' || coalesce(team_name, '?') ||
          '" (' || coalesce(tournament_name, '?') ||
          ') is waiting for review. Please verify it.',
        selected_payment.id,
        selected_payment.team_id,
        selected_payment.tournament_id
      );
    end loop;

    -- No raise: the notifications above must survive. The UI shows the message.
    return jsonb_build_object('status', 'blocked', 'message', blocked_message);
  end if;

  select registrations.status
  into registration_status
  from public.tournament_registrations as registrations
  where registrations.id = selected_payment.registration_id
  for share;

  if normalized_decision = 'verify' and registration_status <> 'pending' then
    raise exception 'Only a pending tournament registration can receive verified payment.'
      using errcode = 'P4503';
  end if;

  update public.tournament_registration_payments
  set
    status = case normalized_decision
      when 'verify' then 'verified'
      else 'rejected'
    end,
    verification_source = 'admin',
    review_reason = trimmed_reason,
    reviewed_by = actor_id,
    reviewed_at = now()
  where id = selected_payment.id
  returning * into selected_payment;

  -- A rejection is contestable: tell every other active staff member why,
  -- with the payment attached (the screenshot rides along once screenshot
  -- upload exists).
  if normalized_decision = 'reject' then
    select teams.name
    into team_name
    from public.teams as teams
    where teams.id = selected_payment.team_id;

    select tournaments.name
    into tournament_name
    from public.tournaments as tournaments
    where tournaments.id = selected_payment.tournament_id;

    for other_staff_id in
      select admin_users.user_id
      from public.admin_users as admin_users
      where admin_users.is_active
        and admin_users.user_id is distinct from actor_id
    loop
      insert into public.staff_notifications (
        recipient_user_id, kind, title, body,
        payment_id, team_id, tournament_id
      ) values (
        other_staff_id,
        'payment_rejected',
        'Payment rejected',
        'The payment for team "' || coalesce(team_name, '?') ||
          '" (' || coalesce(tournament_name, '?') ||
          ') was rejected. Reason: ' || trimmed_reason,
        selected_payment.id,
        selected_payment.team_id,
        selected_payment.tournament_id
      );
    end loop;
  end if;

  return jsonb_build_object(
    'status', normalized_decision,
    'payment_id', selected_payment.id
  );
end;
$$;

alter function public.levelledup_admin_review_tournament_payment(uuid, text, text)
  owner to postgres;
revoke all on function public.levelledup_admin_review_tournament_payment(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_review_tournament_payment(uuid, text, text)
  to authenticated;

comment on function public.levelledup_admin_review_tournament_payment(uuid, text, text) is
  'Admin payment review with the self-approval trap. Tournament Admins are blocked (not raised) from touching their own team''s payments; the block returns {status:''blocked''} so the attempt notification survives. Rejection requires a reason. Super Admin is exempt.';

-- 4. Staff read their own notifications.
create or replace function public.levelledup_list_my_staff_notifications()
returns setof public.staff_notifications
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  return query
  select notifications.*
  from public.staff_notifications as notifications
  where notifications.recipient_user_id = auth.uid()
  order by notifications.created_at desc;
end;
$$;

alter function public.levelledup_list_my_staff_notifications()
  owner to postgres;
revoke all on function public.levelledup_list_my_staff_notifications()
  from public, anon, authenticated;
grant execute on function public.levelledup_list_my_staff_notifications()
  to authenticated;

create or replace function public.levelledup_mark_staff_notification_read(
  p_notification_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  update public.staff_notifications
  set is_read = true
  where id = p_notification_id
    and recipient_user_id = auth.uid();
end;
$$;

alter function public.levelledup_mark_staff_notification_read(uuid)
  owner to postgres;
revoke all on function public.levelledup_mark_staff_notification_read(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_mark_staff_notification_read(uuid)
  to authenticated;

commit;
