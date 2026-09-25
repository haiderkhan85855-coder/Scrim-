# Scrims — Complete Handoff Document

Written 2026-09-25 by Buddy (rollout lead). Plain language throughout — no
jargon. If a line here conflicts with a newer approved decision, the newer
decision wins; the running log of new decisions lives in
`docs/NEW-RULES-CHANGELOG.md`.

Haider's words only for the game structure: **tournament / stage / session /
lobby / match**. A *session* is a day: it holds the matches AND the lobbies.
A *lobby* (A, B, C…) is the group of teams playing that session's matches.

---

## 1. Project snapshot

**What Scrims is.** Haider's Pakistan-first PUBG Mobile scrims platform.
Teams register for tournaments, pay per session they play, get lobbies and
room details, play matches, and the top teams qualify to the next stage.
Money moves by hand (EasyPaisa or any method the payer uses) — there is no
in-app payment gateway because the business isn't registered. Payment proof
is a screenshot + a true transaction/reference ID.

**Stack.** Next.js app + Supabase database. Screenshots live on Haider's own
Hostinger hosting; the database stores only the link.

**Repos and copies — which one is real.**

- GitHub `haiderkhan85855-coder/Scrim-` — the source of truth. Buddy pushes
  here; Haider pulls on his machines.
- `E:\Scrims` on the home PC — Haider's real project. This is home.
- `~/workspace/scrim-fixwork` — Buddy's working clone on this machine.
- `C:\Users\Admin\Desktop\Scrims` — STALE August baseline. Never use it,
  never push it.
- Remote `main` was at commit `51a7845` when this document was written.

**How we work (standing rules, never skip).**

1. **Rules first, for every file.** Before any file is created or changed:
   quote the exact handoff rule it follows, list every rule and edge case it
   must cover, name the conflicts instead of guessing, and give a
   recommendation. Haider approves — then, and only then, the file is built.
2. **One file at a time.** A migration is built, validated, pushed, attached,
   and Haider runs it in the Supabase SQL editor and reports back before the
   next file starts. "If there is a line issue, a single dot issue, you tell
   me and we fix it."
3. **Haider runs every migration himself** in the Supabase SQL editor.
   Buddy never deploys to production and never writes to the live database
   on his own.
4. **Pushing:** git-protocol pushes are rejected, so pushes go through
   `python3 ~/workspace/scrim-fixwork-bin/apipush.py`, then
   `git fetch origin main && git reset --hard origin/main` to re-sync the
   clone (the push recreates the commit hash).
5. **Every finished migration file is attached in chat** so Haider can
   download it. Never leave a migration un-delivered.
6. **`.env.local` never enters git or any archive.** Ever.
7. **Latest approved product rule overrides older docs.** When in doubt, ask
   Haider — don't guess.
8. Other projects/sites are reference-only unless Haider explicitly changes
   scope.

---

## 2. DONE — built, pushed, and confirmed

### 2a. Foundation (teams → tournaments → money → matches)

All 59 foundation migrations passed a full PostgreSQL 16 execution audit on
clean scratch databases on 2026-09-24 (pushed as `17cdd2cd`), and the paid
tournament path passed a 12/12 end-to-end test against the live Supabase
project the same day: 500 PKR tournament registration + 700 PKR session
attempt both proven (one 500 payment approves exactly one registration;
approval with only a pending payment is rejected; the 500 cannot fund the
700). Per-file SQL-editor confirmations from Haider were recorded from
`110000`/`120000` onward (see below); the foundation's green status rests on
the audit + the E2E pass.

In plain words, the foundation covers:

- **Teams & people:** player profiles, team creation, roster members, join
  requests, recruitment posts, transfers and disbanding, in-game names.
  Roles are Captain / Co-Captain / Player (the old 1+1+4 split is dead —
  up to six squad members, anyone may play any match/lobby/session).
  Team rename history is kept forever and searchable (fix 10, `091e76eb`).
  Leaving a team is request-only: the player asks, the captain approves or
  rejects — no direct self-leave, and a captain must transfer first.
  Captain-only 24/7 Support button on the team page routes into admin
  notifications.
