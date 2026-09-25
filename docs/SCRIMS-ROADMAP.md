# Scrims — Complete Setup Roadmap

Lead: Buddy. Mandate (Haider, 2026-09-25): build the complete functioning setup,
miss nothing. One migration file at a time, in dependency order. Standing
workflow still applies: rules per file are stated before building; Haider can
veto any lead decision below.

His language only: tournament / stage / session / lobby A, B.

---

## DONE — ran clean in Haider's SQL editor

| File | What |
|---|---|
| `20260924120000` | Lobby session-start block (no lobby creation once a session's matches started) |
| `20260924130000` | Session entry lock (no entries into started sessions; admin move RPC; next-entry card) — 3 defects found after, fixed in `150000` |
| `20260924140000` | Bulk entry shift + team notifications (team-wide, profile section, per-person delete) |

---

## PHASE 1 — Entry lifecycle correctness

### File `20260924150000` — session entry lock fixes (RULES APPROVED, build next)
1. Moves only to a **later** session of the same stage (session_number
   compared; backwards moves refused). Fixes the gap where an entry could
   slide to an earlier session.
2. Registration review **allows approval after tournament start** — stages stay
   open, teams may register late; the entry lock governs session placement.
3. Approval session override gets the **same room check** the move RPC has.
4. **Consumed = the moment the team's match goes live** (lead decision, Haider
   can veto). Replaces "first result saved" — a team sitting in a live match
   with no result yet is consumed, not movable, not creditable.

### File `20260924160000` — qualification model + next-entry card (NEEDS RULES PASS)
Why: nothing in the DB records who qualified (`qualification_event_id` is
reserved/empty), so the next-entry card cannot be qualification-aware yet.
- New record: which team qualified from which stage (rank, method
  auto/manual, who marked it, audit).
- Haider sets the per-stage qualification number (e.g. top 7 per lobby).
- Proposed: auto-mark from finalized standings + manual admin mark/unmark
  (Haider confirms).
- Qualifying creates the **earned entry** for the next stage's first session
  (free), idempotent — this is the "first session of next stage FREE" rule
  fulfilled in the DB.
- Card after fix: qualified → next stage, first session free, **plus** paid
  replay of the qualified stage; not qualified → retry current stage (paid);
  next stage closed/qualification-only → closed card + top-up button.

---

## PHASE 2 — Cancellation, credit, kill switch

### File `20260924170000` — permanent cancellation + refunds + kill switch (NEEDS RULES PASS)
Locked (Haider's 5-line recap, 2026-09-25):
- **Cancel & recreate** (rebuild the tournament/stage/session) → NO credit.
  Teams migrate, money stays in play.
- **Permanent cancellation** (no intention of continuation) → credit for
  **unused paid entries only**. Played-and-failed and played-and-won are
  consumed; neither gets credit.
- Credit lands on the **payer's profile**; withdraw manually via EasyPaisa or
  use as top-up balance.
- **Kill switch = permanent tournament cancellation**, 4 verification steps:
  (1) confirmation, (2) type tournament ID, (3) another confirmation,
  (4) captcha-style final check.
- Depends on `150000` (consumed helper must be match-live accurate first).
- Open: match-level permanent cancellation (credit or not?); refund
  ownership when several people topped up; audit/history preservation;
  cancel/recreate migration mechanics.

---

## PHASE 3 — Money completeness

### File `20260924180000` — payment screenshots mandatory
Storage bucket + entry column + enforcement: no screenshot = no payment
submission. (Rule locked; build is straightforward.)

### File `20260924190000` — paid session-attempt purchase (positive 700 PKR path)
The known foundation gap: no mint path for buying a session attempt exists.
Build the purchase/mint RPC (amount derived from the session, never supplied).

### File `20260924200000` — top-ups & person-owned balances (NEEDS RULES PASS)
Top-up mechanics, who owns a balance when several people contribute, who may
spend it. Rules not yet decided — dedicated pass before building.

### File `20260924210000` — late pending payments → "Move to credit" (DECIDED, NOT BUILT)
Rule locked: a payment still pending when its session starts gets approved
INTO credit (top up the difference if the next fee is higher). Timing and
edge conditions need a rules pass before building.

---

## PHASE 4 — Integrity & ops

### File `20260924220000` — stricter membership (parked, Haider: later)
- A player cannot be in two teams in one tournament.
- One team cannot be in two tournaments.

### File `20260924230000` — room WhatsApp notification product rules
Open items from `20260924105000`: WhatsApp scope, read state, republish
behavior, clearing credentials, lobby-assignment eligibility.

### Changelog correction pass (no migration)
Fix entries that overstated decided rules: "Move to credit" wording, FIFO
pooled-wallet spending, closing triggers, paid-entry configuration,
late-pending-payment behavior. Separate approval pass, append-only
corrections.

---

## APP UI TODO (Haider's app side — backend RPCs are ready)

- Profile notification section (team notifications: read/mark-read/delete/clear)
- Bulk shift admin UI (entry list → target session → reason → report)
- Staff notification inbox UI
- Payment screenshot upload UI
- Kill switch 4-step verification UI
- Staff management UI (grant/revoke tournament admin seats)

---

## OPEN CONFIRMATIONS NEEDED FROM HAIDER

1. Did `20260924104000` (pre-match lobby) run clean? No confirmation recorded.
2. Match-level permanent cancellation: credit for unused entries, or not?
3. Separate freeze-everything switch: wanted, or is the kill switch enough?
4. Consumed timing: match-goes-live (lead recommendation in `150000`) — veto?
5. Qualification marking: automatic top-N from finalized standings, manual by
   admin, or both? (needed for `160000` rules pass)
6. Refund ownership: when several people topped up one team's balance, who
   receives cancellation credit? (needed for `170000` rules pass)

---

## EXECUTION ORDER

`150000` → `160000` (after rules pass) → `170000` (after rules pass) →
`180000` → `190000` → `200000` (after rules pass) → `210000` (after rules
pass) → `220000` → `230000` → changelog corrections.

Each file: rules stated → built → validated → pushed → attached → Haider runs
it → "success" → next file.
