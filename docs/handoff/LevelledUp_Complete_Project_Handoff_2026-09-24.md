# LevelledUp — Complete Project Handoff

**PUBG MOBILE Scrims & Tournament Platform | Product Rules, Architecture, Status, Audit Findings, QA, and Roadmap**  
**Status date: 24 September 2026**

## Executive decision

**Free/Paid Tournament Foundation: GREEN for the locked financial/data-contract scope.** The missing positive paid Session-attempt purchase path is an intentionally deferred feature, not a failed foundation test. Keep it explicitly listed as unimplemented/not runtime-proven. A visual check of the two labels on the real paid registration page remains a UI QA item.

The next major action is **not more feature coding**. First refresh the deep audit against the current Git tree and live schema because the previous audit predates the latest foundation work.

## Status legend
GREEN = runtime-proven for stated scope; PARTIAL = usable pieces exist but full chain is incomplete; NOT BUILT/PLANNED = approved direction without complete implementation; DECISION NEEDED = behavior must be agreed before code.

## Master status matrix

| Area | Status | Notes |
|---|---|---|
| Free/Paid Tournament financial foundation | **GREEN (foundation scope)** | Free flow runtime-proven. Paid initial-fee vs Session-price separation runtime-proven. Positive paid Session-attempt purchase remains intentionally deferred. |
| Free Tournament E2E | **GREEN** | Stage fee 0, retries off, Session fee 0, no payment/credit rows, source_type=free, negative DB guards passed. |
| Paid Tournament initial registration E2E | **GREEN** | 500 PKR initial fee stayed separate from 700 PKR Session attempt price. Pending payment approval blocked; verified payment approval passed. |
| Positive paid Session attempt / retry purchase | **PLANNED** | No captain/admin purchase/mint path yet. Backend price derivation/negative guards exist; positive purchase is not runtime-proven. |
| Admin Stages & Sessions foundation | **PARTIAL → strong base** | Core create/configure/readiness/Session pricing UI exists after foundation work; lifecycle and broader workflow still need full audit/QA. |
| Session Entries management UI | **NOT BUILT** | Backend model exists, including free/registration/paid/earned/credit/admin-grant semantics; dedicated management UI remains deferred. |
| Lobbies & Operators modern UI | **NOT BUILT** | Backend is Session-aware with operator audit history. Existing/legacy UI must be replaced or upgraded. |
| Matches & Results | **NOT BUILT / backend incomplete** | Match/result data model exists, but trusted Admin operational APIs and UI are incomplete. |
| Leaderboard / public standings | **NOT BUILT** | No trusted public standings projection yet; current public leaderboard remains intentionally non-fabricated. |
| Teams / Squad core | **PARTIAL** | Core team system works; Co-Captain model and latest Squad-lock rule still require implementation. |
| Payments / Credits / Refunds | **PARTIAL** | Backend is advanced; Admin/user operational UI is substantially incomplete. |
| Audit / Staff / Settings | **PARTIAL** | Specific audit histories and staff RPCs exist; consolidated UI and generic audit/settings model are incomplete. |
| Notifications / Support / UID lifecycle | **PLANNED** | Product rules are defined at a high level; implementation remains future work. |
| Current full-project audit | **STALE / must refresh** | A deep static audit was completed before the latest foundation changes. Re-run against the current Git tree before the next major build phase. |

## 1. Project purpose and operating model

LevelledUp is a Pakistan-first PUBG MOBILE scrims/tournament platform. The product is moving from a simple Tournament → Stage → Lobby model to a durable competition model built around exact Sessions and stable participation identities. The platform should support free and paid tournaments, progressive qualification, manual operational control, audited finance, and a mobile-first public/player/admin experience.

### Source-of-truth rule
The newest migration/product decision wins. Old fields and RPCs may remain for compatibility/history, but application UI must not continue treating legacy fields as authoritative when the newer model supersedes them.

## 2. Technical environment and repository

- Project root: `E:\Scrims`
- Framework: Next.js 16.3.1 App Router, TypeScript, Tailwind, GSAP, Lenis
- Backend: Supabase Auth + PostgreSQL + RLS + RPCs (`@supabase/supabase-js`, `@supabase/ssr`)
- Time model: Asia/Karachi for product-facing scheduling; database timestamptz remains UTC
- Current reported repo main: `56b820e29bdfef834336562cb205c9ee9f6a7214`
- Live Supabase project tested: `ekpmwzhtqpfqdztxuela`
- Migration history was reported clean Local + Remote through `20260913010000_free_paid_tournament_contract.sql`
- `.env.local` must remain private; public URL/publishable key only in browser-facing app code. Never expose a service-role key.

