# New Rules Changelog — decided AFTER the handoff docs

Decisions Haider made in chat on/after 2026-09-24 that are NOT in the original
handoff docs (`docs/handoff/`). Newest at the bottom. Append-only: never edit
an old entry, add a correction entry instead. If any line is wrong, Haider
says so and we fix it.

His language only: tournament / stage / session / lobby A, B — no invented terms.

---

## 2026-09-24

### Money & payments
- **Self-approval trap** (built: `20260924110000`, pushed, confirmed): a
  Tournament Admin can never verify or reject a payment for a team where they
  are an ACTIVE roster member. Blocked with a funny message, payment stays
  pending, the attempt is logged to Haider only. Rejecting any payment
  REQUIRES a 1–1000 character reason. Super Admin (Haider) is exempt — full
  approve/reject access on anyone's payment, including his own squad's.
  Option A confirmed: admins may approve other teams' payments, never their own.
- **Payment screenshots mandatory**: no screenshot = no payment submission
  (enforced once upload/storage is built — NOT built yet).
- **Paid entry is per-stage configurable at tournament creation.** Haider has
  full authority: e.g. 3 paid stages in one tournament, 1 paid entry in
  another, zero paid entry in another.
- **Late pending payment → third review option "Move to credit"** (decided,
  NOT built): automated, not manual texting. A 500 payment still pending when
  its session starts gets approved INTO the captain's credit; if the next
  stage fee is 700 he tops up 200 more. Cash refunds stay manual (EasyPaisa +
  mark refunded).
- **Team wallet / top-up balance** (decided, NOT built): two payment types —
  tournament entry fee vs balance top-up. Anyone in the team can top up; only
  captain/co-captain can spend (join). Team sees the pooled balance; spend
  uses oldest top-up first (FIFO) tracked per person. When someone leaves or
  the team disbands, their unspent remainder transfers to their own profile —
  credit goes with the person. Team pays as a unit; blocked if pooled < fee.

### Lobby / session / entry
- **Session-start block** (built: `20260924120000`, pushed, confirmed):
  "we cannot create the lobby when the matches of that session has already
  started" — block is per-session (any match live/completed in THAT session),
  not per-tournament. "as the first match start no new team can join the team
  or lobby, they will play the next day matches." Rename/resize stay editable
  anytime. "lobby can be dlted if its empty" — delete-anyway: empty lobby
  deletable anytime, even mid-tournament. Cancelled matches don't block.
- **Session entry lock** (spec approved, NOT built): trying a started session
  shows "This session is already closed." + a next-stage pay card (details +
  fee → pay). Next stage closed/qualification-only → "Entries are closed for
  this stage." + top-up button labeled "Top up your team balance for the next
  tournament". One payment = one session, paid one at a time. Session choice
  at payment is OPTIONAL — default (choose nothing) = next session; UI must
  say "If you choose nothing, you will play the next session. Choose only if
  you want to play that exact session." Entry is marked with the chosen
  session; lobbies never mix sessions; admin can override the choice. Missed
  chosen session → admin may move the mark to a later session of the SAME
  stage if room. Outcomes: lose it, win/qualify, or never played the whole
  stage → money gone (non-refundable, no credit).
- **Closing trigger** (decided): clicking START on the first match of a
  stage's last session closes the next paid entry immediately.

### Tournament management
- **Permanent cancel flow** (spec, NOT built): cancel of a tournament / stage /
  session = confirmation message → type the tournament ID → one more
  confirmation.
- **Cancel & Recreate** (spec, NOT built): a button beside Cancel (name TBD)
  → "do you want to recreate?" with 4 options (tournament, stage, session,
  match) → opens that section's create/edit tool → Create → Migrate Teams
  button moves teams to the new one. Old one is NOT deleted: everyone sees
  "disbanded", admins see who created/deleted it (even past admins).

### Staff & permissions
- **Denylist model**: Tournament Admins get every access EXCEPT carved-out
  items: per-tournament money totals (super admin only), staff grant/revoke,
  refund-mode change, the kill switch.
- **Co-admins** (Haider's concept, NOT in handoff, NOT in code): Haider can
  assign up to two co-admins (brother/friend). Flow: person logs in, Haider
  enters their Gmail or UID, grants authority, can remove anytime.
- **Simultaneous lobbies ops**: 3 lobbies can run at once (Haider + 2
  co-admins, one per lobby; or split across tournaments). Time slots like
  8–10 and 10–12. Data model supports it; ops workflow NOT built.

### Teams
- **Leaving is request-only**: member clicks 'Request to Leave' → captain
  approves (removes, history preserved) or rejects. No direct self-leave.
  Captains can't leave without transferring first.
- **1+1+4 composition is DEAD**: no enforced role split — up to six squad
  members, anyone may play any match/lobby/session.
- **Rename is captain-only**; team page shows dismissible "X was formerly
  known as Y" popup that re-fires if renamed again.
- PARKED: stricter membership — a player cannot be in two teams in a single
  tournament; one team cannot be in two tournaments. Dedicated pass later.

### Match / pre-match
- **DNP (Did Not Play)** (built): no-show teams get DNP, never zero; NULL
  numerics excluded from averages.
- **Pre-match lobby** (built: `20260924104000`): ready mark exists only so a
  match can start sooner than the 7-min timer; ANY active squad member of a
  participating team can send lobby chat; anti-spam max 2 messages per 30s
  per sender ("Slow down... Try again in N seconds"); labels "PlayerName
  from TeamName" (admins show "Admin"); admins can review a closed lobby's
  chat, players never see past chats; my-pre-match-lobbies widened so
  non-captains can reach chat. Marking ready stays captain/co-captain only.
- **Admin notification section**: covers payment issues (pending approvals +
  duplicate manual references flagged) AND captain-to-admin messages;
  pending-tasks bar stays separate; captain-only 24/7 Support button on the
  team page.

### Kill switch
- Approved ONLY in concept: super-admin-only control; Tournament Admins can
  browse but cannot write while enabled; backend enforcement. Global vs
  per-tournament scope, in-flight requests, reason, audit, UI explanation —
  all undecided.
