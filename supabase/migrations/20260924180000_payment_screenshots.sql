-- 180000 — mandatory payment screenshots.
--
-- Locked product rules (Haider, 2026-09-25):
--   * Payment screenshots are mandatory on payment entry. No screenshot = no
--     payment submission. A payment can never sit in "pending" without one.
--   * Any payment method is allowed (not just EasyPaisa). The slip must be
--     genuine and the transaction / reference ID must be true. The database
--     enforces: reference ID present AND screenshot present, together, at
--     submit time. There is no "submit now, attach the screenshot later".
--   * Screenshots live on Haider's own Hostinger server; the database stores
--     only the link. Because Supabase free-tier space is limited, the
--     super-admin can purge screenshot links from the database after
--     archiving the files (zip/rar) to his own drive. A purged payment keeps
--     its reference ID, payer, and date — only the link is removed.
--   * A database guard makes the screenshot evidence strong: nothing except
--     the purge can silently delete a link, nobody can flip the exemption
--     flag by hand, and a payment cannot be verified without its screenshot
--     (unless grandfathered or purged).
--   * Payments submitted before this migration ran are grandfathered
--     (exempt) and keep working exactly as before.
--   * Only the team's captain and admins can see payment rows, so screenshots
--     ride along under the same privacy. The gallery screen itself is app
--     work; this migration provides its data feed.
--
-- Covered here:
--   1. screenshot_url / screenshot_uploaded_at / screenshot_exempt columns.
--   2. Grandfathering of every payment that exists before this file runs.
--   3. The evidence guard trigger (submit needs screenshot; verify needs
--      screenshot; links cannot be silently cleared; the exempt flag cannot
--      be flipped by hand).
--   4. New 3-argument submit: reference ID + screenshot link, both required.
--      The old 2-argument submit now fails loudly instead of letting a
--      screenshot-less payment through.
--   5. Captain can replace a wrong screenshot while the payment is pending.
--   6. Super-admin screenshot-link purge (per tournament, or everything).
--   7. Admin gallery feed listing every stored screenshot link.

begin;

-- ---------------------------------------------------------------------------
-- 1. Columns.
-- ---------------------------------------------------------------------------

alter table public.tournament_registration_payments
  add column if not exists screenshot_url text,
  add column if not exists screenshot_uploaded_at timestamptz,
  add column if not exists screenshot_exempt boolean not null default false;

-- ---------------------------------------------------------------------------
-- 2. Grandfather every payment submitted before this rule existed.
-- ---------------------------------------------------------------------------

update public.tournament_registration_payments
set screenshot_exempt = true
where screenshot_url is null
  and screenshot_exempt = false;

-- ---------------------------------------------------------------------------
-- 3. Evidence guard: the "strong links" rule, enforced by the database.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_guard_payment_screenshot_evidence()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  purge_bypass_on boolean :=
    current_setting('levelledup.screenshot_purge_bypass', true) = 'on';
  normalized_url text := btrim(coalesce(new.screenshot_url, ''));