Backups previously created: `E:\Scrims_BACKUP_20260905` and `E:\OpenAI_Codex_AppData_Backup_20260905`. The repository has historically had a dirty working tree, so every Codex continuation must inspect current state before editing.

## 3. Core terminology and product rules

### Terminology & hierarchy

- User-facing term is Squad, not Roster. Legacy internal database names may remain where migration risk is unnecessary.
- Primary hierarchy: Tournament → Stage → Session → Session Entry/Attempt → Lobby → Match.
- Use stable UUID/public IDs for identity. Never use display names, “Match 1”, lobby letters, or team codes as the authoritative identity.
- Professional Stage names are required; do not expose generic “Stage 1/2/3” as the primary user-facing naming model.
- Mobile-first and responsive behavior is a product requirement, not a later polish item.

### Team & Squad

- A Team has a permanent public ID in the LU-XXXXXX format.
- A profile may have at most 3 active teams.
- A Team may have at most 6 active Squad members. Active membership uses stable roster_number values 1–6; historical membership rows are preserved.
- Target user-facing roles are Captain / Co-Captain / Player. Current implementation still contains older Member/Substitute semantics and must be migrated deliberately.
- Captain-only powers: remove players, disband team, transfer Captaincy / appoint Captain.
- Co-Captain target powers: accept recruitment/join requests, register for tournaments, perform payment-related actions, finalize Squad. Co-Captain does not automatically become Captain.
- Squad lock is intended to equal tournament registration close. After lock: no new/replacement players; Captain may remove a player but cannot replace them; the team may continue short-handed.
- A player in an active Tournament Squad cannot voluntarily leave; Captain removal is a separate audited action and historical Squad snapshots remain intact.

### Tournament participation — free vs paid

- Tournament classification is derived from tournaments.entry_fee_minor: 0 = FREE; >0 = PAID. Do not maintain a duplicate editable tournament-type flag unless needed for a future migration.
- Tournament entry_fee_minor is the Initial Registration Fee only. It is not the universal price for later attempts.
- Each Session owns its authoritative attempt price via tournament_stage_sessions.entry_fee_minor and fee_currency.
- Free Tournament: no normal payment flow, no credit debit for participation, Stage fee template = 0, Session fee = 0, retries disabled.
- Paid Tournament: initial registration fee is positive; Stage/Session attempt prices remain positive. Session price may differ from the initial registration fee.
- Paid initial registration creates an initial-registration entitlement, not a Session-priced retry allocation.
- Free participation uses a real free participation source, not Admin Grant.
- Admin Grant remains exceptional/manual access only, not the normal route for free tournaments.

### Retries & earned advancement

- Free tournaments have no retries.
- Paid tournaments may allow retries only where the Stage rules permit them. Any retry/extra attempt is paid at the exact Session price.
- A team that succeeds in a previous Session/Stage earns exactly one payment-free attempt in the next Stage.
- Earned qualification does not set the next Session price to zero and does not create unlimited free entries.
- A team that is already qualified but chooses to play another attempt must pay for that additional attempt.
- Admin configures how many teams advance (for example top 6 or top 7) after the Session/day’s matches. The advancement engine itself is not implemented yet.
- Provisional standings should be calculated first; Admin confirms/publishes advancement. Manual override must preserve reason, Admin identity, timestamp, and history.
- Tie-breaker rules are not finalized and must be discussed before implementation.

### Payments, credits & refunds

- Manual payment exists today. Gateway schema exists, but Stripe integration is not implemented yet.
- Initial registration payment amount must be derived by trusted backend logic from the Tournament; callers do not supply the authoritative amount.
- Future Session attempt purchases must derive the amount from the exact Session; arbitrary caller-supplied amounts are not permitted.
- Original payer/source provenance is permanent. Team-operational use of credit must never erase original ownership/provenance.
- While a team is active, operational Team Credit is intended to be usable by Captain + Co-Captain. Co-Captain implementation is pending.
- If a team disbands, unused credit should become directly available to the original payer. Captaincy transfer must not change financial provenance.
- Before registration close, Captain withdrawal/disband may create credit for unused eligible paid entries. At/after registration close there is no normal Captain refund.
- LevelledUp cancellation should refund/credit unused eligible entries. A paid entry becomes consumed irreversibly when its first applicable Match becomes live.
- Refund mode is manual by default with optional automatic mode; changing refund mode is Super Admin-only and audited.
- Desired duplicate-payment behavior: flag duplicate transaction/reference attempts for Admin review rather than auto-rejecting them. Current DB behavior still needs to be aligned to this rule.

