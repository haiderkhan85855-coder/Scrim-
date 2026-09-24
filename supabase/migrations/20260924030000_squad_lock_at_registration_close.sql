-- Fix 5: Squad lock must equal tournament registration close, not the
-- scheduled tournament start.
--
-- Handoff rule (Team & Squad): "Squad lock is intended to equal tournament
-- registration close. After lock: no new/replacement players; Captain may
-- remove a player but cannot replace them; the team may continue
-- short-handed." The locked correction section adds: "Existing historical
-- roster_lock_at behavior must be audited/migrated safely."
--
-- The old trigger defaulted roster_lock_at to scheduled_start_at. This
-- migration:
--   1. Backfills only auto-defaulted rows (roster_lock_at = scheduled_start_at,
--      which is exactly what the old trigger produced on its own) to
--      registration_closes_at. Rows where an admin or earlier logic set a
--      different explicit lock time are left untouched.
--   2. Corrects the default trigger so new tournaments lock at registration
--      close, and so the lock time follows registration_closes_at edits when
--      it was previously auto-following them.
--
-- Captain-leave rules (P3010: captain must transfer captaincy or disband
-- before leaving; P3032: a player in an active Tournament Squad cannot
-- voluntarily leave) already exist in the base migrations and are unchanged.

-- Safe backfill: only rows the old trigger auto-set to scheduled_start_at.
update public.tournaments
set roster_lock_at = registration_closes_at
where roster_lock_at = scheduled_start_at
  and registration_closes_at is not null
  and roster_lock_at is distinct from registration_closes_at;

create or replace function public.levelledup_default_tournament_roster_configuration()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  -- Keep following scheduled_start_at only when the lock was auto-set to it.
  if tg_op = 'UPDATE'
    and new.scheduled_start_at is distinct from old.scheduled_start_at
    and new.roster_lock_at is not distinct from old.roster_lock_at
    and old.roster_lock_at = old.scheduled_start_at then
    new.roster_lock_at := new.scheduled_start_at;
  end if;

  -- The corrected behavior: the lock follows registration_closes_at when it
  -- was auto-set to it.
  if tg_op = 'UPDATE'
    and new.registration_closes_at is distinct from old.registration_closes_at
    and new.roster_lock_at is not distinct from old.roster_lock_at
    and old.roster_lock_at = old.registration_closes_at then
    new.roster_lock_at := new.registration_closes_at;
  end if;

  -- Squad lock equals registration close (locked product rule). Fall back to
  -- scheduled_start_at only when registration_closes_at is somehow null.
  new.roster_lock_at := coalesce(new.roster_lock_at, new.registration_closes_at, new.scheduled_start_at);
  new.roster_min_players := coalesce(new.roster_min_players, 1);
  new.roster_max_players := coalesce(new.roster_max_players, 6);

  return new;
end;
$$;

alter function public.levelledup_default_tournament_roster_configuration()
  owner to postgres;