begin
  if TG_OP = 'INSERT' then
    -- A brand-new payment with no exemption must carry its screenshot.
    if not coalesce(new.screenshot_exempt, false)
       and normalized_url = '' then
      raise exception 'A payment screenshot is required to submit a payment.'
        using errcode = 'P4509';
    end if;
    return new;
  end if;

  -- The exempt flag can only be changed by the screenshot purge (or this
  -- migration's grandfathering, which runs before this trigger exists).
  if new.screenshot_exempt is distinct from old.screenshot_exempt
     and not purge_bypass_on then
    raise exception 'The screenshot exemption can only be changed by the screenshot purge.'
      using errcode = 'P4511';
  end if;

  -- A stored screenshot link cannot be silently cleared. Only the purge
  -- (which marks the payment exempt at the same time) may remove it.
  if not purge_bypass_on
     and btrim(coalesce(old.screenshot_url, '')) <> ''
     and normalized_url = '' then
    raise exception 'Payment screenshots cannot be removed except through the screenshot purge.'
      using errcode = 'P4511';
  end if;

  -- Verification needs the evidence, unless the payment is exempt
  -- (grandfathered from before the rule, or link-purged by the super-admin).
  if new.status = 'verified'
     and old.status is distinct from 'verified'
     and normalized_url = ''
     and not coalesce(new.screenshot_exempt, false) then
    raise exception 'A payment screenshot is required before a payment can be verified.'
      using errcode = 'P4510';
  end if;

  return new;
end;
$$;

alter function public.levelledup_guard_payment_screenshot_evidence()
  owner to postgres;

drop trigger if exists trg_guard_payment_screenshot_evidence
  on public.tournament_registration_payments;

create trigger trg_guard_payment_screenshot_evidence
  before insert or update on public.tournament_registration_payments
  for each row
  execute function public.levelledup_guard_payment_screenshot_evidence();

-- ---------------------------------------------------------------------------
-- 4a. New submit: reference ID AND screenshot link, both mandatory.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_submit_manual_tournament_payment(
  p_registration_id uuid,
  p_reference_id text,
  p_screenshot_url text
)
returns public.tournament_registration_payments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_reference text := btrim(coalesce(p_reference_id, ''));
  normalized_screenshot text := btrim(coalesce(p_screenshot_url, ''));
  registration public.tournament_registrations;
  selected_session public.tournament_stage_sessions;
  selected_stage public.tournament_stages;
  created_payment public.tournament_registration_payments;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to submit payment.'
      using errcode = '42501';
  end if;

  if char_length(normalized_reference) not between 3 and 120 then
    raise exception 'Enter a valid transaction or reference ID.'
      using errcode = 'P4501';
  end if;

  -- The screenshot is mandatory: no screenshot, no payment submission.
  if normalized_screenshot = '' then
    raise exception 'A payment screenshot is required to submit a payment.'
      using errcode = 'P4509';
  end if;

  if normalized_screenshot !~* '^https?://' then
    raise exception 'The payment screenshot link must be a valid http(s) link.'
      using errcode = 'P4509';
  end if;

  if char_length(normalized_screenshot) > 2000 then
    raise exception 'The payment screenshot link is too long.'
      using errcode = 'P4509';
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4502';
  end if;

  if not public.levelledup_is_active_team_captain(registration.team_id) then
    raise exception 'Only the active team Captain can submit payment.'
      using errcode = '42501';
  end if;

  if registration.status <> 'pending'
    or registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the pending tournament Squad before submitting payment.'
      using errcode = 'P4503';
  end if;

  select session.* into selected_session
  from public.tournament_stage_sessions as session
  where session.id = registration.initial_session_id
  for share;

  select stage.* into selected_stage
  from public.tournament_stages as stage
  where stage.id = selected_session.stage_id
  for share;

  if selected_session.id is null
    or selected_session.tournament_id <> registration.tournament_id
    or selected_stage.id is null
    or selected_stage.tournament_id <> registration.tournament_id
    or selected_stage.stage_number <> 1
    or selected_stage.status in ('completed', 'cancelled') then
    raise exception 'Select an exact Stage 1 Session before submitting payment.'
      using errcode = 'P4420';
  end if;

  if selected_session.status not in ('planned', 'open')
    or (selected_session.scheduled_start_at is not null
      and selected_session.scheduled_start_at <= now()) then
    raise exception 'Payment requires a future selected Session that is open or planned for entry.'
      using errcode = 'P4421';
  end if;

  if selected_session.entry_fee_minor = 0 then
    raise exception 'The selected Session is free; payment is not required.'
      using errcode = 'P4504';
  end if;

  if selected_session.entry_fee_minor > 2147483647 then
    raise exception 'The selected Session fee exceeds the existing payment amount range.'
      using errcode = '22003';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(registration.id::text || ':payment', 0)
  );

  if exists (
    select 1
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.status in ('pending', 'verified')
  ) then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
  end if;

  insert into public.tournament_registration_payments (
    registration_id, tournament_id, team_id, session_id,
    payment_method, status, expected_amount_minor, currency,
    reference_id, submitted_by,
    screenshot_url, screenshot_uploaded_at, screenshot_exempt
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    selected_session.id, 'manual', 'pending',
    selected_session.entry_fee_minor::integer, selected_session.fee_currency,
    normalized_reference, authenticated_user_id,
    normalized_screenshot, now(), false
  ) returning * into created_payment;

  return created_payment;
exception
  when unique_violation then
    raise exception 'This registration already has a pending or verified payment.'
      using errcode = 'P4505';
end;
$$;

alter function public.levelledup_submit_manual_tournament_payment(uuid, text, text)
  owner to postgres;