### Stages, Sessions & Lobbies

- Stage settings are templates/planning. Runtime attempt pricing belongs to Session; runtime match count belongs to Session default or Lobby override.
- A Session is a stable scheduled competition/attempt unit beneath a Stage.
- A Lobby belongs to one exact Session. Do not infer a Session once multiple Sessions exist.
- Session owns max concurrent lobbies and default matches per lobby. Lobby may carry an explicit matches-per-lobby override.
- Lobby operator assignment/reassignment must be audited and should eventually notify affected staff/teams where relevant.
- Tournament Admins can operate tournament/stage/session/lobby/match/result/schedule workflows. Super Admin handles global sensitive finance/security/staff operations.
- Desired staffing cap: exactly one Super Admin and at most two active Tournament Admins; backend already enforces the current staff model.

### Matches, results & scoring

- PUBG MOBILE custom-room host data is not guaranteed by an official public API. V1 should use manual results plus screenshot/evidence where needed.
- Team result data target: placement, kills/eliminations, placement points, kill points, penalties, total score; damage where available.
- Player result target: stable player identity/UID, kills, damage, participation.
- Match eligibility must use exact Tournament/Stage/Session Entry/Lobby/Match identity. Results must never be assignable to a team from the wrong Lobby.
- Lineup is max 4 players selected from a Squad of up to 6 for the relevant Match/Session.
- Raw result data is preserved. Penalty is a separate audited adjustment. Official score = raw score + penalty adjustment.
- Result corrections/penalties require reason/evidence/Admin/audit history.

### UID / identity lifecycle

- Captain may create an Unclaimed Player using a PUBG UID when that player has no LevelledUp account.
- Later signup using the same UID should claim the existing identity instead of creating a duplicate.
- Claim flow should support Captain approval when the player is in a team and Admin assistance when needed.
- Super Admin may detach a UID from a profile after proof if PUBG account ownership changes; historical competition identity never moves retroactively.
- Detach/reassignment requires double confirmation, reason/evidence, actor, timestamp, and effective-date history.
- Future bans should support UID/profile/reason/Admin/date/evidence/notes/temp expiry; unban closes the ban rather than deleting history.

### Notifications, support & privacy

- Persistent notifications should cover lobby/slot/time/operator changes, qualification, cancellation, payments/credit, Squad lock, and support.
- In-app unread/history first; push/PWA later; native app is not required for V1.
- Support/chat plus WhatsApp fallback is planned.
- Public surfaces may show standings, performance, career and UID search where appropriate, but must hide payment references, private contact data, internal notes, and evidence.
- Account deletion must be blocked/pending while credit/refund/payment/active tournament/dispute obligations exist; legally/operationally required competition history should remain preserved.

## 4. What has been completed

### Core stack and Supabase foundation
Next.js App Router + TypeScript + Tailwind + Supabase Auth/Postgres/RLS/RPCs are established. Public client uses URL + publishable key; service-role key must never be requested for normal app work.

### Team/Squad base system
Create team, lookup, join requests, recruitment, leave/remove/transfer/disband, team cap, six-member pool, stable roster numbers, and immutable/historical membership behavior largely exist.

### Tournament base
Tournament creation, draft/edit, registration windows, manual registration review, Squad snapshots/revisions, and initial payment review exist.

### Stage model
Named Stage identity, configuration, readiness/setup diagnostics, fee template, retry flag, knockout flag, advancement count, planning/concurrency, locking/version history exist in DB.

### Session model
Real tournament_stage_sessions exist with schedule, concurrency, default matches/lobby, status, stable identity, legacy backfill, and Session-owned authoritative pricing.

### Session Entry model
Stable Session participation identity exists with source/provenance/history, exact Tournament/Stage/Session/Registration/Team scope, active/cancelled lifecycle, and assignment linkage.