- **Tournaments, stages, sessions, lobbies, matches:** tournaments with
  stages, sessions inside stages, lobbies inside sessions (Haider decides
  lobby count and sizes per session — e.g. 30 teams → 3 lobbies of 10),
  matches inside lobbies, match results with player data. Match lifecycle:
  scheduled → pre-match → live → completed, with cancel/reopen rules and a
  full event log. Pre-match lobby (104000): ready-check so a match can start
  sooner than the 7-minute timer (captain/co-captain only), lobby chat open
  to ANY active squad member, anti-spam max 2 messages per 30 seconds
  ("Slow down... Try again in N seconds"), labels "PlayerName from
  TeamName", admins shown as "Admin"; players never see past chats, admins
  can review closed-lobby chat.
- **Registrations & entries:** tournament registrations with time
  boundaries, roster finalization and lock, session entries (one team's
  right to play one session), the session entry lock (130000) and its fixes
  (150000), bulk entry shifting with team notifications (140000).
- **Money:** manual payments with duplicate-reference flagging for admin
  review (never auto-reject — fix 7, `5008b706` is fix 9 DNP; duplicate
  rule: only pending/verified payments reserve a reference, rejected ones
  are history), the self-approval trap (110000), mandatory payment
  screenshots (180000), session-attempt purchase (190000), free-vs-paid
  tournament contract, and the session financial contracts. Totals count
  only money-backed rows; free/earned entries never touch money math.
- **Staff & admin:** exactly one Super Admin (Haider); up to two active
  Tournament Admins (seats granted/revoked by Haider via SQL for now —
  backend exists, UI pending). Denylist permission model: admins get
  everything EXCEPT per-tournament money totals (Haider only), staff
  grant/revoke, refund-mode change, and the kill switch. A Tournament
  Admin verifying or rejecting their OWN team's payment is blocked with a
  funny message; the attempt is logged to Haider only; the payment stays
  pending for the other admin or Haider. Super Admin is exempt.
- **Notifications:** team-wide inbox (every active roster member sees team
  notifications in their profile; new joiners never see old ones; anyone
  may delete only their own view; read/unread is per person), staff/admin
  notification section (payment issues + captain-to-admin messages;
  pending-tasks bar stays separate), room/WhatsApp credential plumbing
  (105000 — partial, see §3).

### 2b. File-by-file: 110000 → 190000

**110000 — payment self-approval trap** · commit `c3d3a5f6` · Haider
confirmed it ran clean 2026-09-24.
A Tournament Admin can never verify or reject a payment for a team where
they are an active roster member. Blocked with a funny message, payment
stays pending, the attempt is logged to Haider only. Rejecting any payment
requires a reason. Super Admin (Haider) is exempt — full access on anyone's
payment, including his own squad's. (Option A confirmed.)

**120000 — lobby session-start block** · commit `1694d17f` · confirmed
2026-09-25.
Haider's words: "we cannot create the lobby when the matches of that
session has already started"; "as the first match start no new team can join
the team or lobby, they will play the next day matches." The block is
per-session (any live/completed match in THAT session → refused); cancelled
or merely scheduled matches don't block. Lobby rename/resize stays open
anytime; an empty lobby can be deleted anytime; stages stay OPEN after
tournament start; bulk lobby generation inherits the block.

**130000 — session entry lock** · commit `f26dbdf` · confirmed 2026-09-25.
No entries into started sessions ("This session is already closed."),
enforced at the captain picker, registration, payment, and approval. If the
captain picks no session at payment, the entry pins to the next open
Stage 1 session ("If you choose nothing, you will play the next session.").
Admin may move an unused entry to a later session of the SAME stage only
(never another stage). Late approval allowed while the tournament is live.
Lobby creation never mixes sessions. Consumed = the team's match went live
(lead decision — assigned team + live/completed match = consumed even with
no result yet). The team is auto-notified on every entry change. Started-
session UI: "This session is already closed." + next-stage card; next stage
closed/qualification-only → "Entries are closed for this stage." + "Top up
your team balance for the next tournament" button. One payment = one
session, paid one at a time. Outcomes: lose it, win/qualify, or never play
the whole stage → money gone (non-refundable, no credit). (Three defects
were found in this file after Haider ran it; all fixed in 150000 — see the
"single dot issue" rule in §1.)