revoke all on function public.levelledup_submit_manual_tournament_payment(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_submit_manual_tournament_payment(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4b. The old screenshot-less submit now fails loudly instead of letting a
--     payment through without evidence.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_submit_manual_tournament_payment(
  p_registration_id uuid,
  p_reference_id text
)
returns public.tournament_registration_payments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  raise exception 'A payment screenshot is now required. Please update the app and attach the payment screenshot.'
    using errcode = 'P4509';
  -- Unreachable; keeps the return type honest.
  return null::public.tournament_registration_payments;
end;
$$;

alter function public.levelledup_submit_manual_tournament_payment(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_submit_manual_tournament_payment(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_submit_manual_tournament_payment(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Captain can replace a wrong screenshot while the payment is pending.
--    (There is always a screenshot — this only swaps one for another.)
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_replace_payment_screenshot(
  p_payment_id uuid,
  p_screenshot_url text
)
returns public.tournament_registration_payments
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_screenshot text := btrim(coalesce(p_screenshot_url, ''));
  selected_payment public.tournament_registration_payments;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  if normalized_screenshot = '' then
    raise exception 'A payment screenshot is required.'
      using errcode = 'P4509';
  end if;

  if normalized_screenshot !~* '^https?://' then
    raise exception 'The payment screenshot link must be a valid http(s) link.'
      using errcode = 'P4509';
  end if;

  if char_length(normalized_screenshot) > 2000 then
    raise exception 'The payment screenshot link is too long.'
      using errcode = 'P4509';
  end if;

  select payments.* into selected_payment
  from public.tournament_registration_payments as payments
  where payments.id = p_payment_id
  for update;

  if selected_payment.id is null
    or selected_payment.status <> 'pending' then
    raise exception 'Only a pending payment screenshot can be replaced.'
      using errcode = 'P4507';
  end if;

  if not public.levelledup_is_active_team_captain(selected_payment.team_id) then
    raise exception 'Only the active team Captain can replace the payment screenshot.'
      using errcode = '42501';
  end if;

  update public.tournament_registration_payments
  set screenshot_url = normalized_screenshot,
      screenshot_uploaded_at = now(),
      screenshot_exempt = false
  where id = selected_payment.id
  returning * into selected_payment;

  return selected_payment;
end;
$$;

alter function public.levelledup_replace_payment_screenshot(uuid, text)
  owner to postgres;
revoke all on function public.levelledup_replace_payment_screenshot(uuid, text)
  from public, anon, authenticated;
grant execute on function public.levelledup_replace_payment_screenshot(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Super-admin screenshot-link purge. Run AFTER archiving the files from
--    the Hostinger server to a zip/rar on the drive. The payment keeps its
--    reference ID, payer, and date; only the link is removed, and the
--    payment is marked exempt so verification and history keep working.
--    Pass a tournament id to purge one tournament, or null for everything.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_super_admin_purge_payment_screenshots(
  p_tournament_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  purged_count integer := 0;
begin
  perform public.levelledup_require_admin('super_admin');

  -- Allow ONLY this function to clear links / flip the exempt flag.
  perform set_config('levelledup.screenshot_purge_bypass', 'on', true);

  with cleared as (
    update public.tournament_registration_payments as payments
    set screenshot_url = null,
        screenshot_uploaded_at = null,
        screenshot_exempt = true
    where (p_tournament_id is null
           or payments.tournament_id = p_tournament_id)
      and payments.screenshot_url is not null
    returning 1
  )
  select count(*) into purged_count from cleared;

  perform set_config('levelledup.screenshot_purge_bypass', 'off', true);

  return purged_count;
exception
  when others then
    perform set_config('levelledup.screenshot_purge_bypass', 'off', true);
    raise;
end;
$$;

alter function public.levelledup_super_admin_purge_payment_screenshots(uuid)
  owner to postgres;
revoke all on function public.levelledup_super_admin_purge_payment_screenshots(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_super_admin_purge_payment_screenshots(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Gallery feed for admins: every stored screenshot link, newest first.
--    (The gallery screen itself is app work.)
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_admin_list_payment_screenshots(
  p_tournament_id uuid
)
returns table (
  payment_id uuid,
  team_name text,
  reference_id text,
  screenshot_url text,
  status text,
  submitted_at timestamptz,
  submitted_by uuid
)
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform public.levelledup_require_admin('admin');

  return query
  select payments.id,
         teams.name,
         payments.reference_id,
         payments.screenshot_url,
         payments.status,
         payments.created_at,
         payments.submitted_by
  from public.tournament_registration_payments as payments
  join public.teams as teams
    on teams.id = payments.team_id
  where payments.tournament_id = p_tournament_id
    and payments.screenshot_url is not null
  order by payments.created_at desc;
end;
$$;

alter function public.levelledup_admin_list_payment_screenshots(uuid)
  owner to postgres;
revoke all on function public.levelledup_admin_list_payment_screenshots(uuid)
  from public, anon, authenticated;
grant execute on function public.levelledup_admin_list_payment_screenshots(uuid)
  to authenticated;

commit;