### Authoritative Session financial contract
Session attempt price is authoritative; Stage fee is creation template; paid/credit-backed Session attempts must match exact Session price.

### Free/Paid tournament contract
Free vs Paid classification and DB guards are deployed through 20260913010000. Free Tournament forbids paid/retry behavior; Paid Tournament keeps positive Stage/Session pricing.

### Free Tournament E2E
GREEN. Runtime verified against remote Supabase: free Stage/Session rules, Captain registration with no payment UI, approval without payment, free Session Entry, and zero financial rows.

### Paid initial registration E2E
GREEN for foundation contract. Runtime verified 500 PKR initial registration vs 700 PKR Session price separation, payment verification guard, approval provenance, and no accidental paid Session allocation.

### Secure credit/refund backend
Append-only payer-owned ledger, team-operational context, refund cases/mode history, debits/reversals and provenance exist in backend, though operational UI is incomplete.

### Payment destination backend
Versioned payment destination/history exists in backend. UI is still missing.

### Lobby/Session backend
Lobbies are Session-scoped, Session-local codes/order, optional Match override, operator assignment and append-only operator history exist.

### Admin role backend
One Super Admin + up to two active Tournament Admin seats are enforced; audited grant/revoke RPC exists.

### Homepage cleanup
Fake teams/leaderboard counts were removed. Public tournaments use real projection/fallback behavior. Responsive homepage and CTA artwork were implemented.

### Public leaderboard safety
No fake standings are emitted. The leaderboard remains intentionally empty/pending until a trusted standings projection exists.

## 5. What is not done / known gaps

### Refresh deep audit against current Git tree
Required next. The previous deep static audit predates the latest Free/Paid foundation changes and must be re-run before broad implementation.

### Positive paid Session-attempt purchase
No Captain/Admin mint/purchase path or UI. Negative guard and price derivation are proven; positive 700 PKR flow is intentionally unimplemented.

### Stripe / gateway integration
Schema anticipates gateway payments, but no Stripe checkout/callback/verification implementation exists.

### Advancement / qualification engine
No immutable qualification-event model, provisional standings calculation, top-N confirmation/publish flow, or automatic Earned Entry creation yet.

### Tie-breakers
Not decided. Must be discussed before advancement implementation.

### Session Entry Admin UI
No complete table/create/cancel/provenance/history management screen yet.

### Modern Lobby & Operator Admin UI
Backend exists; current/legacy UI needs Session Entry-aware assignment and operator workflow.

### Stage/Session lifecycle operations
Create/configure is present, but open/start/complete/cancel lifecycle operations need a full current-tree audit; do not assume all required RPCs/UI exist.

### Match operations
Create/generate/start/end/cancel Match workflow is incomplete.

### Admin Results API/UI
Existing result primitives are not a complete secure Admin workflow. Need trusted read/write/finalize/review operations and evidence/penalties.

### Leaderboard & standings
No trusted standings aggregation/public projection. Must be built after Results/Advancement model is correct.

### Co-Captain implementation
Target role/permissions are locked but DB/RPC/UI conversion from current Member/Substitute model is not done.

### Squad lock rule correction
Locked product rule is registration-close. Existing historical roster_lock_at behavior must be audited/migrated safely.

### Payment destination UI
Admin cannot yet configure it in normal UI and payer cannot reliably see it in the intended final flow.

### Duplicate transaction review model
Desired rule is flag, not automatic rejection. Existing DB behavior requires redesign/migration.

### Credits/refunds Admin UI
Balance/debit/reversal/refund-case/review/mode/history controls need dedicated UI.

### Staff Management UI
Backend grant/revoke exists; no complete Super Admin staff screen.

### Generic Audit & Settings
Specific histories exist, but there is no complete platform-wide audit log/settings/security dashboard.

### Notifications & support
No complete persistent notification center/support workflow yet.

### UID claim/transfer/ban system
Rules are planned; DB/UI not implemented.

### Account deletion workflow
Blocking/pending rules are planned but not implemented end-to-end.

### Homepage remaining polish
Featured tournament/live scrim banner is unfinished. Historical real-browser hamburger/footer accordion inconsistency should be rechecked on current build.

### Solo/Duo formats
Unresolved. Do not change behavior until explicitly discussed.

## 6. Approved Admin information architecture