**140000 — bulk entry shift + team notifications** · commit `e4e5531e` ·
confirmed 2026-09-25.
One admin call moves a whole list of entries to the next session (same
guards per entry as the single move: same stage only, target not started,
entry unused, team unassigned, room in target). Moves what's movable, skips
the rest with reasons, returns a moved/skipped report; re-running is safe.
Notifications are team-wide, not captain-only: fanned out to current active
roster members only (new joiners never see old ones); anyone may delete
their own view only; read/unread per person; a trigger writes the
notification automatically on every entry session change; direct table
writes refused.

**150000 — session entry lock fixes** · commit `d8bb1d7c` · confirmed
2026-09-25.
Moves are later-session-only (session numbers compared; backwards moves
refused). Late registration approval: stages stay open after tournament
start — a live tournament accepts approvals; only completed/cancelled/draft
refuse. Approval session override runs the same room check as the move
(refused when the target session's lobbies are full). Consumed = the moment
the team's match goes live.

**160000 — qualification** · commit `c1773ef` (+ changelog entry `ef29515`)
· confirmed 2026-09-25.
Each stage gets a "top N qualify" number set at creation (e.g. top 7).
`tournament_stage_qualifiers` records every qualifier: team, stage,
session, lobby, rank, points, auto or manual, who marked it. "Mark
qualifiers" (one button per session, after matches are done and results
final): per lobby, rank by total points; already-qualified teams are
SKIPPED and their slot slides down to the next team; everyone tied on
points at the cutoff qualifies (damage tiebreak is future work). One team =
one active qualification per stage — qualifying twice never creates a
second free entry. Every qualifier instantly gets a FREE entry for the next
stage's first open session; every player on the team is notified (also on
"already qualified" and on revocation). Manual mark/unmark with mandatory
reason (unmark cancels the unused free entry; played history stays). The
next-entry card: qualified → next stage first session FREE (+ paid replay
option for the stage they came from); not qualified → paid retry; nothing
left → closed + top-up. **Known bug (fix planned in 195000):** if a team
holds a paid entry in the next stage's earliest session and then qualifies,
the free entry is linked to their PAID entry — a later revocation would
cancel the paid entry and wrongly say "the unused free entry was
cancelled." (See §6.)

