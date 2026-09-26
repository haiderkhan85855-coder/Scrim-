-- 20260924200000_team_topups_person_balances.sql
--
-- Personal balances, team contributions, fee sharing, withdrawals, and the
-- exact return/refund math.
--
-- Locked rules (Haider, 2026-09-26):
--   1. Every player holds their OWN money. A top-up lands in the player's
--      profile balance first -- never directly into a team.
--   2. Top-up: minimum 100 PKR, no maximum. Every payment record carries
--      player ID + transaction ID + screenshot. For top-ups the screenshot
--      stays in Haider's own files/drive; the transaction ID + date is the
--      lookup key, so no screenshot upload is needed in the top-up flow.
--      (The 180000 screenshot rule still stands for tournament entry and
--      session payments submitted by players.)
--   3. Haider credits top-ups from an admin section: player ID + amount +
--      transaction ID + a captcha-type confirmation. The player is notified
--      when the balance lands. A player may also submit a top-up request
--      (amount + transaction ID + which tournament section he paid through,
--      so Haider knows his intent); the transaction ID shows with a copy
--      button for Haider to verify, then he approves or rejects.
--   4. From the team page the player taps "+" and chooses "add from your own
--      credits". A player may split money across many teams (500 -> 100 to
--      Team A, 100 to Team B, 300 kept). Every rupee in a team pot is tagged
--      with the player who put it there, forever.
--   5. SEPARATION RULE: profile money and team money are two sealed boxes.
--      Fee splits and deductions touch ONLY the team pot. Nothing ever
--      auto-deducts from the profile -- the profile moves only when the
--      player himself moves it (transfer to a team, withdrawal request).
--   6. The team pot pays both tournament registration fees and
--      session-attempt fees. The fee is split EQUALLY among the players who
--      have money in the pot. Nobody pays more than they put in: a player
--      whose share exceeds his tagged balance pays only what he has, the
--      rest re-splits among the others; if the pot still cannot cover the
--      fee the payment is blocked ("short by X"). Whole paisa; leftover
--      paisa goes to the earliest contributor.
--   7. Played = wasted (lost or qualified -- khatam). Qualification never
--      returns the paid money. Leftover pot money is never wasted and
--      persists for the next tournament/session until returned.
--   8. Automatic returns, no clicks needed: player leaves/is removed ->
--      his leftover pot share goes back to his profile; tournament
--      cancelled -> each player's unused fee share goes back to THAT
--      player (never stays with the team) and the team is notified per
--      player; team disbands -> everything goes back to each contributor.
--   9. Return-all: lives in the credit section where the team total shows.
--      Captain/co-captain only, always visible. It is NEVER instant: the
--      captain's own verification/confirmation is required, then it
--      executes. At disband it is shown explicitly; clicking it or skipping
--      it leads to the same outcome (auto-return on disband).
--  10. Withdrawal: minimum 100 PKR. Player requests -> Haider approves ->
--      Haider sends the money manually via EasyPaisa.
--  11. 220000 (stricter membership) is DROPPED, both halves: a player may be
--      in two teams and both may play (even the same tournament); one team
--      may play multiple tournaments. It is up to the players how they
--      manage their matches; the backend keeps the money straight.
--  12. PARKED (do not build here): an admin "remove credit" tool with double
--      verification for Haider's mistakes, plus a credit-vs-real-money
--      reconciliation report.
--
-- Money model:
--   * levelledup_profile_balance_ledger: append-only journal of one person's
--     money. Balance = sum of deltas for (owner, currency).
--   * levelledup_team_pot_ledger: append-only journal of one team's pot,
--     every row tagged with the contributing player. A contributor's share
--     = sum of deltas for (team, contributor, currency).
--   * Fee shares reference the payment they funded, so cancellation can
--     return each rupee to the exact person who paid it.
--
-- Handoff basis: "A player who leaves the team gets their own money back
-- automatically (principle locked; exact math parked for 200000)"
-- (docs/SCRIMS-COMPLETE-HANDOFF.md). "Team credit -- money value parked on
-- the team." / "Top-up -- balance added by a player; spending rules land in
-- 200000."

begin;

-- ---------------------------------------------------------------------------
-- 1. Mark pot-funded payments on the existing payments table.
-- ---------------------------------------------------------------------------

alter table public.tournament_registration_payments
  add column if not exists funded_from_team_pot boolean not null default false;

comment on column public.tournament_registration_payments.funded_from_team_pot is
  'True when the payment was funded from the team pot (internal balance) instead of a bank transfer. The money was already verified when Haider credited the top-ups, so these payments never go through admin payment review.';

-- ---------------------------------------------------------------------------
-- 2. levelledup_topup_requests: player top-up intents + Haider''s direct credits.
-- ---------------------------------------------------------------------------

create table public.levelledup_topup_requests (
  id uuid primary key default gen_random_uuid(),
  player_profile_id uuid not null
    references public.profiles (id) on delete restrict,
  amount_minor bigint not null,
  currency text not null default 'PKR',
  transaction_id text not null,
  tournament_id uuid
    references public.tournaments (id) on delete set null,
  status text not null default 'pending',
  submitted_by uuid not null
    references auth.users (id) on delete restrict,
  reviewed_by uuid
    references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  constraint levelledup_topup_requests_amount_valid check (
    amount_minor >= 10000
  ),
  constraint levelledup_topup_requests_currency_valid check (
    currency = upper(currency) and currency ~ '^[A-Z]{3}$'
  ),
  constraint levelledup_topup_requests_transaction_valid check (
    transaction_id = btrim(transaction_id)
    and char_length(transaction_id) between 3 and 160
  ),
  constraint levelledup_topup_requests_status_valid check (
    status in ('pending', 'approved', 'rejected')
  ),
  constraint levelledup_topup_requests_idempotency_valid check (
    idempotency_key = btrim(idempotency_key)
    and char_length(idempotency_key) between 8 and 120
  ),
  constraint levelledup_topup_requests_review_valid check (
    (status = 'pending' and reviewed_by is null and reviewed_at is null)
    or (status in ('approved', 'rejected')
        and reviewed_by is not null and reviewed_at is not null)
  )
);

comment on table public.levelledup_topup_requests is
  'Top-up intents. A player submits amount + transaction ID (+ optional tournament intent); Haider approves/rejects or credits directly. Approving moves real money into the player''s profile balance.';

create unique index levelledup_topup_requests_idempotency_unique
  on public.levelledup_topup_requests (idempotency_key);

-- One live transaction ID backs at most one live top-up. A rejected request
-- frees its transaction ID for correction and resubmission.
create unique index levelledup_topup_requests_transaction_live_unique
  on public.levelledup_topup_requests (lower(transaction_id))
  where status in ('pending', 'approved');

create index levelledup_topup_requests_player_status_idx
  on public.levelledup_topup_requests (player_profile_id, status, created_at desc);

-- ---------------------------------------------------------------------------
-- 3. levelledup_withdrawal_requests: cash-out intents (min 100 PKR).
-- ---------------------------------------------------------------------------

create table public.levelledup_withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  player_profile_id uuid not null
    references public.profiles (id) on delete restrict,
  amount_minor bigint not null,
  currency text not null default 'PKR',
  easypaisa_number text not null,
  status text not null default 'pending',
  requested_by uuid not null
    references auth.users (id) on delete restrict,
  decided_by uuid
    references auth.users (id) on delete set null,
  decided_at timestamptz,
  decision_note text,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  constraint levelledup_withdrawal_requests_amount_valid check (
    amount_minor >= 10000
  ),
  constraint levelledup_withdrawal_requests_currency_valid check (
    currency = upper(currency) and currency ~ '^[A-Z]{3}$'
  ),
  constraint levelledup_withdrawal_requests_easypaisa_valid check (
    easypaisa_number = btrim(easypaisa_number)
    and char_length(easypaisa_number) between 7 and 20
  ),
  constraint levelledup_withdrawal_requests_status_valid check (
    status in ('pending', 'paid', 'rejected')
  ),
  constraint levelledup_withdrawal_requests_idempotency_valid check (
    idempotency_key = btrim(idempotency_key)
    and char_length(idempotency_key) between 8 and 120
  ),
  constraint levelledup_withdrawal_requests_decision_valid check (
    (status = 'pending' and decided_by is null and decided_at is null)
    or (status in ('paid', 'rejected')
        and decided_by is not null and decided_at is not null)
  )
);

comment on table public.levelledup_withdrawal_requests is
  'Withdrawal intents. Requesting holds the amount from the profile balance; Haider approves (he sends the money manually via EasyPaisa) or rejects (the hold is released).';

create unique index levelledup_withdrawal_requests_idempotency_unique
  on public.levelledup_withdrawal_requests (idempotency_key);

create index levelledup_withdrawal_requests_player_status_idx
  on public.levelledup_withdrawal_requests (player_profile_id, status, created_at desc);

-- ---------------------------------------------------------------------------
-- 4. levelledup_team_pot_ledger: the team pot, every rupee tagged to its player.
-- ---------------------------------------------------------------------------

create table public.levelledup_team_pot_ledger (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null
    references public.teams (id) on delete restrict,
  contributor_profile_id uuid not null
    references public.profiles (id) on delete restrict,
  event_type text not null,
  amount_delta_minor bigint not null,
  currency text not null,
  source_payment_id uuid
    references public.tournament_registration_payments (id) on delete restrict,
  related_pot_ledger_id uuid
    references public.levelledup_team_pot_ledger (id) on delete restrict,
  reason text not null,
  idempotency_key text not null,
  actor_user_id uuid not null
    references auth.users (id) on delete restrict,
  actor_role text not null,
  reversed_at timestamptz,
  provenance jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint levelledup_team_pot_ledger_event_valid check (
    event_type in ('contribution', 'fee_share', 'return_to_profile')
  ),
  constraint levelledup_team_pot_ledger_direction_valid check (
    (event_type = 'contribution' and amount_delta_minor > 0)
    or (event_type in ('fee_share', 'return_to_profile') and amount_delta_minor < 0)
  ),
  constraint levelledup_team_pot_ledger_currency_valid check (
    currency = upper(currency) and currency ~ '^[A-Z]{3}$'
  ),
  constraint levelledup_team_pot_ledger_reason_valid check (
    reason = btrim(reason) and char_length(reason) between 3 and 500
  ),
  constraint levelledup_team_pot_ledger_idempotency_valid check (
    idempotency_key = btrim(idempotency_key)
    and char_length(idempotency_key) between 8 and 160
  ),
  constraint levelledup_team_pot_ledger_fee_share_valid check (
    (event_type = 'fee_share' and source_payment_id is not null)
    or (event_type <> 'fee_share')
  )
);