The generated Admin concept images are approved as **visual/layout references only**. Actual controls must come from real backend capabilities and permissions; aspirational controls must not be fabricated.

- **Overview:** Summary cards, new-admin workflow, quick actions, pipeline, recent activity, today’s sessions. Must use real data only.
- **Tournaments:** Create/edit tournament, status, initial fee type, schedule, public visibility. Existing base requires consolidation.
- **Tournament Control:** Details, registration lifecycle, rules/public page/notifications/integrity checks, setup checklist. Only expose controls backed by real operations.
- **Stages & Sessions:** Stage list, configuration/readiness, Session list/editor, Session pricing and runtime defaults. Foundation now exists and needs current-tree audit/polish.
- **Session Entries:** Stable Entry ID, source/provenance, status, exact Session, Lobby assignment, create/cancel/history.
- **Lobbies & Operators:** Session-scoped lobbies, operator assignment/reassignment, team assignments through Session Entry, immutable operator history.
- **Matches & Results:** Match lifecycle, result entry/review/verify/publish, penalties/evidence, disputes/flags, leaderboard preview.
- **Teams & Registrations:** Team/Squad snapshot, registration status, eligibility, Captain/Co-Captain, lock warnings, messaging.
- **Payments & Credits:** Initial payments, Session-attempt purchases, payment destination, credit ledger, refunds, approval queue, finance safeguards.
- **Leaderboard & Results:** Standings, recalculation, publishing queue, public visibility. Requires trusted results/standings backend first.
- **Audit & Settings:** Specific audit histories, roles/permissions, financial settings, security/access. Do not fabricate platform settings that do not exist.

## 7. Deep-audit findings that remain relevant

- Earlier audit found the frontend substantially behind the Session-based backend. Many authenticated-callable RPCs had no application caller, while several visible controls still used legacy architecture.
- The biggest structural mismatch was old Tournament → Stage → Lobby UI versus the real Tournament → Stage → Session → Session Entry → Lobby → Match model.
- Finance backend is much more mature than finance UI: credit ledger, refund cases/mode history, payment destination/versioning, Session pricing, and multiple audit histories exist but are not exposed end-to-end.
- Current admin concepts such as Finance Admin, Support role, generic maintenance mode, IP restrictions, 2FA controls, Discord/webhook settings, and API-key rotation are not automatically real features; they must only appear if backed by actual product/backend work.
- Because the Free/Paid foundation changed several flows, the RPC-to-UI inventory must be regenerated before relying on old counts.

## 8. Free/Paid Tournament Foundation — verification record

### Free flow — GREEN
Runtime verification proved: Tournament fee 0; FREE admin/public classification; Stage fee 0; retry disabled and DB-rejected if enabled; Session fee 0; positive Session price DB-rejected; Captain registration has no payment section; Admin approval works without payment; one exact active `free` Session Entry is created; payments/paid allocations/credit-ledger rows remain zero; rollback-only negative tests passed; lint/TypeScript/build/diff-check passed.

### Paid flow — GREEN for foundation scope
Runtime test used **500 PKR Initial Registration Fee** and **700 PKR Session attempt price**. All 12 checks passed: initial payment derived 500 from Tournament; pending-payment approval rejected with `P4508`; verified payment stayed 500; approval created one initial-registration entitlement (`source_type=registration`) with explicit provenance; approval created zero paid Session allocations; Session remained 700; trying to fund 700 using the 500 payment was rejected with `22023`; no paid allocation was left behind.

### Explicit deferred gap
A positive 700 PKR Session-attempt purchase/allocation has no Captain/Admin purchase/mint path yet. This was intentionally deferred. It must not be described as runtime-passed. The eventual purchase flow must derive the amount from the Session and then create the correct paid allocation/Session Entry without confusing it with the Initial Registration Fee.

### Role-separation limitation
The paid E2E used the same authenticated account as both Admin and Captain. Amount/provenance logic was exercised, but true cross-account Admin/Captain separation still needs release-hardening E2E.

### Remaining visual QA
Visually inspect the real paid registration page to confirm **Initial Registration Fee** and **Session attempt price** are visibly distinct. Static/runtime amount behavior is correct; this is a UI acceptance check.

## 9. Test fixtures intentionally retained