**170000 — permanent cancellation / credit / kill switch** · commit
`283d805` · confirmed 2026-09-25.
Two kinds of death. **Cancel & Recreate** (rebuild): NO credit; teams
migrate and money stays in play as team credit in the new tournament.
**Permanent cancellation** (no continuation): UNUSED paid entries become
credit on the TEAM (this overrode the earlier "credit to the payer's
profile" call); played-and-failed and played-and-won entries are consumed —
nothing back; free/earned entries just end. "Unused" = the team's match
never went live. Mid-tournament cancellation is allowed. A player who
leaves the team gets their own money back automatically (principle locked;
exact math parked for 200000). **Kill switch = permanent tournament
cancellation, Super Admin (Haider) only**, 4 UI steps (confirm → type
tournament ID → confirm → captcha-style check); the database re-verifies
the typed ID; cancelled is terminal and can never be reopened. **Matches
cannot be cancelled anymore** — a broken match is RECREATED (fresh match,
same lobby, teams shift automatically, every lobby player notified with
Haider's own message). **Pause button:** freezing blocks registrations,
payments, lobbies, match changes and new entries until resumed; Haider
writes the reason each time; every team is notified on pause and resume.

**180000 — mandatory payment screenshots** · commit `2bb8f20` · Haider
reported "success" 2026-09-25.
Reference ID AND screenshot are both mandatory together at submit time —
"a screenshot or no [payment]". Any payment method allowed (not just
EasyPaisa); the slip must be genuine and the ID true. Screenshots live on
Haider's Hostinger; the database stores only the link. Super-admin-only
purge (per tournament, or everything) clears links after Haider zips the
files to his own drive — the payment keeps its reference ID, payer, and
date. A guard blocks silent link deletion, blocks verification without a
screenshot, and blocks hand-flipping the exemption; only the purge clears
links. Payments from before 180000 are grandfathered (exempt) and keep
working. Captain can replace a wrong screenshot while pending. Gallery data
feed included for the app.

**190000 — session-attempt purchase (the 700)** · corrected commit
`51a7845` · Haider reported "success" 2026-09-25.
One paid entry covers exactly one session; retry = pay per session. Stage 1
has no prerequisite. First entry into stage N (N > 1) requires having
PLAYED at least one match in stage N−1 (assigned to a lobby whose match
went live/completed — not merely paying). A later stage may be skipped only
if Haider configures a direct-entry price (e.g. normal 700, direct 1050);
no direct-entry price = no skipping. The premium applies only to the first
entry without the participation chain; later retries in that stage cost the
normal session price. Qualification still gives the next stage's first
session free. Captain must choose a specific future planned/open session —
no unattached pre-buying. Admin verification automatically creates the
paid entry (one action, no forgotten second step); if the world changed
while pending (session started/full/entry exists), verification fails
loudly instead of minting a bad entry. One unresolved pending
session-attempt payment per team ("paid one at a time"). Zero-fee sessions
refuse the paid path (free claiming is separate). One normalized
bank/EasyPaisa reference backs only one LIVE (pending/verified) payment;
rejected attempts are history and never reserve the reference. Business
purpose (Haider): retry/session revenue may support larger future prize
pools and attract teams. **Correction story:** the first version failed in
Haider's SQL editor at Section 11 — his live DB held two rejected test
rows sharing reference `CODEXDUP083001` (Haider: likely forgotten Codex
testing rows, 2026-08-30, ~70 seconds apart). The strict unique index was
Buddy's mistake — it contradicted the standing 20260830 rule that only
pending/verified payments reserve a reference. Section 11 was corrected to
a partial unique index on pending/verified only; the duplicate rejected
rows stay safely as history. Scratch-validated on PostgreSQL 16 with the
exact duplicate rows present; idempotent on re-apply.

**Also done:** the roadmap (`docs/SCRIMS-ROADMAP.md`, `9887794b`), the
rules changelog (`docs/NEW-RULES-CHANGELOG.md`, created `2591d33c`), the
repair pass fixes 9 (`5008b706`: DNP for no-shows, NULL numerics out of
averages) and 10 (`091e76eb`: rename history), Haider's minimal decisions
(`4a79daa`: lobby editing stays open post-start with warning; admin
notifications cover payment issues + captain messages; captain-only 24/7
Support button; request-only leaving; 1+1+4 dead).

---

## 3. NOT DONE / PARKED — with why, and what each needs

- **104000 confirmation.** File `20260924104000_pre_match_lobby.sql`
  (pushed `aac2a058`): pre-match lobby chat + ready check. No explicit
  SQL-success confirmation recorded from Haider — to confirm with Haider.
- **105000 / 230000 product rules.** File
  `20260924105000_room_whatsapp_notifications.sql` exists in the repo
  (WhatsApp group link, room ID/password per match, publish control,
  eligibility = confirmed registration). NOT recorded as live. Needs its
  own rules pass before Haider runs it: WhatsApp scope, personal read
  state, republish behavior, clearing credentials, lobby-assignment
  eligibility. (Also note the §6 collision with 140000.)
- **200000 — top-ups & person-owned balances.** Needs a rules pass first:
  top-up ownership when several people contribute, who may spend, person
  vs team balance rules, and the EXACT leave-refund math (principle locked
  in 170000: leaving player gets their money back automatically).
- **210000 — late pending payment → credit.** Decided, NOT built. Rule:
  a payment still pending when its session starts gets approved INTO
  credit (top up the difference if the next fee is higher). Timing and
  edge conditions need a rules pass first.
- **220000 — stricter membership.** Parked (Haider: later). Two rules for
  a dedicated pass: a player cannot be in two teams in one tournament;
  one team cannot be in two tournaments.
- **230000 — room WhatsApp notification product rules.** Same open items
  as 105000 above; dedicated pass.
- **Changelog correction pass (no migration).** Fix older entries that
  overstated decided rules: "Move to credit" wording, FIFO pooled-wallet
  spending, closing triggers, paid-entry configuration, late-pending-
  payment behavior. Append-only corrections, separate approval pass.
- **Deep audit.** Parked — Haider said later.
- **Multi-lobby multi-device rules.** Parked 2026-09-25 as a separate
  future rules pass. Haider's note: with several lobbies at once (e.g. 5
  lobbies, he runs 3 across multiple devices), who-may-do-what needs its
  own rules. Not part of 195000.
- **Session finalize + picker UI (app work).** Haider's design 2026-09-25:
  a box with a + icon; he taps teams to add them, confirms, clicks
  finalize — teams receive the message on finalize. Backend queue
  numbering (195000) feeds this screen.
- **Staff management UI (app work).** Grant/revoke the two Tournament
  Admin seats — backend exists (`levelledup_super_admin_set_tournament_admin`),
  currently SQL-editor only.
- **Staff notification inbox UI (app work).**
- **Team notification UI + bulk-shift admin UI (app work).** Backend RPCs
  ready (140000).
- **Payment screenshot gallery UI + Hostinger upload integration (app
  work).** DB feed ready (180000).
- **Pause/resume, permanent-cancel confirmation, match-recreate admin
  controls, kill-switch 4-step UI (app work).** Backend ready (170000).
- **Free-claim path for zero-fee sessions.** 190000 refuses the paid path
  for fee-0 sessions; the free-claim path is a separate follow-up — folded
  into the 195000 rules pass (to confirm with Haider).
- **Lobby-assignment admin UI + operator-assignment UI (app work).**
  (Operator = an assignment ON a lobby, not a login role.)
- **Co-admin concept (Haider's, NOT in handoff, NOT in code).** Up to two
  co-admins (brother/friend): person logs in, Haider enters Gmail/UID,
  grants authority, removes anytime. Needs its own rules pass before any
  build.

---

## 4. WILL DO — the road ahead, in order

### 4a. 195000 — earned-entry claim + Haider-placed sessions **[PROPOSED — awaiting Haider's approval, NOT built]**

No file created, changed, committed, pushed, or attached. Proposed file:
`supabase/migrations/20260924195000_earned_entry_claim.sql`.

**Haider's LATEST decisions (2026-09-25) — these override the earlier
auto-placement proposal:**

- **No auto-push.** Nobody is auto-placed into sessions. Haider manually
  decides who plays in which session and which lobby. Free entries queue
  unassigned until he places them.
- **Queue numbers, first-come-first-served.** Every buy and every earn gets
  a number in order per stage, tagged paid/earned — #1 paid, #2 paid,
  #3 paid, #4 earned, #5 paid… This order is what Haider sees when placing
  teams.
- **Max teams per session, set by Haider.** 16 teams per lobby is the PUBG
  official standard (noted); how many teams per session is his call via the
  per-session number — that number is his lobby-capacity control (e.g. 2
  lobbies = 24–32 teams).
- **Stage entry close button.** One button per stage that Haider clicks
  himself when full ("i will close the manual entries on my own"), with
  the warning in his words: "Too many entries here — you can turn the
  entry off."
- **Play-for-fun.** A team holding a leftover free (earned) entry after
  qualifying may still play it for fun — scores count universally as
  normal, but qualification standing cannot change (extends the 2026-09-24
  locked rule to earned entries).
- **Paid first + purchase guard.** The paid entry is used before the earned
  one. The purchase flow must show: "You already have a FREE session — you
  earned it by qualifying. Use it before paying?" with [Use my free
  session] / [Pay anyway] (pay-anyway allowed after confirm — locked rule:
  qualified teams may buy extra attempts).
- **Leftover / lapse messaging.** If the team qualifies for stage 3 on the
  paid entry while still holding the free stage-2 entry, team page +
  notification says plainly: "You still have a FREE Stage 2 entry — play
  it in a later Stage 2 session or lose it. No refund, it cannot move to
  Stage 3." Unused earned entries lapse at stage end / tournament cancel /
  team removal with zero credit (nothing was paid).
- **160000 bugfix included.** The earned entry is always created as its own
  entry — never linked to an existing paid entry (fixes the §6 bug where
  revoking a qualification could cancel a paid entry).
- **Free vs paid marking everywhere.** Entries already carry
  paid/earned/credit/admin_grant in the DB; the mark must be visible to
  teams and admins on every entry list and the lobby screen.
- **Dropped by Haider 2026-09-25 (do NOT build):** auto-bump of free
  entries when a paid entry needs space; over-capacity auto logic. "I
  control everything… u leave that to me."
- **Session finalize + picker UI (app work, alongside):** box with + icon,
  tap teams to add, confirm, click finalize — teams receive the message on
  finalize.

**Still open inside 195000 (to confirm with Haider):**

- **The A/B.** 190000's LIVE rule says "captain must choose a specific
  session" at purchase. The new queue model says Haider places everyone.
  These two need reconciling — 190000 stays live as-is until Haider
  decides. (To confirm with Haider.)
- **Captain claim button.** Earlier proposal had a "claim my free session"
  fallback for when auto-placement failed. Under manual placement the
  queued entry may be enough — is the claim button still wanted? (To
  confirm with Haider.)
- **The reverse-order edge (old D5) is moot.** With manual placement,
  Haider puts the paid entry in the earlier session himself — no silent
  swaps needed.
- **Waiting-list auto-retry** (when a new session opens or max-teams
  rises) was part of the old auto-placement proposal; under manual
  placement its shape needs re-deciding. (To confirm with Haider.)

### 4b. After 195000 — in this order

1. **200000** — top-ups / person-owned balances + exact leave-refund math
   (rules pass first).
2. **210000** — late pending payment → credit (rules pass first).
3. **220000** — stricter membership (dedicated pass).
4. **230000** — room WhatsApp notification product rules (dedicated pass).
5. **Changelog correction pass** (append-only, separate approval).
6. **App UI batch** (§3): finalize/picker, staff management, notification
   inboxes, screenshot gallery + Hostinger upload, pause/cancel/recreate
   controls, kill-switch 4-step UI, lobby/operator assignment UI.

Each file: rules stated → Haider approves → built → validated on
PostgreSQL 16 scratch → pushed → attached → Haider runs it → "success" →
next file.

---

## 5. OPEN QUESTIONS — awaiting Haider's answers

**From 190000 (4 items — SQL success did not settle these; do NOT treat as
decided):**

1. If a price changes while a payment is pending, is the originally
   submitted amount kept?
2. Does "already entered this stage" mean an ACTIVE session entry only
   (not historical/consumed entries)?
3. Can Tournament Admins set direct-entry prices, or only Haider?
4. May a direct-entry price be any positive value, or must it sit above
   the normal price?

**From 195000:**

5. A/B: 190000's live "captain must choose a specific session" vs the new
   queue model (Haider places everyone) — which wins?
6. Under manual placement, is the captain "claim my free session" button
   still wanted, or is the queued entry enough?
7. Waiting-list auto-retry under manual placement — wanted, and in what
   shape?
8. Free-claim path for zero-fee sessions — folded into 195000 as assumed?

**From 105000/230000:**

9. WhatsApp scope, personal read state, republish behavior, clearing
   credentials, lobby-assignment eligibility.

**From the roadmap:**

10. Did `20260924104000` (pre-match lobby) run clean?
11. Match-level permanent cancellation: credit for unused entries, or not?
12. Separate freeze-everything switch: wanted, or is the kill switch enough?
13. Consumed = match-goes-live (built in 150000; lead decision — veto still
    open to Haider).

**Undecided from earlier:**

14. Kill switch scope: global vs per-tournament, in-flight requests,
    reason text, audit, UI explanation.
15. Co-admin permissions (Haider's concept): exactly what a co-admin may
    and may not do vs Haider.
16. Damage-based tiebreak for qualification ties (160000: all tied teams
    qualify for now; tiebreak is future work).

---

## 6. KNOWN ISSUES — real, recorded, not yet fixed

1. **105000 / 140000 `team_notifications` collision.** 105000 creates the
   table with `if not exists`; 140000 creates it without. A migration chain
   containing both fails at 140000. 105000 is not recorded as live and
   needs its own rules pass; scratch validation chains exclude
   `20260924105000`.
2. **Registration-fee vs session-fee validator contradiction.** 180000
   submits the selected Stage 1 session fee/currency, but an older
   validator demands the tournament's initial registration fee/currency
   (e.g. tournament registration 500 vs Stage 1 session 700) — error:
   "Payment amount and currency must equal the authoritative Tournament
   initial registration fee." Needs its own rules-first fix.
3. **Tournament-live roster-lock contradiction.** Going live locks
   finalized rosters, but the registration lifecycle validation refuses
   the update because confirmation is only allowed during
   registration-open/closed — error: "This tournament cannot confirm
   registrations now." Scratch workaround was locking finalized rosters
   before setting the tournament live. Needs its own rules-first fix.
4. **160000 paid-entry link bug.** If a team holds a paid entry in the
   next stage's earliest session and then qualifies, the grant links
   `earned_entry_id` to their PAID entry. A later revocation would cancel
   the paid entry and wrongly tell the team "the unused free entry was
   cancelled." Fix planned inside 195000: the earned entry is always its
   own entry, never linked to a paid one.

---

## 7. Glossary — Haider's terms

- **Tournament** — the whole competition (e.g. a season).
- **Stage** — a named phase of the tournament (Stage 1, Stage 2…); holds
  the per-stage settings like the entry fee and the "top N qualify" number.
- **Session** — a day. Holds that day's matches AND the lobbies. A paid
  entry covers exactly one session.
- **Lobby** — a group of teams (A, B, C…) playing a session's matches.
  Haider decides lobby count and sizes per session.
- **Match** — one game inside a lobby.
- **Paid entry** — a session entry backed by money (payment verified).
- **Free / earned entry** — one payment-free next-stage session attempt,
  earned by qualifying. Never touches money math; lapses unused at stage
  end with zero credit.
- **Queue number** — a team's place in line per stage, in buy/earn order,
  tagged paid or earned (195000, proposed).
- **Max teams (per session)** — the number Haider sets per session: how
  many teams he can manage in it (195000, proposed).
- **Entry close** — Haider's per-stage button: no more entries (195000,
  proposed).
- **Direct entry** — skipping the participation chain into a later stage
  by paying a special price Haider configures (190000, live).
- **Consumed** — an entry whose team was assigned to a lobby where a match
  went live/completed. Never movable, never credited.
- **Pending / verified / rejected (payment)** — payment states. Only
  pending and verified reserve a reference ID; rejected attempts are
  history.
- **Team credit** — money value parked on the team (e.g. from permanent
  cancellation of unused paid entries).
- **Top-up** — balance added by a player; spending rules land in 200000.
- **Kill switch** — permanent tournament cancellation, Haider only,
  4-step check, terminal.
- **DNP (Did Not Play)** — a no-show team in a match; never scored as zero.
- **Operator** — an assignment ON a lobby (not a login role).
- **Co-admin** — Haider's planned concept: up to two people he grants
  authority to (not in code yet).