comment on table public.levelledup_team_pot_ledger is
  'Append-only team-pot journal. A contributor''s share = sum of deltas for (team, contributor, currency). fee_share rows reference the payment they funded so cancellation can return each rupee to its exact contributor. reversed_at marks a fee_share whose value was returned to the contributor''s profile on cancellation.';

create unique index levelledup_team_pot_ledger_idempotency_unique
  on public.levelledup_team_pot_ledger (idempotency_key);

create index levelledup_team_pot_ledger_share_idx
  on public.levelledup_team_pot_ledger (team_id, contributor_profile_id, currency, created_at);

create index levelledup_team_pot_ledger_payment_idx
  on public.levelledup_team_pot_ledger (source_payment_id)
  where source_payment_id is not null;

-- ---------------------------------------------------------------------------
-- 5. levelledup_profile_balance_ledger: one person''s money, append-only.
-- ---------------------------------------------------------------------------

create table public.levelledup_profile_balance_ledger (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null
    references public.profiles (id) on delete restrict,
  event_type text not null,
  amount_delta_minor bigint not null,
  currency text not null,
  team_id uuid
    references public.teams (id) on delete restrict,
  topup_request_id uuid
    references public.levelledup_topup_requests (id) on delete restrict,
  withdrawal_request_id uuid
    references public.levelledup_withdrawal_requests (id) on delete restrict,
  source_pot_ledger_id uuid
    references public.levelledup_team_pot_ledger (id) on delete restrict,
  reason text not null,
  idempotency_key text not null,
  actor_user_id uuid not null
    references auth.users (id) on delete restrict,
  actor_role text not null,
  provenance jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint levelledup_profile_balance_ledger_event_valid check (
    event_type in (
      'topup', 'transfer_to_team', 'return_from_team',
      'cancellation_credit', 'withdrawal_hold', 'withdrawal_release'
    )
  ),
  constraint levelledup_profile_balance_ledger_direction_valid check (
    (event_type in (
       'topup', 'return_from_team', 'cancellation_credit', 'withdrawal_release'
     ) and amount_delta_minor > 0)
    or (event_type in ('transfer_to_team', 'withdrawal_hold')
        and amount_delta_minor < 0)
  ),
  constraint levelledup_profile_balance_ledger_currency_valid check (
    currency = upper(currency) and currency ~ '^[A-Z]{3}$'
  ),
  constraint levelledup_profile_balance_ledger_reason_valid check (
    reason = btrim(reason) and char_length(reason) between 3 and 500
  ),
  constraint levelledup_profile_balance_ledger_idempotency_valid check (
    idempotency_key = btrim(idempotency_key)
    and char_length(idempotency_key) between 8 and 160
  )
);

comment on table public.levelledup_profile_balance_ledger is
  'Append-only personal-money journal. Balance = sum of deltas for (owner, currency). The profile is only ever touched by the player''s own actions (top-up in, transfer out, withdrawal) or money coming back to him (returns, cancellation credit). Fee splits never touch this table.';

create unique index levelledup_profile_balance_ledger_idempotency_unique
  on public.levelledup_profile_balance_ledger (idempotency_key);

create index levelledup_profile_balance_ledger_owner_idx
  on public.levelledup_profile_balance_ledger (owner_profile_id, currency, created_at);

-- ---------------------------------------------------------------------------
-- 6. profile_notifications: one person''s inbox (top-ups, returns, refunds).
-- ---------------------------------------------------------------------------

create table public.profile_notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null
    references public.profiles (id) on delete cascade,
  type text not null,
  title text not null,
  message text not null,
  metadata jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint profile_notifications_type_valid check (
    type = btrim(type) and char_length(type) between 1 and 60
  ),
  constraint profile_notifications_title_valid check (
    title = btrim(title) and char_length(title) between 1 and 120
  ),
  constraint profile_notifications_message_valid check (
    message = btrim(message) and char_length(message) between 1 and 2000
  )
);

comment on table public.profile_notifications is
  'Per-person inbox. Money events (top-up credited, share returned, cancellation credit, withdrawal decided) notify the exact person whose money moved.';

create index profile_notifications_profile_created_idx
  on public.profile_notifications (profile_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 7. Append-only guards: ledger history is never rewritten.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup__forbid_ledger_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Ledger rows are append-only and cannot be changed or deleted.'
    using errcode = 'P4601';
  return null;
end;
$$;

create trigger levelledup_team_pot_ledger_no_mutation
before update or delete on public.levelledup_team_pot_ledger
for each row
execute function public.levelledup__forbid_ledger_mutation();

create trigger levelledup_profile_balance_ledger_no_mutation
before update or delete on public.levelledup_profile_balance_ledger
for each row
execute function public.levelledup__forbid_ledger_mutation();

alter function public.levelledup__forbid_ledger_mutation() owner to postgres;

-- ---------------------------------------------------------------------------
-- 8. Balance helpers (internal).
-- ---------------------------------------------------------------------------

-- One person's current balance for a currency.
create or replace function public.levelledup__profile_balance(
  p_profile_id uuid,
  p_currency text
)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(ledger.amount_delta_minor), 0::bigint)
  from public.levelledup_profile_balance_ledger as ledger
  where ledger.owner_profile_id = p_profile_id
    and ledger.currency = p_currency;
$$;

-- One contributor's current share of one team's pot.
create or replace function public.levelledup__pot_share(
  p_team_id uuid,
  p_profile_id uuid,
  p_currency text
)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(ledger.amount_delta_minor), 0::bigint)
  from public.levelledup_team_pot_ledger as ledger
  where ledger.team_id = p_team_id
    and ledger.contributor_profile_id = p_profile_id
    and ledger.currency = p_currency;
$$;

-- Captain or co-captain, active, for an explicit user (not just auth.uid()).
create or replace function public.levelledup__is_captain_or_co(
  p_team_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.team_roster_members as member
    where member.team_id = p_team_id
      and member.profile_id = p_user_id
      and member.status = 'active'
      and member.role in ('captain', 'co_captain')
  );
$$;