| Fixture | Name | Details |
|---|---|---|
| Free E2E tournament | TEST - Free Tournament Contract 20260913 | Public ID LU-T-KQWZW837; Stage Open Qualifier; Session Free Session 1; Team Haider (LU-EP3JLD); confirmed test registration; finalized Squad; one active FREE Session Entry. |
| Paid E2E tournament | TEST - Paid Tournament Contract 2026-09-24 07:18 | Initial registration 500 PKR, Session attempt 700 PKR; payment reference E2E-PAID-MUF79YQ3. |
| Additional Paid E2E drafts | 3 draft TEST tournaments | Created by failed E2E script iterations. Do not delete without explicit approval; immutable/history constraints may apply. |

Do not delete these fixtures without explicit approval. Historical/financial rows may be intentionally immutable.

## 10. Roadmap / order of work

### 0. One remaining visual QA check
Open the real paid registration page and visually confirm “Initial Registration Fee” and “Session attempt price” are clearly distinct. This is UI QA, not a financial-contract blocker.

### 1. Refresh the complete deep audit
Re-audit current Git tree + migrations + real Supabase state. Rebuild the RPC-to-helper-to-page-to-button matrix and identify dead/legacy/missing controls after recent changes.

### 2. Overview + Tournaments + Tournament Control
Bring the admin entry point in line with real setup/readiness and remove stale legacy assumptions.

### 3. Finish Stages & Sessions
Audit current foundation, add missing lifecycle/edit operations only where backend contract supports them, and close responsive/error-state gaps.

### 4. Session Entries + paid attempt purchase
Build exact Session Entry management and the positive Session-attempt purchase path. Manual payment first; Stripe can follow as a dedicated finance integration.

### 5. Payments, Credits & Refunds
Payment destination UI, duplicate-reference flagging, credit balances/debits/reversals, refund cases/mode/history, cancellation workflows.

### 6. Lobbies & Operators
Replace legacy assignment flow with Session Entry-aware assignment, operator transfer, history, readiness and notifications.

### 7. Matches & Results
Trusted Match lifecycle, exact Lobby eligibility, manual result entry, evidence, penalties, review/finalize/publish.

### 8. Teams & Registrations
Implement Co-Captain permissions, correct Squad-lock timing, refine eligibility/warnings/history.

### 9. Advancement + Leaderboard
Top-N configuration, provisional rankings, Admin confirmation, immutable qualification events, Earned Entries, withdrawals/replacement, standings/public projection.

### 10. Audit / Staff / Settings
Staff management, consolidated audit views, finance/config histories, real settings/security controls only.

### 11. Notifications / Support / UID lifecycle
Persistent notifications, support workflow, UID claim/ownership-transfer/ban controls, privacy/account deletion.

### 12. Release hardening
Cross-role E2E (separate Admin/Captain accounts), mobile QA, accessibility, error states, load/edge cases, migration/state reconciliation, proper Git checkpoints.

## 11. Open decisions that must be discussed first

- **Tie-breaker order:** Not finalized. Must define exact standings tie order before advancement/leaderboard implementation.
- **Captain inactivity takeover:** Proposed: audited request + approvals + Super Admin review → Co-Captain to Captain. Not finalized.
- **Solo / Duo support:** Unresolved. Current historical schema contains format concepts, but product behavior must be discussed before changes.
- **Stripe rollout details:** Stripe is desired for paid/custom tournaments, but exact checkout, currency/provider rules, webhooks, reconciliation and rollout sequence remain to be designed.
- **Advancement edge cases:** Qualified team withdrawal / next eligible replacement concept is approved at a high level, but exact deadlines and tie handling need implementation design.

## 12. Definition of GREEN / QA rules

- A feature is only GREEN when the entire chain works: DB → RPC/action → page/tab → visible control → click → permission → DB change → UI refresh → success/error → manual test.
- No dead buttons, backend functions with no intended UI (except true internal/security helpers), UI controls calling missing functions, fake/demo public data, broken permissions, hidden runtime errors, or materially unusable mobile layouts.
- Important actions must preserve audit/history and show meaningful error/empty/loading states.
- Static type/lint/build success is necessary but does not replace authenticated runtime testing.
- When Codex cannot access real auth/network context, report the blocked layer; never weaken RLS/auth or introduce service-role browser logic to force a test.

Minimum validation for meaningful code batches: `npm run lint`, `npx tsc --noEmit`, `npm run build` when practical, and `git diff --check`; then authenticated/manual E2E for the feature’s real chain.

