#!/usr/bin/env node
/*
 * PAID Tournament E2E — price-separation verification
 * ---------------------------------------------------
 * Run from your project root (E:\Scrims):   node paid-e2e.js
 *
 * What it proves (handoff rule: "Initial Registration Fee and Session
 * attempt price are separate"):
 *   1. Initial registration payment = 500 PKR, sourced from
 *      tournaments.entry_fee_minor (caller supplies NO amount).
 *   2. Session attempt price = 700 PKR, sourced from
 *      tournament_stage_sessions.entry_fee_minor.
 *   3. Approving the 500 PKR registration payment does NOT silently
 *      create a 700 PKR paid Session allocation.
 *   4. The Session still shows/stores 700 PKR after approval.
 *   5. A future paid Session allocation derives 700 from the Session;
 *      the 500 payment can never fund it (22023, no fallback).
 *   6. Registration approval without a verified initial payment is
 *      rejected (P4508).
 *   7. The first Session entitlement from approval gets
 *      source_type='registration' with explicit provenance
 *      (NOT a 'paid' retry-style allocation).
 *
 * Manual payment only. No Stripe, no retry UI, no advancement.
 * Test data is clearly marked and left in place (same convention as
 * the free-tournament E2E fixtures).
 *
 * Privacy: passwords/tokens are typed/held locally only and are NEVER
 * printed. Only PASS/FAIL lines, ids and amounts are printed.
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const crypto = require('crypto');

// ---------- helpers ----------
function loadEnv() {
  const raw = fs.readFileSync(path.join(process.cwd(), '.env.local'), 'utf8')
    .replace(/^\uFEFF/, '').replace(/\r/g, '');
  const env = {};
  for (const line of raw.split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) env[m[1]] = m[2].trim();
  }
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY) {
    throw new Error('.env.local must define NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
  }
  return env;
}

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
function ask(q) {
  return new Promise(res => rl.question(q, ans => res(ans.trim())));
}

let BASE, APIKEY;
function headers(token) {
  const h = { apikey: APIKEY, 'Content-Type': 'application/json' };
  if (token) h['Authorization'] = 'Bearer ' + token;
  return h;
}

async function signIn(email, password) {
  const r = await fetch(`${BASE}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: headers(null),
    body: JSON.stringify({ email, password }),
  });
  const b = await r.json().catch(() => ({}));
  if (!r.ok || !b.access_token) throw new Error('sign-in failed for ' + email + ': ' + (b.msg || b.error_description || r.status));
  return { token: b.access_token, uid: b.user.id };
}

async function rpc(token, fn, params) {
  const r = await fetch(`${BASE}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: headers(token), body: JSON.stringify(params || {}),
  });
  const b = await r.json().catch(() => null);
  if (!r.ok) {
    const err = new Error(b && b.message ? b.message : ('RPC ' + fn + ' failed: ' + r.status));
    err.code = b && b.code ? String(b.code) : String(r.status);
    err.body = b;
    throw err;
  }
  return b;
}

async function rest(token, resource, query) {
  const r = await fetch(`${BASE}/rest/v1/${resource}?${query}`, { headers: headers(token) });
  const b = await r.json().catch(() => null);
  if (!r.ok) throw new Error('REST ' + resource + ' failed: ' + r.status + ' ' + JSON.stringify(b).slice(0, 200));
  return b;
}

// ---------- checks ----------
const results = [];
function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log((ok ? '  PASS' : '  FAIL') + '  ' + name + (detail ? '  — ' + detail : ''));
  if (!ok) {
    console.log('\nE2E STOPPED at first failure. Fix and re-run; test data is marked TEST and safe to inspect.');
    process.exit(1);
  }
}
function note(t) { console.log('  ... ' + t); }
const iso = d => d.toISOString();
const plusDays = n => new Date(Date.now() + n * 86400000);

// ---------- main ----------
(async () => {
  const env = loadEnv();
  BASE = env.NEXT_PUBLIC_SUPABASE_URL;
  APIKEY = env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  console.log('PAID Tournament E2E — 500 PKR registration fee vs 700 PKR session attempt price');
  console.log('Project: ' + BASE.replace(/^https:\/\//, '').split('.')[0].slice(0, 4) + '… (rest hidden)');
  console.log('Type passwords locally; nothing secret is printed or leaves this machine.\n');

  const adminEmail = await ask('Admin email: ');
  const adminPw = await ask('Admin password: ');
  const capEmail = await ask('Captain email (Enter = same as admin): ') || adminEmail;
  const capPw = capEmail === adminEmail ? adminPw : await ask('Captain password: ');
  const sameAccount = capEmail.toLowerCase() === adminEmail.toLowerCase();

  const admin = await signIn(adminEmail, adminPw);
  const captain = sameAccount ? admin : await signIn(capEmail, capPw);
  note('signed in: admin=' + adminEmail + ' captain=' + capEmail + (sameAccount ? ' (same account — role separation not exercised, amount/provenance logic is)' : ''));

  const stamp = new Date().toISOString().slice(0, 16).replace('T', ' ');
  const ref = 'E2E-PAID-' + Date.now().toString(36).toUpperCase();

  // --- 1. Mirror a known-good tournament, override fee to 500 ---
  console.log('\n[1] Creating TEST paid tournament (fee 500 PKR)...');
  const freeT = await rest(admin.token, 'tournaments',
    'name=ilike.*Free%20Tournament%20Contract*&select=id,name,game_mode,perspective,reward_model,prize_pool_minor,per_kill_reward_minor,max_team_slots,matches_per_day,number_of_days&limit=1');
  if (!freeT.length) throw new Error('free-test tournament not found to mirror fields from');
  const f = freeT[0];
  const tournament = await rpc(admin.token, 'levelledup_admin_create_tournament', {
    p_name: 'TEST - Paid Tournament Contract ' + stamp,
    p_description: 'E2E price-separation test. 500 PKR initial registration fee vs 700 PKR session attempt price. Safe to ignore/delete.',
    p_scheduled_start_at: iso(plusDays(8)),
    p_scheduled_end_at: iso(plusDays(9)),
    p_registration_opens_at: iso(new Date(Date.now() - 3600000)),
    p_registration_closes_at: iso(plusDays(7)),
    p_max_team_slots: f.max_team_slots, p_matches_per_day: f.matches_per_day,
    p_number_of_days: f.number_of_days, p_game_mode: f.game_mode, p_perspective: f.perspective,
    p_entry_fee_minor: 500, p_currency: 'PKR',
    p_reward_model: f.reward_model, p_prize_pool_minor: f.prize_pool_minor,
    p_per_kill_reward_minor: f.per_kill_reward_minor,
  });
  note('tournament: ' + tournament.name + ' (' + tournament.id.slice(0, 8) + '…)');
  check('INV-1a tournament stores Initial Registration Fee = 500 PKR',
    tournament.entry_fee_minor === 500 && tournament.currency === 'PKR',
    'entry_fee_minor=' + tournament.entry_fee_minor);

  // --- 2. Stage 1 configured (publish guard) + session priced at 700 ---
  console.log('\n[2] Configuring Stage 1, creating session, opening registration...');
  const stage = await rpc(admin.token, 'levelledup_admin_create_tournament_stage', {
    p_tournament_id: tournament.id, p_stage_number: 1,
    p_name_preset: 'open_qualifier', p_custom_name: null, p_configuration: {},
  });
  // Publish guard requires Stage 1 configuration_ready before open_registration.
  // Paid tournaments require a positive stage fee template; mirror the 500
  // tournament fee as the template so the E2E proves the session's 700 wins
  // over BOTH the tournament fee and the stage template.
  const configured = await rpc(admin.token, 'levelledup_admin_configure_stage', {
    p_stage_id: stage.id,
    p_patch: { matches_per_lobby: 3, stage_fee_minor: 500, fee_currency: 'PKR', advancement_count: 0 },
  });
  check('stage 1 configuration_ready (publish guard requirement)',
    configured.configuration_ready === true, 'configuration_ready=' + configured.configuration_ready);
  const session = await rpc(admin.token, 'levelledup_admin_create_tournament_session', {
    p_stage_id: stage.id, p_display_name: 'TEST Paid Session 1',
    p_scheduled_start_at: iso(plusDays(9)), p_scheduled_end_at: iso(new Date(Date.now() + 9 * 86400000 + 3 * 3600000)),
  });

  await rpc(admin.token, 'levelledup_admin_transition_tournament',
    { p_tournament_id: tournament.id, p_action: 'open_registration' });
  note('registration opened after Stage 1 configuration was complete');
  const priced = await rpc(admin.token, 'levelledup_admin_set_session_price', {
    p_session_id: session.id, p_entry_fee_minor: 700, p_fee_currency: 'PKR',
    p_reason: 'PAID E2E price-separation test: session attempt price must stay 700, distinct from 500 registration fee.',
    p_request_id: crypto.randomUUID(),
  });
  check('INV-2 session stores attempt price = 700 PKR',
    priced.entry_fee_minor === 700 && priced.fee_currency === 'PKR',
    'entry_fee_minor=' + priced.entry_fee_minor);
  check('session is enterable (planned/open)',
    ['planned', 'open'].includes(priced.status), 'status=' + priced.status);

  // --- 3. Captain: pick team, register ---
  console.log('\n[3] Captain registers a team...');
  const teams = await rest(captain.token, 'teams',
    'select=id,name,team_id&created_by=eq.' + captain.uid);
  if (!teams.length) throw new Error('captain has no teams (created_by). Use an account that owns/captains a team.');
  let team = teams[0];
  if (teams.length > 1) {
    console.log('  teams:'); teams.forEach((t, i) => console.log('    [' + i + '] ' + t.name + ' (' + t.team_id + ')'));
    const pick = await ask('  pick team number [0]: ');
    team = teams[parseInt(pick || '0', 10)] || teams[0];
  }
  note('team: ' + team.name + ' (' + team.team_id + ')');
  const members = await rest(captain.token, 'team_roster_members',
    'team_id=eq.' + team.id + '&status=eq.active&select=id');
  if (!members.length) throw new Error('team has no active roster members');
  const memberIds = members.map(m => m.id);

  const reg = await rpc(captain.token, 'levelledup_register_team_for_tournament', {
    p_tournament_id: tournament.id, p_team_id: team.id,
  });
  await rpc(captain.token, 'levelledup_select_registration_initial_session',
    { p_registration_id: reg.id, p_session_id: session.id });
  await rpc(captain.token, 'levelledup_finalize_tournament_roster',
    { p_registration_id: reg.id, p_roster_member_ids: memberIds });
  note('registration ' + reg.id.slice(0, 8) + '… squad finalized, initial session selected');

  // --- 4. Captain submits manual payment; caller supplies NO amount ---
  console.log('\n[4] Captain submits manual payment (no amount supplied)...');
  const payment = await rpc(captain.token, 'levelledup_submit_manual_tournament_payment', {
    p_registration_id: reg.id, p_reference_id: ref,
  });
  check('INV-1b payment row = 500 PKR from tournaments.entry_fee_minor (not caller, not session)',
    payment.expected_amount_minor === 500 && payment.currency === 'PKR'
    && payment.session_id === session.id && payment.status === 'pending',
    'expected_amount_minor=' + payment.expected_amount_minor + ' session pinned, status=' + payment.status);

  // --- 5. NEGATIVE: approve before verification -> P4508 ---
  console.log('\n[5] NEGATIVE: approve registration with only a PENDING payment...');
  let negErr = null;
  try {
    await rpc(admin.token, 'levelledup_admin_review_tournament_registration',
      { p_registration_id: reg.id, p_decision: 'approve' });
  } catch (e) { negErr = e; }
  check('INV-6 approval without verified initial payment is rejected (P4508)',
    !!(negErr && negErr.code === 'P4508'), negErr ? 'got ' + negErr.code : 'NOT rejected!');

  // --- 6. Admin verifies payment, approves registration ---
  console.log('\n[6] Admin verifies payment, then approves registration...');
  await rpc(admin.token, 'levelledup_admin_review_tournament_payment',
    { p_payment_id: payment.id, p_decision: 'verify' });
  const payRows = await rest(admin.token, 'tournament_registration_payments',
    'id=eq.' + payment.id + '&select=status,expected_amount_minor');
  check('payment verified, amount unchanged at 500',
    payRows[0].status === 'verified' && payRows[0].expected_amount_minor === 500,
    'status=' + payRows[0].status);

  await rpc(admin.token, 'levelledup_admin_review_tournament_registration',
    { p_registration_id: reg.id, p_decision: 'approve' });

  const entries = await rest(admin.token, 'tournament_session_entries',
    'registration_id=eq.' + reg.id + '&select=id,source_type,source_provenance,status');
  check('INV-7 approval creates exactly one entitlement with source_type=registration + explicit provenance',
    entries.length === 1 && entries[0].source_type === 'registration'
    && entries[0].source_provenance && entries[0].source_provenance.payment_id === payment.id
    && entries[0].source_provenance.entitlement === 'initial_registration_confirmation',
    'source_type=' + (entries[0] && entries[0].source_type));

  const paidEntries = await rest(admin.token, 'tournament_registration_paid_entries',
    'registration_id=eq.' + reg.id + '&select=id');
  check('INV-3 approval did NOT silently create a 700 PKR paid session allocation',
    paidEntries.length === 0, 'paid allocations=' + paidEntries.length);

  const sessAfter = await rest(admin.token, 'tournament_stage_sessions',
    'id=eq.' + session.id + '&select=entry_fee_minor,fee_currency');
  check('INV-4 session still stores 700 PKR after approval',
    sessAfter[0].entry_fee_minor === 700 && sessAfter[0].fee_currency === 'PKR',
    'entry_fee_minor=' + sessAfter[0].entry_fee_minor);

  // --- 7. NEGATIVE: 500-payment must not fund the 700-session ---
  console.log('\n[7] NEGATIVE: try to fund the 700 PKR session with the 500 PKR payment...');
  let allocErr = null;
  try {
    await rpc(admin.token, 'levelledup_admin_create_stage_paid_entry', {
      p_registration_id: reg.id, p_stage_id: stage.id, p_entry_scope: 'session',
      p_source_payment_id: payment.id, p_session_id: session.id, p_lobby_id: null,
    });
  } catch (e) { allocErr = e; }
  check('INV-5a session allocation rejects the 500 PKR payment (22023, no fallback to tournament fee)',
    !!(allocErr && allocErr.code === '22023'), allocErr ? 'got ' + allocErr.code : 'NOT rejected!');
  const paidAfter = await rest(admin.token, 'tournament_registration_paid_entries',
    'registration_id=eq.' + reg.id + '&select=id');
  check('INV-5b still zero paid allocations after rejected attempt', paidAfter.length === 0, '');

  // --- summary ---
  console.log('\n================ E2E SUMMARY ================');
  const failed = results.filter(r => !r.ok);
  console.log(failed.length === 0
    ? 'ALL ' + results.length + ' CHECKS PASSED — 500/700 price separation holds end to end.'
    : failed.length + ' CHECK(S) FAILED — see above.');
  console.log('\nTest fixtures left in place (marked TEST, same as free-test convention):');
  console.log('  tournament: ' + tournament.name);
  console.log('  payment ref: ' + ref);
  console.log('\nNot covered by this run (known, per handoff):');
  console.log('  - Positive 700 PKR session-attempt purchase: no captain/admin mint path exists yet');
  console.log('    (purchase UI deferred). Covered only by the 22023 negative test + code read.');
  console.log('  - UI label wording verified statically; please eyeball "Initial Registration Fee"');
  console.log('    vs "Session attempt price" on the tournament register page once.');
  rl.close();
  process.exit(failed.length ? 1 : 0);
})().catch(e => {
  console.error('\nE2E ERROR: ' + (e.code ? '[' + e.code + '] ' : '') + e.message);
  process.exit(1);
});