-- ---------------------------------------------------------------------------
-- 9. Equal fee split with caps (internal).
--
-- Splits p_fee_minor equally among every contributor holding a positive pot
-- share, earliest contributor first. Nobody pays more than his tagged share:
-- a capped player pays what he has and the rest re-splits among the others.
-- Raises P4602 "short by X" when the pot cannot cover the fee.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup__split_fee_equal(
  p_team_id uuid,
  p_fee_minor bigint,
  p_currency text
)
returns table (
  contributor_profile_id uuid,
  share_minor bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ids uuid[];
  bals bigint[];
  shares bigint[];
  contributor_count integer;
  total_balance bigint;
  remaining bigint;
  active_count integer;
  per_share bigint;
  extra_paisa bigint;
  rank_idx integer;
  i integer;
  want bigint;
  pay bigint;
  made_progress boolean;
begin
  if p_fee_minor <= 0 then
    raise exception 'The fee to split must be positive.' using errcode = 'P4603';
  end if;

  select
    array_agg(x.profile_id order by x.first_at, x.profile_id),
    array_agg(x.balance order by x.first_at, x.profile_id)
  into ids, bals
  from (
    select
      ledger.contributor_profile_id as profile_id,
      sum(ledger.amount_delta_minor) as balance,
      min(ledger.created_at) as first_at
    from public.levelledup_team_pot_ledger as ledger
    where ledger.team_id = p_team_id
      and ledger.currency = p_currency
    group by ledger.contributor_profile_id
    having sum(ledger.amount_delta_minor) > 0
  ) as x;

  if ids is null then
    raise exception 'The team pot is empty; add credits before paying a fee.'
      using errcode = 'P4604';
  end if;

  contributor_count := array_length(ids, 1);
  select coalesce(sum(b), 0::bigint) into total_balance from unnest(bals) as b;

  if total_balance < p_fee_minor then
    raise exception 'The team pot is short by % %; add more credits first.',
      (p_fee_minor - total_balance), p_currency
      using errcode = 'P4602';
  end if;

  shares := array_fill(0::bigint, array[contributor_count]);
  remaining := p_fee_minor;

  loop
    active_count := 0;
    for i in 1 .. contributor_count loop
      if bals[i] > shares[i] then
        active_count := active_count + 1;
      end if;
    end loop;

    exit when remaining <= 0 or active_count = 0;

    per_share := remaining / active_count;
    extra_paisa := remaining % active_count;
    made_progress := false;
    rank_idx := 0;

    for i in 1 .. contributor_count loop
      if bals[i] > shares[i] then
        want := per_share + case when rank_idx < extra_paisa then 1 else 0 end;
        pay := least(want, bals[i] - shares[i]);
        if pay > 0 then
          shares[i] := shares[i] + pay;
          remaining := remaining - pay;
          made_progress := true;
        end if;
        rank_idx := rank_idx + 1;
      end if;
    end loop;

    exit when not made_progress;
  end loop;

  if remaining > 0 then
    raise exception 'The team pot is short by % %; add more credits first.',
      remaining, p_currency
      using errcode = 'P4602';
  end if;

  for i in 1 .. contributor_count loop
    if shares[i] > 0 then
      contributor_profile_id := ids[i];
      share_minor := shares[i];
      return next;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Profile notification helper (internal).
-- ---------------------------------------------------------------------------

create or replace function public.levelledup__notify_profile(
  p_profile_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  notification_id uuid;
begin
  insert into public.profile_notifications
    (profile_id, type, title, message, metadata)
  values (
    p_profile_id,
    btrim(p_type), btrim(p_title), btrim(p_message),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into notification_id;

  return notification_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. Paired pot -> profile return (internal).
--
-- Moves p_amount_minor from one contributor's pot share back to his profile.
-- Used by leave/remove auto-return, disband auto-return, and the
-- captain's return-all. Idempotent per idempotency key; a zero share is a
-- silent no-op so triggers never break roster flows.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup__return_pot_share_to_profile(
  p_team_id uuid,
  p_contributor_profile_id uuid,
  p_currency text,
  p_amount_minor bigint,
  p_profile_event text,
  p_reason text,
  p_actor_user_id uuid,
  p_actor_role text,
  p_idempotency_key text
)
returns bigint
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  current_share bigint;
  team_name text;
begin
  if p_amount_minor is null or p_amount_minor <= 0 then
    return 0;
  end if;

  if p_profile_event not in ('return_from_team', 'cancellation_credit') then
    raise exception 'Unknown profile return event.' using errcode = 'P4605';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'pot-return:' || p_team_id::text || ':' || p_contributor_profile_id::text || ':' || p_currency, 0
    )
  );

  -- Idempotency: the same return is never applied twice.
  if exists (
    select 1 from public.levelledup_team_pot_ledger as ledger
    where ledger.idempotency_key = p_idempotency_key || ':pot'
  ) then
    return 0;
  end if;

  current_share := public.levelledup__pot_share(
    p_team_id, p_contributor_profile_id, p_currency
  );

  if current_share <= 0 then
    return 0;
  end if;

  if p_amount_minor > current_share then
    p_amount_minor := current_share;
  end if;

  select teams.name into team_name
  from public.teams as teams
  where teams.id = p_team_id;

  insert into public.levelledup_team_pot_ledger (
    team_id, contributor_profile_id, event_type, amount_delta_minor, currency,
    reason, idempotency_key, actor_user_id, actor_role,
    provenance
  ) values (
    p_team_id, p_contributor_profile_id, 'return_to_profile', -p_amount_minor,
    p_currency, p_reason, p_idempotency_key || ':pot',
    p_actor_user_id, p_actor_role,
    jsonb_build_object('profile_event', p_profile_event)
  );

  insert into public.levelledup_profile_balance_ledger (
    owner_profile_id, event_type, amount_delta_minor, currency, team_id,
    reason, idempotency_key, actor_user_id, actor_role,
    provenance
  ) values (
    p_contributor_profile_id, p_profile_event, p_amount_minor, p_currency,
    p_team_id, p_reason, p_idempotency_key || ':profile',
    p_actor_user_id, p_actor_role,
    jsonb_build_object('team_name', coalesce(team_name, ''))
  );

  return p_amount_minor;
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. Return one contributor's whole current pot share (internal).
-- ---------------------------------------------------------------------------

create or replace function public.levelledup__return_whole_pot_share(
  p_team_id uuid,
  p_contributor_profile_id uuid,
  p_currency text,
  p_reason text,
  p_actor_user_id uuid,
  p_actor_role text,
  p_idempotency_key text
)
returns bigint
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  current_share bigint;
begin
  current_share := public.levelledup__pot_share(
    p_team_id, p_contributor_profile_id, p_currency
  );

  if current_share <= 0 then
    return 0;
  end if;

  return public.levelledup__return_pot_share_to_profile(
    p_team_id, p_contributor_profile_id, p_currency, current_share,
    'return_from_team', p_reason, p_actor_user_id, p_actor_role,
    p_idempotency_key
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. Top-ups: player submits, Haider approves or credits directly.
-- ---------------------------------------------------------------------------

-- Player: "I paid via EasyPaisa, here is my transaction ID."
create or replace function public.levelledup_submit_topup_request(
  p_amount_minor bigint,
  p_transaction_id text,
  p_tournament_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authenticated_user_id uuid := auth.uid();
  normalized_tid text := btrim(coalesce(p_transaction_id, ''));
  normalized_key text := btrim(coalesce(p_idempotency_key, ''));
  existing public.levelledup_topup_requests;
  violated_constraint text;
begin
  if authenticated_user_id is null then
    raise exception 'Authentication is required to submit a top-up.'
      using errcode = '42501';
  end if;

  if p_amount_minor is null or p_amount_minor < 10000 then
    raise exception 'A top-up starts at 100 PKR.'
      using errcode = 'P4606';
  end if;

  if char_length(normalized_tid) not between 3 and 160 then
    raise exception 'Enter the transaction ID of your payment.'
      using errcode = 'P4607';
  end if;

  if char_length(normalized_key) not between 8 and 120 then
    raise exception 'A request key is required.' using errcode = '22023';
  end if;

  if p_tournament_id is not null
    and not exists (
      select 1 from public.tournaments as t where t.id = p_tournament_id
    ) then
    raise exception 'Tournament not found.' using errcode = 'P4013';
  end if;

  select request.* into existing
  from public.levelledup_topup_requests as request
  where request.idempotency_key = normalized_key;

  if existing.id is not null then
    return jsonb_build_object(
      'ok', true,
      'request_id', existing.id,
      'status', existing.status,
      'duplicate', true
    );
  end if;

  insert into public.levelledup_topup_requests (
    player_profile_id, amount_minor, currency, transaction_id, tournament_id,
    status, submitted_by, idempotency_key
  ) values (
    authenticated_user_id, p_amount_minor, 'PKR', normalized_tid,
    p_tournament_id, 'pending', authenticated_user_id, normalized_key
  )
  returning * into existing;

  return jsonb_build_object(
    'ok', true,
    'request_id', existing.id,
    'status', 'pending',
    'message', 'Top-up request received. The admin will verify your transaction ID and credit your balance.'
  );
exception
  when unique_violation then
    get stacked diagnostics violated_constraint = constraint_name;
    if violated_constraint = 'levelledup_topup_requests_idempotency_unique' then
      -- A concurrent call won the race; return the row it created.
      select request.* into existing
      from public.levelledup_topup_requests as request
      where request.idempotency_key = normalized_key;

      if existing.id is null then
        raise;
      end if;

      return jsonb_build_object(
        'ok', true,
        'duplicate', true,
        'request_id', existing.id,
        'status', existing.status
      );
    end if;

    raise exception 'This transaction ID is already used by a live top-up.'
      using errcode = 'P4608';
end;
$$;

comment on function public.levelledup_submit_topup_request(bigint, text, uuid, text) is
  'Player submits a top-up intent: amount + transaction ID (+ optional tournament he paid through, so Haider knows his intent). Sits pending until Haider approves or rejects.';

-- Haider: direct credit. Player ID + amount + transaction ID + his own
-- captcha-type confirmation (app-side). The screenshot stays in his drive;
-- the transaction ID + date is the lookup key.
create or replace function public.levelledup_admin_credit_topup(
  p_player_profile_id uuid,
  p_amount_minor bigint,
  p_transaction_id text,
  p_tournament_id uuid,
  p_idempotency_key text,
  p_confirmed boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  admin_id uuid := auth.uid();
  normalized_tid text := btrim(coalesce(p_transaction_id, ''));
  normalized_key text := btrim(coalesce(p_idempotency_key, ''));
  existing public.levelledup_topup_requests;
  created_request public.levelledup_topup_requests;
  violated_constraint text;
begin
  perform public.levelledup_require_admin('super_admin');

  -- The captcha-type/double confirmation happens in the app; the database
  -- refuses to credit until Haider has passed it.
  if not coalesce(p_confirmed, false) then
    raise exception 'Confirm the top-up first: this adds real money to a player''s balance.'
      using errcode = 'P4612';
  end if;

  if p_player_profile_id is null
    or not exists (
      select 1 from public.profiles as p where p.id = p_player_profile_id
    ) then
    raise exception 'Player not found.' using errcode = 'P4013';
  end if;

  if p_amount_minor is null or p_amount_minor < 10000 then
    raise exception 'A top-up starts at 100 PKR.'
      using errcode = 'P4606';
  end if;

  if char_length(normalized_tid) not between 3 and 160 then
    raise exception 'Enter the transaction ID of the payment.'
      using errcode = 'P4607';
  end if;

  if char_length(normalized_key) not between 8 and 120 then
    raise exception 'A request key is required.' using errcode = '22023';
  end if;

  select request.* into existing
  from public.levelledup_topup_requests as request
  where request.idempotency_key = normalized_key;

  if existing.id is not null then
    return jsonb_build_object(
      'ok', true,
      'request_id', existing.id,
      'status', existing.status,
      'duplicate', true
    );
  end if;

  insert into public.levelledup_topup_requests (
    player_profile_id, amount_minor, currency, transaction_id, tournament_id,
    status, submitted_by, reviewed_by, reviewed_at,
    review_note, idempotency_key
  ) values (
    p_player_profile_id, p_amount_minor, 'PKR', normalized_tid,
    p_tournament_id, 'approved', admin_id, admin_id, now(),
    'Direct credit by admin.', normalized_key
  )
  returning * into created_request;

  insert into public.levelledup_profile_balance_ledger (
    owner_profile_id, event_type, amount_delta_minor, currency,
    topup_request_id, reason, idempotency_key,
    actor_user_id, actor_role,
    provenance
  ) values (
    p_player_profile_id, 'topup', p_amount_minor, 'PKR',
    created_request.id,
    'Top-up credited by admin. Transaction ID ' || normalized_tid || '.',
    normalized_key || ':ledger',
    admin_id, 'super_admin',
    jsonb_build_object(
      'transaction_id', normalized_tid,
      'tournament_id', p_tournament_id
    )
  );

  perform public.levelledup__notify_profile(
    p_player_profile_id,
    'topup_credited',
    'Balance credited',
    'Your top-up of ' || (p_amount_minor / 100)::text || ' PKR has been added to your profile balance.',
    jsonb_build_object(
      'amount_minor', p_amount_minor,
      'currency', 'PKR',
      'transaction_id', normalized_tid
    )
  );

  return jsonb_build_object(
    'ok', true,
    'request_id', created_request.id,
    'status', 'approved',
    'amount_minor', p_amount_minor
  );
exception
  when unique_violation then
    get stacked diagnostics violated_constraint = constraint_name;
    if violated_constraint = 'levelledup_topup_requests_idempotency_unique' then
      -- A concurrent call won the race; return the row it created.
      select request.* into existing
      from public.levelledup_topup_requests as request
      where request.idempotency_key = normalized_key;

      if existing.id is null then
        raise;
      end if;

      return jsonb_build_object(
        'ok', true,
        'duplicate', true,
        'request_id', existing.id,
        'status', existing.status
      );
    end if;

    raise exception 'This transaction ID is already used by a live top-up.'
      using errcode = 'P4608';
end;
$$;

comment on function public.levelledup_admin_credit_topup(uuid, bigint, text, uuid, text, boolean) is
  'Haider''s manual top-up: player ID + amount + transaction ID (+ optional tournament intent) + his double confirmation. Credits the player''s profile balance immediately and notifies him.';

-- Haider: approve or reject a player-submitted top-up request.
create or replace function public.levelledup_admin_review_topup_request(
  p_request_id uuid,
  p_approve boolean,
  p_confirmed boolean,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  admin_id uuid := auth.uid();
  topup_request public.levelledup_topup_requests;
  normalized_note text := btrim(coalesce(p_note, ''));
begin
  perform public.levelledup_require_admin('super_admin');

  -- Approving moves real money, so the captcha-type/double confirmation is
  -- enforced here too. Rejecting only needs the reason below.
  if p_approve and not coalesce(p_confirmed, false) then
    raise exception 'Confirm the top-up first: this adds real money to a player''s balance.'
      using errcode = 'P4612';
  end if;

  select request.* into topup_request
  from public.levelledup_topup_requests as request
  where request.id = p_request_id
  for update;

  if topup_request.id is null then
    raise exception 'Top-up request not found.' using errcode = 'P4609';
  end if;

  if topup_request.status <> 'pending' then
    raise exception 'This top-up request was already decided.'
      using errcode = 'P4610';
  end if;

  if p_approve then
    update public.levelledup_topup_requests
    set status = 'approved',
        reviewed_by = admin_id,
        reviewed_at = now(),
        review_note = nullif(normalized_note, '')
    where id = topup_request.id;

    insert into public.levelledup_profile_balance_ledger (
      owner_profile_id, event_type, amount_delta_minor, currency,
      topup_request_id, reason, idempotency_key,
      actor_user_id, actor_role,
      provenance
    ) values (
      topup_request.player_profile_id, 'topup', topup_request.amount_minor,
      topup_request.currency, topup_request.id,
      'Top-up approved by admin. Transaction ID ' || topup_request.transaction_id || '.',
      'topup-review:' || topup_request.id::text || ':ledger',
      admin_id, 'super_admin',
      jsonb_build_object(
        'transaction_id', topup_request.transaction_id,
        'tournament_id', topup_request.tournament_id
      )
    );

    perform public.levelledup__notify_profile(
      topup_request.player_profile_id,
      'topup_credited',
      'Balance credited',
      'Your top-up of ' || (topup_request.amount_minor / 100)::text || ' ' || topup_request.currency || ' has been added to your profile balance.',
      jsonb_build_object(
        'amount_minor', topup_request.amount_minor,
        'currency', topup_request.currency,
        'transaction_id', topup_request.transaction_id,
        'topup_request_id', topup_request.id
      )
    );
  else
    if char_length(normalized_note) < 3 then
      raise exception 'Give a short reason for the rejection.'
        using errcode = '22023';
    end if;

    update public.levelledup_topup_requests
    set status = 'rejected',
        reviewed_by = admin_id,
        reviewed_at = now(),
        review_note = normalized_note
    where id = topup_request.id;

    perform public.levelledup__notify_profile(
      topup_request.player_profile_id,
      'topup_rejected',
      'Top-up not approved',
      'Your top-up request was not approved. Reason: ' || normalized_note,
      jsonb_build_object('topup_request_id', topup_request.id)
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'request_id', topup_request.id,
    'status', case when p_approve then 'approved' else 'rejected' end
  );
end;
$$;

comment on function public.levelledup_admin_review_topup_request(uuid, boolean, boolean, text) is
  'Haider approves (double confirmation enforced, then credits the profile balance + notifies) or rejects (reason required + notifies) a player-submitted top-up request.';

-- ---------------------------------------------------------------------------
-- 14. Transfer profile -> team pot ("add from your own credits").
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_transfer_to_team_pot(
  p_team_id uuid,
  p_amount_minor bigint,
  p_currency text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  player_id uuid := auth.uid();
  normalized_currency text := upper(btrim(coalesce(p_currency, 'PKR')));
  normalized_key text := btrim(coalesce(p_idempotency_key, ''));
  current_balance bigint;
  existing_pot public.levelledup_team_pot_ledger;
  team_name text;
begin
  if player_id is null then
    raise exception 'Authentication is required to move credits.'
      using errcode = '42501';
  end if;

  if p_team_id is null
    or not exists (
      select 1 from public.teams as t
      where t.id = p_team_id and t.status = 'active'
    ) then
    raise exception 'Team not found or not active.' using errcode = 'P3020';
  end if;

  if not public.levelledup_is_active_team_member(p_team_id) then
    raise exception 'Only an active team member can add credits to the team.'
      using errcode = '42501';
  end if;

  if normalized_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency is invalid.' using errcode = '22023';
  end if;

  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'Enter an amount greater than zero.'
      using errcode = 'P4606';
  end if;

  if char_length(normalized_key) not between 8 and 120 then
    raise exception 'A request key is required.' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('profile-move:' || player_id::text || ':' || normalized_currency, 0)
  );

  select ledger.* into existing_pot
  from public.levelledup_team_pot_ledger as ledger
  where ledger.idempotency_key = normalized_key || ':pot';

  if existing_pot.id is not null then
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'team_id', p_team_id,
      'amount_minor', p_amount_minor,
      'currency', normalized_currency
    );
  end if;

  current_balance := public.levelledup__profile_balance(
    player_id, normalized_currency
  );

  if current_balance < p_amount_minor then
    raise exception 'Your profile balance (% %) is not enough for this transfer.',
      (current_balance / 100)::text, normalized_currency
      using errcode = 'P4611';
  end if;

  select teams.name into team_name
  from public.teams as teams
  where teams.id = p_team_id;

  -- The profile moves ONLY because the player himself moved it.
  insert into public.levelledup_profile_balance_ledger (
    owner_profile_id, event_type, amount_delta_minor, currency, team_id,
    reason, idempotency_key, actor_user_id, actor_role
  ) values (
    player_id, 'transfer_to_team', -p_amount_minor, normalized_currency,
    p_team_id,
    'Moved to the team pot of "' || coalesce(team_name, '?') || '".',
    normalized_key || ':profile', player_id, 'player'
  );

  insert into public.levelledup_team_pot_ledger (
    team_id, contributor_profile_id, event_type, amount_delta_minor, currency,
    reason, idempotency_key, actor_user_id, actor_role
  ) values (
    p_team_id, player_id, 'contribution', p_amount_minor, normalized_currency,
    'Contribution from the player''s own credits.',
    normalized_key || ':pot', player_id, 'player'
  );

  perform public.levelledup__notify_profile(
    player_id,
    'team_contribution',
    'Credits added to team',
    'You added ' || (p_amount_minor / 100)::text || ' ' || normalized_currency ||
      ' to "' || coalesce(team_name, '?') || '". It stays yours until it is spent or returned.',
    jsonb_build_object(
      'team_id', p_team_id,
      'amount_minor', p_amount_minor,
      'currency', normalized_currency
    )
  );

  return jsonb_build_object(
    'ok', true,
    'team_id', p_team_id,
    'amount_minor', p_amount_minor,
    'currency', normalized_currency,
    'profile_balance_minor', current_balance - p_amount_minor
  );
end;
$$;

comment on function public.levelledup_transfer_to_team_pot(uuid, bigint, text, text) is
  'Player moves his own profile balance into a team pot (the "+" / "add from your own credits" action). Every rupee stays tagged to him. The profile is debited only by his own explicit action.';

-- ---------------------------------------------------------------------------
-- 15. Balance readers.
-- ---------------------------------------------------------------------------

-- My money: profile balance per currency + pot shares per team.
create or replace function public.levelledup_get_my_balances()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  player_id uuid := auth.uid();
begin
  if player_id is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'profile', coalesce((
      select jsonb_agg(row_to_json(x))
      from (
        select ledger.currency,
               sum(ledger.amount_delta_minor)::bigint as balance_minor
        from public.levelledup_profile_balance_ledger as ledger
        where ledger.owner_profile_id = player_id
        group by ledger.currency
      ) as x
    ), '[]'::jsonb),
    'team_pots', coalesce((
      select jsonb_agg(row_to_json(x))
      from (
        select ledger.team_id,
               teams.name as team_name,
               ledger.currency,
               sum(ledger.amount_delta_minor)::bigint as share_minor
        from public.levelledup_team_pot_ledger as ledger
        join public.teams as teams on teams.id = ledger.team_id
        where ledger.contributor_profile_id = player_id
        group by ledger.team_id, teams.name, ledger.currency
        having sum(ledger.amount_delta_minor) <> 0
      ) as x
    ), '[]'::jsonb)
  );
end;
$$;

comment on function public.levelledup_get_my_balances() is
  'My money, plainly: profile balance per currency and my tagged share of every team pot.';

-- One team's pot: total + per-contributor breakdown.
create or replace function public.levelledup_get_team_pot(
  p_team_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  player_id uuid := auth.uid();
begin
  if player_id is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  if not (
    public.levelledup_is_active_team_member(p_team_id)
    or public.levelledup_has_admin_role('admin')
  ) then
    raise exception 'You cannot view this team pot.' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'team_id', p_team_id,
    'contributors', coalesce((
      select jsonb_agg(row_to_json(x) order by x.share_minor desc)
      from (
        select ledger.contributor_profile_id as profile_id,
               coalesce(profiles.display_name, 'Player') as display_name,
               ledger.currency,
               sum(ledger.amount_delta_minor)::bigint as share_minor
        from public.levelledup_team_pot_ledger as ledger
        left join public.profiles as profiles
          on profiles.id = ledger.contributor_profile_id
        where ledger.team_id = p_team_id
        group by ledger.contributor_profile_id, profiles.display_name,
                 ledger.currency
        having sum(ledger.amount_delta_minor) <> 0
      ) as x
    ), '[]'::jsonb)
  );
end;
$$;

comment on function public.levelledup_get_team_pot(uuid) is
  'One team pot: every contributor and his tagged share. Visible to team members and admins.';

-- ---------------------------------------------------------------------------
-- 16. Pay a session-attempt fee from the team pot (captain/co-captain).
--
-- The fee is split equally among pot contributors (capped at each player's
-- tagged share). The money was already verified when Haider credited the
-- top-ups, so the payment goes pending -> verified inside one transaction;
-- that step fires the 195000 mint trigger and the entry lands in Haider's
-- queue exactly like a manual payment.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_pay_session_attempt_from_pot(
  p_registration_id uuid,
  p_stage_id uuid,
  p_preferred_session_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  captain_id uuid := auth.uid();
  normalized_key text := btrim(coalesce(p_idempotency_key, ''));
  pot_reference text;
  registration public.tournament_registrations;
  target_stage public.tournament_stages;
  preferred_session public.tournament_stage_sessions;
  pricing_session public.tournament_stage_sessions;
  prev_stage public.tournament_stages;
  already_in_stage boolean := false;
  chain_ok boolean := false;
  expected_amount bigint;
  fee_currency text;
  price_kind text;
  created_payment public.tournament_registration_payments;
  split_row record;
  share_count integer := 0;
  earned_entry_id uuid;
  warning_text text := null;
begin
  if captain_id is null then
    raise exception 'Authentication is required to pay from the team pot.'
      using errcode = '42501';
  end if;

  if char_length(normalized_key) not between 8 and 120 then
    raise exception 'A request key is required.' using errcode = '22023';
  end if;

  pot_reference := 'POT:' || substr(md5(normalized_key), 1, 24);

  -- Idempotency: the same key never pays twice.
  select payment.* into created_payment
  from public.tournament_registration_payments as payment
  where payment.reference_id = pot_reference
    and payment.payment_purpose = 'session_attempt';

  if created_payment.id is not null then
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'payment_id', created_payment.id
    );
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for share;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4013';
  end if;

  if not public.levelledup__is_captain_or_co(registration.team_id, captain_id) then
    raise exception 'Only the captain or co-captain can pay from the team pot.'
      using errcode = '42501';
  end if;

  if registration.status <> 'confirmed' then
    raise exception 'Only a confirmed registration can buy a session attempt.'
      using errcode = 'P4404';
  end if;

  select stage.* into target_stage
  from public.tournament_stages as stage
  where stage.id = p_stage_id
    and stage.tournament_id = registration.tournament_id
  for share;

  if target_stage.id is null then
    raise exception 'Stage not found.' using errcode = 'P4420';
  end if;

  if target_stage.status in ('completed', 'cancelled') then
    raise exception 'The stage is closed for new entries.'
      using errcode = 'P4420';
  end if;

  if not target_stage.entries_open then
    raise exception 'Entries are closed for this stage.'
      using errcode = 'P4420';
  end if;

  if p_preferred_session_id is not null then
    select session.* into preferred_session
    from public.tournament_stage_sessions as session
    where session.id = p_preferred_session_id
    for share;

    if preferred_session.id is null
      or preferred_session.tournament_id <> registration.tournament_id
      or preferred_session.stage_id <> target_stage.id then
      raise exception 'Preferred session not found.' using errcode = 'P4420';
    end if;

    pricing_session := preferred_session;
  else
    select sess.* into pricing_session
    from public.tournament_stage_sessions as sess
    where sess.stage_id = target_stage.id
      and sess.status in ('planned', 'open')
      and not public.levelledup_session_has_started(sess.id)
    order by sess.session_number, sess.id
    limit 1;
  end if;

  if pricing_session.id is null then
    raise exception 'This stage has no priced session yet.'
      using errcode = 'P4422';
  end if;

  if pricing_session.entry_fee_minor = 0 then
    raise exception 'This session is free; payment is not required.'
      using errcode = 'P4504';
  end if;

  -- Price: normal vs direct entry (same rule as the manual purchase flow).
  select exists (
    select 1
    from public.tournament_session_entries as entry
    where entry.registration_id = registration.id
      and entry.stage_id = target_stage.id
      and entry.status = 'active'
  ) into already_in_stage;

  if already_in_stage or target_stage.stage_number = 1 then
    expected_amount := pricing_session.entry_fee_minor;
    price_kind := 'normal';
  else
    select stage.* into prev_stage
    from public.tournament_stages as stage
    where stage.tournament_id = target_stage.tournament_id
      and stage.stage_number = target_stage.stage_number - 1
    limit 1;

    if prev_stage.id is not null then
      select exists (
        select 1
        from public.tournament_stage_assignments as assignment
        join public.tournament_matches as match
          on match.lobby_id = assignment.lobby_id
         and match.stage_id = assignment.stage_id
        where assignment.registration_id = registration.id
          and assignment.stage_id = prev_stage.id
          and assignment.status = 'assigned'
          and match.status in ('live', 'completed')
      ) into chain_ok;
    end if;

    if chain_ok then
      expected_amount := pricing_session.entry_fee_minor;
      price_kind := 'normal';
    elsif target_stage.direct_entry_fee_minor is not null then
      expected_amount := target_stage.direct_entry_fee_minor;
      price_kind := 'direct_entry';
    else
      raise exception 'Direct entry is not available for this stage yet. Play the previous stage first.'
        using errcode = 'P4422';
    end if;
  end if;

  fee_currency := pricing_session.fee_currency;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(registration.id::text || ':pot_session_payment', 0)
  );

  if exists (
    select 1
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.payment_purpose = 'session_attempt'
      and payment.status = 'pending'
  ) then
    raise exception 'Resolve your pending session payment first.'
      using errcode = 'P4505';
  end if;

  -- The split raises P4602 ("short by X") when the pot cannot cover it.
  -- Only the team pot is ever touched here -- profile money is invisible.
  --
  -- The payment is born pending and then verified in the same transaction.
  -- That pending -> verified step is what fires the standard mint trigger,
  -- so a pot-paid attempt lands in Haider's queue exactly like a manual one.
  insert into public.tournament_registration_payments (
    registration_id, tournament_id, team_id, stage_id, session_id,
    payment_method, payment_purpose, status,
    expected_amount_minor, currency,
    reference_id, submitted_by,
    screenshot_exempt, funded_from_team_pot
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    target_stage.id, preferred_session.id,
    'manual', 'session_attempt', 'pending',
    expected_amount::integer, fee_currency,
    pot_reference, captain_id,
    true, true
  )
  returning * into created_payment;

  update public.tournament_registration_payments as payment
  set status = 'verified',
      verification_source = 'admin',
      reviewed_by = captain_id,
      reviewed_at = now()
  where payment.id = created_payment.id
  returning * into created_payment;

  for split_row in
    select * from public.levelledup__split_fee_equal(
      registration.team_id, expected_amount, fee_currency
    )
  loop
    insert into public.levelledup_team_pot_ledger (
      team_id, contributor_profile_id, event_type, amount_delta_minor,
      currency, source_payment_id, reason, idempotency_key,
      actor_user_id, actor_role,
      provenance
    ) values (
      registration.team_id, split_row.contributor_profile_id, 'fee_share',
      -split_row.share_minor, fee_currency, created_payment.id,
      'Session-attempt fee share for stage "' || target_stage.display_name || '".',
      normalized_key || ':fee:' || split_row.contributor_profile_id::text,
      captain_id, 'captain',
      jsonb_build_object(
        'price_kind', price_kind,
        'payment_id', created_payment.id
      )
    );

    perform public.levelledup__notify_profile(
      split_row.contributor_profile_id,
      'fee_paid_from_pot',
      'Team fee paid',
      (split_row.share_minor / 100)::text || ' ' || fee_currency ||
        ' from your team pot share was used for the session fee (' ||
        target_stage.display_name || ').',
      jsonb_build_object(
        'team_id', registration.team_id,
        'payment_id', created_payment.id,
        'share_minor', split_row.share_minor,
        'currency', fee_currency
      )
    );

    share_count := share_count + 1;
  end loop;

  -- Paid-first info: an unused free entry already in the queue?
  select entry.id into earned_entry_id
  from public.tournament_session_entries as entry
  where entry.registration_id = registration.id
    and entry.stage_id = target_stage.id
    and entry.source_type = 'earned'
    and entry.status = 'active'
    and not public.levelledup_session_entry_consumed(entry.id)
  order by entry.created_at, entry.id
  limit 1;

  if earned_entry_id is not null then
    warning_text :=
      'Note: the team already holds an unused FREE session in the queue. The paid entry was still bought, as requested.';
  end if;

  return jsonb_build_object(
    'ok', true,
    'payment_id', created_payment.id,
    'stage_id', target_stage.id,
    'expected_amount_minor', expected_amount,
    'currency', fee_currency,
    'price_kind', price_kind,
    'contributors_charged', share_count,
    'earned_entry_warning', warning_text
  );
end;
$$;

comment on function public.levelledup_pay_session_attempt_from_pot(uuid, uuid, uuid, text) is
  'Captain/co-captain pays a session-attempt fee from the team pot. Split equally among contributors (capped at each player''s tagged share). The entry lands in the admin placement queue via the verified-payment mint trigger.';

-- ---------------------------------------------------------------------------
-- 17. Pay a tournament registration fee from the team pot.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_pay_registration_fee_from_pot(
  p_registration_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  captain_id uuid := auth.uid();
  normalized_key text := btrim(coalesce(p_idempotency_key, ''));
  pot_reference text;
  registration public.tournament_registrations;
  tournament public.tournaments;
  initial_session public.tournament_stage_sessions;
  expected_amount bigint;
  fee_currency text;
  created_payment public.tournament_registration_payments;
  split_row record;
  share_count integer := 0;
begin
  if captain_id is null then
    raise exception 'Authentication is required to pay from the team pot.'
      using errcode = '42501';
  end if;

  if char_length(normalized_key) not between 8 and 120 then
    raise exception 'A request key is required.' using errcode = '22023';
  end if;

  pot_reference := 'POT:' || substr(md5('reg:' || normalized_key), 1, 24);

  select payment.* into created_payment
  from public.tournament_registration_payments as payment
  where payment.reference_id = pot_reference
    and payment.payment_purpose = 'registration';

  if created_payment.id is not null then
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'payment_id', created_payment.id
    );
  end if;

  select current_registration.* into registration
  from public.tournament_registrations as current_registration
  where current_registration.id = p_registration_id
  for update;

  if registration.id is null then
    raise exception 'Tournament registration not found.' using errcode = 'P4013';
  end if;

  if not public.levelledup__is_captain_or_co(registration.team_id, captain_id) then
    raise exception 'Only the captain or co-captain can pay from the team pot.'
      using errcode = '42501';
  end if;

  if registration.status <> 'pending' then
    raise exception 'This registration is no longer awaiting payment.'
      using errcode = 'P4404';
  end if;

  if registration.roster_status not in ('finalized', 'locked') then
    raise exception 'Finalize the tournament squad before paying the registration fee.'
      using errcode = 'P4409';
  end if;

  -- The payment-level initial-session contract requires the exact selected
  -- Stage 1 session on every registration payment.
  select session.* into initial_session
  from public.tournament_stage_sessions as session
  where session.id = registration.initial_session_id;

  if initial_session.id is null then
    raise exception 'The registration has no selected session; select one before paying.'
      using errcode = 'P4420';
  end if;

  select tournaments.* into tournament
  from public.tournaments as tournaments
  where tournaments.id = registration.tournament_id
  for share;

  expected_amount := tournament.entry_fee_minor;
  fee_currency := tournament.currency;

  if expected_amount is null or expected_amount <= 0 then
    raise exception 'This tournament is free; payment is not required.'
      using errcode = 'P4504';
  end if;

  if exists (
    select 1
    from public.tournament_registration_payments as payment
    where payment.registration_id = registration.id
      and payment.payment_purpose = 'registration'
      and payment.status = 'verified'
  ) then
    raise exception 'This registration fee is already paid.'
      using errcode = 'P4505';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(registration.id::text || ':pot_registration_payment', 0)
  );

  insert into public.tournament_registration_payments (
    registration_id, tournament_id, team_id, stage_id, session_id,
    payment_method, payment_purpose, status,
    expected_amount_minor, currency,
    reference_id, submitted_by,
    verification_source, reviewed_by, reviewed_at,
    screenshot_exempt, funded_from_team_pot
  ) values (
    registration.id, registration.tournament_id, registration.team_id,
    initial_session.stage_id, initial_session.id,
    'manual', 'registration', 'verified',
    expected_amount::integer, fee_currency,
    pot_reference, captain_id,
    'admin', captain_id, now(),
    true, true
  )
  returning * into created_payment;

  for split_row in
    select * from public.levelledup__split_fee_equal(
      registration.team_id, expected_amount, fee_currency
    )
  loop
    insert into public.levelledup_team_pot_ledger (
      team_id, contributor_profile_id, event_type, amount_delta_minor,
      currency, source_payment_id, reason, idempotency_key,
      actor_user_id, actor_role,
      provenance
    ) values (
      registration.team_id, split_row.contributor_profile_id, 'fee_share',
      -split_row.share_minor, fee_currency, created_payment.id,
      'Tournament registration fee share for "' || tournament.name || '".',
      normalized_key || ':fee:' || split_row.contributor_profile_id::text,
      captain_id, 'captain',
      jsonb_build_object(
        'payment_id', created_payment.id,
        'tournament_id', tournament.id
      )
    );

    perform public.levelledup__notify_profile(
      split_row.contributor_profile_id,
      'fee_paid_from_pot',
      'Team fee paid',
      (split_row.share_minor / 100)::text || ' ' || fee_currency ||
        ' from your team pot share was used for the registration fee ("' ||
        tournament.name || '").',
      jsonb_build_object(
        'team_id', registration.team_id,
        'payment_id', created_payment.id,
        'share_minor', split_row.share_minor,
        'currency', fee_currency
      )
    );

    share_count := share_count + 1;
  end loop;

  -- The verified payment satisfies the confirmation guard; the lifecycle
  -- trigger assigns the slot.
  update public.tournament_registrations
  set status = 'confirmed'
  where id = registration.id;

  return jsonb_build_object(
    'ok', true,
    'payment_id', created_payment.id,
    'registration_id', registration.id,
    'expected_amount_minor', expected_amount,
    'currency', fee_currency,
    'contributors_charged', share_count
  );
end;
$$;

comment on function public.levelledup_pay_registration_fee_from_pot(uuid, text) is
  'Captain/co-captain pays a tournament registration fee from the team pot (equal split, capped per contributor) and the registration is confirmed.';

-- ---------------------------------------------------------------------------
-- 18. Return-all: captain/co-captain sends every pot rupee back to its owner.
--
-- Never instant: p_confirmed must be true -- the app sets it only after the
-- captain passes the verification/confirmation step.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_captain_return_all_from_pot(
  p_team_id uuid,
  p_confirmed boolean,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  captain_id uuid := auth.uid();
  normalized_key text := btrim(coalesce(p_idempotency_key, ''));
  team_name text;
  currency_row record;
  contributor_row record;
  notice_tournament_id uuid;
  returned_minor bigint;
  totals_by_currency jsonb := '{}'::jsonb;
  people_count integer := 0;
begin
  if captain_id is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  if not coalesce(p_confirmed, false) then
    raise exception 'Confirm the return first: this sends every rupee in the team pot back to the player who put it there.'
      using errcode = 'P4612';
  end if;

  if char_length(normalized_key) not between 8 and 120 then
    raise exception 'A request key is required.' using errcode = '22023';
  end if;

  select teams.name into team_name
  from public.teams as teams
  where teams.id = p_team_id and teams.status = 'active';

  if team_name is null then
    raise exception 'Team not found or not active.' using errcode = 'P3020';
  end if;

  if not public.levelledup__is_captain_or_co(p_team_id, captain_id) then
    raise exception 'Only the captain or co-captain can return the team pot.'
      using errcode = '42501';
  end if;

  for currency_row in
    select distinct ledger.currency
    from public.levelledup_team_pot_ledger as ledger
    where ledger.team_id = p_team_id
  loop
    for contributor_row in
      select ledger.contributor_profile_id as profile_id
      from public.levelledup_team_pot_ledger as ledger
      where ledger.team_id = p_team_id
        and ledger.currency = currency_row.currency
      group by ledger.contributor_profile_id
      having sum(ledger.amount_delta_minor) > 0
    loop
      returned_minor := public.levelledup__return_whole_pot_share(
        p_team_id,
        contributor_row.profile_id,
        currency_row.currency,
        'Return-all by the captain: every pot rupee back to its contributor.',
        captain_id,
        'captain',
        normalized_key || ':' || currency_row.currency || ':' || contributor_row.profile_id::text
      );

      if returned_minor > 0 then
        totals_by_currency := jsonb_set(
          totals_by_currency,
          array[currency_row.currency],
          to_jsonb(
            coalesce((totals_by_currency ->> currency_row.currency)::bigint, 0)
            + returned_minor
          )
        );
        people_count := people_count + 1;

        perform public.levelledup__notify_profile(
          contributor_row.profile_id,
          'pot_returned',
          'Team money returned',
          (returned_minor / 100)::text || ' ' || currency_row.currency ||
            ' was returned to your profile balance from "' ||
            coalesce(team_name, '?') || '".',
          jsonb_build_object(
            'team_id', p_team_id,
            'amount_minor', returned_minor,
            'currency', currency_row.currency
          )
        );
      end if;
    end loop;
  end loop;

  -- Team inbox notice, attached to the team's latest tournament when there is
  -- one (team notices are tournament-scoped). Every contributor already got
  -- a personal notice above.
  select registration.tournament_id into notice_tournament_id
  from public.tournament_registrations as registration
  where registration.team_id = p_team_id
  order by registration.created_at desc, registration.id desc
  limit 1;

  if notice_tournament_id is not null then
    perform public.levelledup__notify_team(
      p_team_id,
      notice_tournament_id,
      'pot_returned_all',
      'Team pot returned',
      'The captain returned the whole team pot. Every rupee went back to the player who put it in (' ||
        people_count::text || ' players).',
      jsonb_build_object('people_count', people_count)
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'team_id', p_team_id,
    'people_returned', people_count,
    'totals_by_currency', totals_by_currency
  );
end;
$$;

comment on function public.levelledup_captain_return_all_from_pot(uuid, boolean, text) is
  'Captain/co-captain only: returns the entire team pot, every rupee to the player who contributed it. Requires the captain''s explicit confirmation (never instant).';

-- ---------------------------------------------------------------------------
-- 19. Auto-return: a member who leaves / is removed / is disbanded gets his
--     leftover pot share back automatically. Fires on every roster exit path,
--     including team disband (each member''s row flips to ''disbanded'').
-- ---------------------------------------------------------------------------

create or replace function public.levelledup__auto_return_pot_on_roster_exit()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  actor_id uuid := auth.uid();
  actor_role text := 'auto';
  currency_row record;
  returned_minor bigint;
  reason_text text;
  -- A FRESH random key per status flip: a player who leaves, rejoins, and
  -- leaves again is a brand-new event and must get his new balance back.
  -- A deterministic key would silently swallow the second leave.
  event_key text := 'auto-return:' || gen_random_uuid()::text;
begin
  if old.status <> 'active'
    or new.status not in ('left', 'removed', 'disbanded') then
    return new;
  end if;

  if actor_id is null then
    actor_id := new.profile_id;
  end if;

  reason_text := case new.status
    when 'left' then 'Player left the team: his leftover pot share returned automatically.'
    when 'removed' then 'Player removed from the team: his leftover pot share returned automatically.'
    else 'Team disbanded: every contributor''s leftover pot share returned automatically.'
  end;

  for currency_row in
    select distinct ledger.currency
    from public.levelledup_team_pot_ledger as ledger
    where ledger.team_id = new.team_id
      and ledger.contributor_profile_id = new.profile_id
  loop
    returned_minor := public.levelledup__return_whole_pot_share(
      new.team_id,
      new.profile_id,
      currency_row.currency,
      reason_text,
      actor_id,
      actor_role,
      event_key || ':' || currency_row.currency
    );

    if returned_minor > 0 then
      perform public.levelledup__notify_profile(
        new.profile_id,
        'pot_returned',
        'Team money returned',
        (returned_minor / 100)::text || ' ' || currency_row.currency ||
          ' was returned to your profile balance.',
        jsonb_build_object(
          'team_id', new.team_id,
          'amount_minor', returned_minor,
          'currency', currency_row.currency,
          'reason', new.status
        )
      );
    end if;
  end loop;

  return new;
exception
  when others then
    -- The money return must never break a roster change. The app surfaces
    -- the roster result; any undistributed share stays visible in the pot.
    raise warning 'Pot auto-return skipped for team % profile %: %',
      new.team_id, new.profile_id, sqlerrm;
    return new;
end;
$$;

create trigger levelledup_roster_exit_auto_return_pot
after update of status on public.team_roster_members
for each row
execute function public.levelledup__auto_return_pot_on_roster_exit();

comment on function public.levelledup__auto_return_pot_on_roster_exit() is
  'Trigger: when a roster member exits (left/removed/disbanded), his leftover pot share returns to his profile automatically.';

-- ---------------------------------------------------------------------------
-- 20. Cancellation: pot-funded value returns to EACH contributor's profile.
--
-- Whenever any flow tries to park pot-funded value as a team credit or a
-- stage credit entitlement, this reroutes it: every fee_share goes back to
-- the exact player who paid it, and the team is notified per player.
-- Direct (bank-transfer) payments keep the old single-owner credit flow.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_return_pot_fee_shares(
  p_payment_id uuid,
  p_actor_user_id uuid,
  p_actor_role text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  source_payment public.tournament_registration_payments;
  fee_row record;
  player_name text;
  returned_count integer := 0;
  returned_total bigint := 0;
  return_currency text := null;
  players_json jsonb := '[]'::jsonb;
  ledger_key text;
begin
  if p_payment_id is null then
    raise exception 'A payment is required.' using errcode = '22023';
  end if;

  select payment.* into source_payment
  from public.tournament_registration_payments as payment
  where payment.id = p_payment_id;

  if source_payment.id is null
    or not coalesce(source_payment.funded_from_team_pot, false) then
    raise exception 'Payment is not pot-funded.' using errcode = 'P4613';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('cancel-return:' || p_payment_id::text, 0)
  );

  for fee_row in
    select ledger.*
    from public.levelledup_team_pot_ledger as ledger
    where ledger.source_payment_id = p_payment_id
      and ledger.event_type = 'fee_share'
      and ledger.reversed_at is null
    order by ledger.created_at, ledger.id
    for update
  loop
    -- The fee value already left the pot when it was paid; it now goes
    -- straight to the contributor's profile. The pot balance is untouched.
    ledger_key := 'cancel-return:' || fee_row.id::text;

    if exists (
      select 1
      from public.levelledup_profile_balance_ledger as existing
      where existing.idempotency_key = ledger_key || ':profile'
    ) then
      update public.levelledup_team_pot_ledger
      set reversed_at = now()
      where id = fee_row.id;
      continue;
    end if;

    insert into public.levelledup_profile_balance_ledger (
      owner_profile_id, event_type, amount_delta_minor, currency,
      team_id, source_pot_ledger_id,
      reason, idempotency_key, actor_user_id, actor_role,
      provenance
    ) values (
      fee_row.contributor_profile_id, 'cancellation_credit',
      -fee_row.amount_delta_minor, fee_row.currency,
      fee_row.team_id, fee_row.id,
      p_reason, ledger_key || ':profile',
      p_actor_user_id, coalesce(p_actor_role, 'system'),
      jsonb_build_object(
        'source_payment_id', p_payment_id,
        'fee_share_ledger_id', fee_row.id
      )
    );

    update public.levelledup_team_pot_ledger
    set reversed_at = now()
    where id = fee_row.id;

    select coalesce(profiles.display_name, 'Player')
    into player_name
    from public.profiles as profiles
    where profiles.id = fee_row.contributor_profile_id;

    perform public.levelledup__notify_profile(
      fee_row.contributor_profile_id,
      'cancellation_credit',
      'Unused fee returned',
      (-fee_row.amount_delta_minor / 100)::text || ' ' || fee_row.currency ||
        ' of unused fee was returned to your profile balance. ' || p_reason,
      jsonb_build_object(
        'amount_minor', -fee_row.amount_delta_minor,
        'currency', fee_row.currency,
        'team_id', fee_row.team_id,
        'source_payment_id', p_payment_id
      )
    );

    players_json := players_json || jsonb_build_object(
      'profile_id', fee_row.contributor_profile_id,
      'display_name', player_name,
      'amount_minor', -fee_row.amount_delta_minor
    );
    returned_count := returned_count + 1;
    returned_total := returned_total + (-fee_row.amount_delta_minor);
    return_currency := fee_row.currency;
  end loop;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'players_returned', returned_count,
    'total_minor', returned_total,
    'currency', return_currency,
    'players', players_json
  );
end;
$$;

comment on function public.levelledup_return_pot_fee_shares(uuid, uuid, text, text) is
  'Internal: returns each fee_share of a pot-funded payment to its contributor''s profile (cancellation path). Idempotent; marks fee_share rows reversed.';

-- Shared reroute trigger for both credit tables.
create or replace function public.levelledup__reroute_pot_funded_credit()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  source_payment public.tournament_registration_payments;
  result jsonb;
  player_elem jsonb;
  breakdown text := '';
  entry_text text;
begin
  select payment.* into source_payment
  from public.tournament_registration_payments as payment
  where payment.id = new.source_payment_id;

  if source_payment.id is null
    or not coalesce(source_payment.funded_from_team_pot, false) then
    return new;
  end if;

  -- Pot-funded: every rupee goes back to the player who paid it.
  result := public.levelledup_return_pot_fee_shares(
    source_payment.id,
    new.created_by,
    'system',
    'Tournament cancelled; unused team-pot fee returned per contributor.'
  );

  -- The team is notified that EACH PLAYER got his money back.
  for player_elem in
    select jsonb_array_elements(coalesce(result -> 'players', '[]'::jsonb))
  loop
    entry_text := (player_elem ->> 'display_name') || ' — ' ||
      ((player_elem ->> 'amount_minor')::bigint / 100)::text || ' ' ||
      coalesce(result ->> 'currency', '');
    breakdown := case when breakdown = '' then entry_text
                     else breakdown || '; ' || entry_text end;
  end loop;

  if coalesce(result ->> 'players_returned', '0') <> '0' then
    perform public.levelledup__notify_team(
      new.team_id,
      new.tournament_id,
      'cancellation_returned_per_player',
      'Unused money returned to players',
      'The tournament was cancelled. Unused team-pot money did not stay with the team -- each player got his own money back: ' ||
        breakdown || '.',
      jsonb_build_object(
        'source_payment_id', source_payment.id,
        'players_returned', result -> 'players_returned'
      )
    );
  end if;

  -- Skip the team-credit / entitlement row: there is nothing left to park.
  return null;
end;
$$;

create trigger levelledup_reroute_pot_funded_team_credit
before insert on public.tournament_team_credits
for each row
execute function public.levelledup__reroute_pot_funded_credit();

create trigger levelledup_reroute_pot_funded_stage_entitlement
before insert on public.tournament_stage_credit_entitlements
for each row
execute function public.levelledup__reroute_pot_funded_credit();

comment on function public.levelledup__reroute_pot_funded_credit() is
  'Trigger: a pot-funded payment never becomes a team credit or a stage entitlement. Its fee shares return to each contributor''s profile instead, and the team is notified per player.';

-- ---------------------------------------------------------------------------
-- 21. Withdrawals: player requests (min 100 PKR), Haider approves/rejects.
-- ---------------------------------------------------------------------------

create or replace function public.levelledup_request_withdrawal(
  p_amount_minor bigint,
  p_currency text,
  p_easypaisa_number text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  player_id uuid := auth.uid();
  normalized_currency text := upper(btrim(coalesce(p_currency, 'PKR')));
  normalized_number text := btrim(coalesce(p_easypaisa_number, ''));
  normalized_key text := btrim(coalesce(p_idempotency_key, ''));
  current_balance bigint;
  existing public.levelledup_withdrawal_requests;
begin
  if player_id is null then
    raise exception 'Authentication is required to request a withdrawal.'
      using errcode = '42501';
  end if;

  if p_amount_minor is null or p_amount_minor < 10000 then
    raise exception 'A withdrawal starts at 100 PKR.'
      using errcode = 'P4606';
  end if;

  if normalized_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency is invalid.' using errcode = '22023';
  end if;

  if char_length(normalized_number) not between 7 and 20 then
    raise exception 'Enter the EasyPaisa number the money should go to.'
      using errcode = 'P4614';
  end if;

  if char_length(normalized_key) not between 8 and 120 then
    raise exception 'A request key is required.' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('withdrawal:' || player_id::text || ':' || normalized_currency, 0)
  );

  select request.* into existing
  from public.levelledup_withdrawal_requests as request
  where request.idempotency_key = normalized_key;

  if existing.id is not null then
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'request_id', existing.id,
      'status', existing.status
    );
  end if;

  if exists (
    select 1
    from public.levelledup_withdrawal_requests as request
    where request.player_profile_id = player_id
      and request.currency = normalized_currency
      and request.status = 'pending'
  ) then
    raise exception 'You already have a pending withdrawal. Wait for it to be decided first.'
      using errcode = 'P4615';
  end if;

  current_balance := public.levelledup__profile_balance(
    player_id, normalized_currency
  );

  if current_balance < p_amount_minor then
    raise exception 'Your balance (% %) is not enough for this withdrawal.',
      (current_balance / 100)::text, normalized_currency
      using errcode = 'P4611';
  end if;

  insert into public.levelledup_withdrawal_requests (
    player_profile_id, amount_minor, currency, easypaisa_number,
    status, requested_by, idempotency_key
  ) values (
    player_id, p_amount_minor, normalized_currency, normalized_number,
    'pending', player_id, normalized_key
  )
  returning * into existing;

  -- The hold deducts the balance immediately; nothing else can spend it.
  insert into public.levelledup_profile_balance_ledger (
    owner_profile_id, event_type, amount_delta_minor, currency,
    withdrawal_request_id, reason, idempotency_key,
    actor_user_id, actor_role
  ) values (
    player_id, 'withdrawal_hold', -p_amount_minor, normalized_currency,
    existing.id,
    'Withdrawal requested; amount held until the admin decides.',
    normalized_key || ':hold', player_id, 'player'
  );

  perform public.levelledup__notify_profile(
    player_id,
    'withdrawal_requested',
    'Withdrawal requested',
    'Your withdrawal request of ' || (p_amount_minor / 100)::text || ' ' ||
      normalized_currency || ' was received. The admin will send it to ' ||
      normalized_number || '.',
    jsonb_build_object(
      'withdrawal_request_id', existing.id,
      'amount_minor', p_amount_minor,
      'currency', normalized_currency
    )
  );

  return jsonb_build_object(
    'ok', true,
    'request_id', existing.id,
    'status', 'pending',
    'amount_minor', p_amount_minor,
    'currency', normalized_currency
  );