## 13. Codex working rules

- Use one manageable Codex task at a time. Small focused fix → GPT-5.6 Sol Medium. Complex multi-section UI or broad audit → Sol High.
- If Codex is already running, do not interrupt merely to change effort level.
- On continuation: inspect dirty working tree and continue; do not restart, reset, revert, clean, stash, or discard existing work.
- Latest approved product rule overrides older behavior. Any unresolved rule that affects money, tournament behavior, permissions, or user flow must be discussed and approved before implementation.
- Do not use service-role keys in the app or ask the user to expose them.
- Do not weaken RLS/auth because Codex sandbox networking fails.
- UI and functionality must be built together. Do not ship “pretty” controls without real backend operations.
- Reference images are layout inspiration only. Never implement a control solely because the concept image shows it.
- Mobile usability has priority over desktop polish.
- Use ⓘ help only for terminology/setup concepts that genuinely need explanation.

## 14. Important migrations / architectural milestones

- `20260902020000_tournament_stage_identity_and_names.sql` — professional Stage naming/identity.
- `20260902030000_stage_configuration_and_readiness.sql` — Stage rules, fee template, retry/knockout/advancement readiness.
- `20260903010000_stage_planning_and_setup_foundation.sql` — planned/concurrent Lobby metadata and setup diagnostics.
- `20260903020000_tournament_admin_payment_destination_history.sql` — staff model/payment destination history work.
- `20260903030000_stage_scoped_matches_and_setup_checks.sql` — Stage-scoped Match setup checks/legacy clarification.
- `20260905010000_tournament_stage_sessions.sql` — real Sessions, Session-scoped Lobbies, operator history, Session runtime defaults.
- `20260905020000_tournament_session_entries.sql` — stable Session Entry participation identity and Session-aware assignment/finance scope.
- `20260908010000_authoritative_session_financial_contract.sql` — Session-owned attempt price and price history; paid/credit allocation derives authoritative price.
- `20260913010000_free_paid_tournament_contract.sql` — deployed Free/Paid contract, free participation source, free retry/payment guards, paid initial-registration vs Session-attempt separation.

## 15. Known UI/public-site state

- Homepage is dark/orange esports style, responsive/mobile-first, with fake teams/counts removed.
- Public tournament data uses the authorized public projection/fallback rather than invented data.
- Public leaderboard intentionally does not fabricate standings while the trusted standings backend is absent.
- CTA desktop/mobile artwork exists in `public/images`; featured tournament/live-scrim banner remains unfinished.
- A prior real-browser/phone issue affected hamburger/footer accordion interaction despite Codex browser success. Re-test this on the current build rather than redesigning blindly.

## 16. Handoff instructions for the next developer/agent

1. Start by reading this document, then inspect the current Git status and migration history.
2. Do **not** trust old audit counts; run a fresh full audit against the current tree.
3. Preserve deployed migration history. Add new migrations rather than editing already-deployed migrations.
4. Keep the Free/Paid financial contract intact. Initial Tournament fee and Session attempt price are separate concepts.
5. Do not implement positive Session-attempt purchases until the current audit confirms the exact existing RPC/action surfaces.
6. Do not build advancement until tie-breakers and edge cases are finalized.
7. Work one admin section at a time, map every real backend operation to an intentional UI control, and E2E test before marking GREEN.
8. Never fabricate public data or UI capabilities.

## 17. Compact glossary

- **Tournament:** overall competition container; owns initial registration fee and top-level registration window.
- **Stage:** named competitive phase; holds templates/planning such as fee template, retry/knockout and advancement count.
- **Session:** exact scheduled attempt unit within a Stage; owns authoritative attempt price and runtime Lobby/Match defaults.
- **Session Entry / Attempt:** stable right for one registration/team to participate in one exact Session, with source/provenance.
- **Lobby:** exact Session-local room/group; owns team assignments and optional Match-count override.
- **Match:** exact competitive game under a Lobby.
- **Initial Registration Fee:** Tournament-level price to enter a paid Tournament.
- **Session attempt price:** Session-level price for a later paid attempt/retry.
- **Earned Entry:** one free next-Stage attempt earned by qualification; does not alter Session price.
- **Admin Grant:** exceptional manually granted participation, not the standard free-tournament path.
- **Credit:** auditable financial value with permanent original payer provenance and operational team context.
