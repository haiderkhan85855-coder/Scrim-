-- Fix 7: duplicate manual payment references are flagged for admin review,
-- never auto-rejected.
--
-- Handoff rule (Duplicate transaction review model): "Desired rule is flag,
-- not automatic rejection. Existing DB behavior requires redesign/migration."
-- Haider's approved rule: never auto-reject duplicate payment references;
-- flag for Haider's review showing reference ID, tournament, and submitting
-- team/sender; preserve historical payment information.
--
-- The old trigger raised P4520, refusing to store a second pending/verified
-- payment with an already-used normalized reference. Now the duplicate is
-- stored as pending and the admin payment UI flags it dynamically
-- (referenceConflict): the Verify action stays disabled on conflicted rows
-- until Haider rejects the bogus attempt, so the genuine payment can then
-- be verified. Rejected attempts remain in payment history.
-- The advisory lock is kept so concurrent duplicate submissions serialize.

create or replace function public.levelledup_guard_manual_payment_reference()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  normalized_reference text;
begin
  if new.payment_method <> 'manual' then
    return new;
  end if;

  normalized_reference :=
    public.levelledup_normalize_manual_payment_reference(new.reference_id);

  if pg_catalog.char_length(normalized_reference) not between 3 and 120 then
    raise exception 'Enter a valid transaction or reference ID.'
      using errcode = 'P4501';
  end if;

  if new.status in ('pending', 'verified') then
    -- Serialize writes on the normalized reference so two concurrent
    -- submissions cannot slip past each other. Duplicates are NOT rejected:
    -- they stay pending and are flagged for admin review in the UI.
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'manual-payment-reference:' || normalized_reference,
        0
      )
    );
  end if;

  return new;
end;
$$;

comment on function public.levelledup_guard_manual_payment_reference() is
  'Serializes manual-reference writes. Duplicate normalized references are flagged for admin review, never auto-rejected. Historical rejected attempts remain preserved.';