end;
$$;

comment on function public.levelledup_request_withdrawal(bigint, text, text, text) is
  'Player requests a withdrawal (min 100 PKR). The amount is held from his profile balance until Haider approves (he sends the money via EasyPaisa) or rejects (the hold is released).';

create or replace function public.levelledup_admin_decide_withdrawal(
  p_request_id uuid,
  p_approve boolean,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  admin_id uuid := auth.uid();
  withdrawal public.levelledup_withdrawal_requests;
  normalized_note text := btrim(coalesce(p_note, ''));
begin
  perform public.levelledup_require_admin('super_admin');

  select request.* into withdrawal
  from public.levelledup_withdrawal_requests as request
  where request.id = p_request_id
  for update;

  if withdrawal.id is null then
    raise exception 'Withdrawal request not found.' using errcode = 'P4616';
  end if;

  if withdrawal.status <> 'pending' then
    raise exception 'This withdrawal was already decided.'
      using errcode = 'P4610';
  end if;

  if p_approve then
    update public.levelledup_withdrawal_requests
    set status = 'paid',
        decided_by = admin_id,
        decided_at = now(),
        decision_note = nullif(normalized_note, '')
    where id = withdrawal.id;

    perform public.levelledup__notify_profile(
      withdrawal.player_profile_id,
      'withdrawal_paid',
      'Withdrawal sent',
      'Your withdrawal of ' || (withdrawal.amount_minor / 100)::text || ' ' ||
        withdrawal.currency || ' was approved and sent to ' ||
        withdrawal.easypaisa_number || '.',
      jsonb_build_object(
        'withdrawal_request_id', withdrawal.id,
        'amount_minor', withdrawal.amount_minor,
        'currency', withdrawal.currency
      )
    );
  else
    if char_length(normalized_note) < 3 then
      raise exception 'Give a short reason for the rejection.'
        using errcode = '22023';
    end if;

    update public.levelledup_withdrawal_requests
    set status = 'rejected',
        decided_by = admin_id,
        decided_at = now(),
        decision_note = normalized_note
    where id = withdrawal.id;

    -- The hold is released: the money is spendable again.
    insert into public.levelledup_profile_balance_ledger (
      owner_profile_id, event_type, amount_delta_minor, currency,
      withdrawal_request_id, reason, idempotency_key,
      actor_user_id, actor_role
    ) values (
      withdrawal.player_profile_id, 'withdrawal_release',
      withdrawal.amount_minor, withdrawal.currency,
      withdrawal.id,
      'Withdrawal rejected; held amount released back to the balance.',
      'withdrawal-decide:' || withdrawal.id::text || ':release',
      admin_id, 'super_admin'
    );

    perform public.levelledup__notify_profile(
      withdrawal.player_profile_id,
      'withdrawal_rejected',
      'Withdrawal not approved',
      'Your withdrawal request was not approved. The held amount is back in your balance. Reason: ' ||
        normalized_note,
      jsonb_build_object('withdrawal_request_id', withdrawal.id)
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'request_id', withdrawal.id,
    'status', case when p_approve then 'paid' else 'rejected' end
  );
end;
$$;

comment on function public.levelledup_admin_decide_withdrawal(uuid, boolean, text) is
  'Haider approves (he sends the money manually via EasyPaisa) or rejects (reason required; the held amount is released) a withdrawal request.';

-- ---------------------------------------------------------------------------
-- 22. RLS: closed by default; narrow, read-mostly access.
-- ---------------------------------------------------------------------------

alter table public.levelledup_topup_requests enable row level security;
alter table public.levelledup_withdrawal_requests enable row level security;
alter table public.levelledup_team_pot_ledger enable row level security;
alter table public.levelledup_profile_balance_ledger enable row level security;
alter table public.profile_notifications enable row level security;

revoke all on table public.levelledup_topup_requests from anon, authenticated;
revoke all on table public.levelledup_withdrawal_requests from anon, authenticated;
revoke all on table public.levelledup_team_pot_ledger from anon, authenticated;
revoke all on table public.levelledup_profile_balance_ledger from anon, authenticated;
revoke all on table public.profile_notifications from anon, authenticated;

grant select on table public.levelledup_topup_requests to authenticated;
grant select on table public.levelledup_withdrawal_requests to authenticated;
grant select on table public.levelledup_team_pot_ledger to authenticated;
grant select on table public.levelledup_profile_balance_ledger to authenticated;
grant select, update, delete on table public.profile_notifications to authenticated;

-- A player reads his own top-up requests; admins read everything.
create policy "Players read own top-up requests"
  on public.levelledup_topup_requests
  for select
  to authenticated
  using (
    player_profile_id = auth.uid()
    or submitted_by = auth.uid()
    or public.levelledup_has_admin_role('admin')
  );

-- A player reads his own withdrawal requests; admins read everything.
create policy "Players read own withdrawal requests"
  on public.levelledup_withdrawal_requests
  for select
  to authenticated
  using (
    player_profile_id = auth.uid()
    or requested_by = auth.uid()
    or public.levelledup_has_admin_role('admin')
  );

-- Pot ledger: contributors read rows they are tagged on; admins read all.
-- (Team-wide pot views go through levelledup_get_team_pot.)
create policy "Contributors read own pot rows"
  on public.levelledup_team_pot_ledger
  for select
  to authenticated
  using (
    contributor_profile_id = auth.uid()
    or public.levelledup_has_admin_role('admin')
  );

-- Profile ledger: owners read their own money history; admins read all.
create policy "Owners read own balance history"
  on public.levelledup_profile_balance_ledger
  for select
  to authenticated
  using (
    owner_profile_id = auth.uid()
    or public.levelledup_has_admin_role('admin')
  );

-- Own inbox: read, mark read, delete own copies.
create policy "Owners manage own notifications"
  on public.profile_notifications
  for all
  to authenticated
  using (
    profile_id = auth.uid()
    or public.levelledup_has_admin_role('admin')
  )
  with check (
    profile_id = auth.uid()
    or public.levelledup_has_admin_role('admin')
  );

-- ---------------------------------------------------------------------------
-- 23. Function ownership and execute grants.
-- ---------------------------------------------------------------------------

-- Internal helpers: no direct execution.
do $$
declare
  fn text;
begin
  for fn in
    select unnest(array[
      'public.levelledup__forbid_ledger_mutation()',
      'public.levelledup__profile_balance(uuid, text)',
      'public.levelledup__pot_share(uuid, uuid, text)',
      'public.levelledup__is_captain_or_co(uuid, uuid)',
      'public.levelledup__split_fee_equal(uuid, bigint, text)',
      'public.levelledup__notify_profile(uuid, text, text, text, jsonb)',
      'public.levelledup__return_pot_share_to_profile(uuid, uuid, text, bigint, text, text, uuid, text, text)',
      'public.levelledup__return_whole_pot_share(uuid, uuid, text, text, uuid, text, text)',
      'public.levelledup__auto_return_pot_on_roster_exit()',
      'public.levelledup_return_pot_fee_shares(uuid, uuid, text, text)',
      'public.levelledup__reroute_pot_funded_credit()'
    ])
  loop
    execute 'alter function ' || fn || ' owner to postgres';
    execute 'revoke all on function ' || fn || ' from public, anon, authenticated';
  end loop;
end;
$$;

-- User-facing RPCs.
do $$
declare
  fn text;
begin
  for fn in
    select unnest(array[
      'public.levelledup_submit_topup_request(bigint, text, uuid, text)',
      'public.levelledup_admin_credit_topup(uuid, bigint, text, uuid, text, boolean)',
      'public.levelledup_admin_review_topup_request(uuid, boolean, boolean, text)',
      'public.levelledup_transfer_to_team_pot(uuid, bigint, text, text)',
      'public.levelledup_get_my_balances()',
      'public.levelledup_get_team_pot(uuid)',
      'public.levelledup_pay_session_attempt_from_pot(uuid, uuid, uuid, text)',
      'public.levelledup_pay_registration_fee_from_pot(uuid, text)',
      'public.levelledup_captain_return_all_from_pot(uuid, boolean, text)',
      'public.levelledup_request_withdrawal(bigint, text, text, text)',
      'public.levelledup_admin_decide_withdrawal(uuid, boolean, text)'
    ])
  loop
    execute 'alter function ' || fn || ' owner to postgres';
    execute 'revoke all on function ' || fn || ' from public, anon, authenticated';
    execute 'grant execute on function ' || fn || ' to authenticated';
  end loop;
end;
$$;

commit;
