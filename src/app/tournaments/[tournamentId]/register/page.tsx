import type { Metadata } from "next";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";

import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import {
  TournamentRegistrationFlow,
  type RegistrationRecord,
  type RegistrationRosterMember,
  type RegistrationSession,
  type RegistrationTeam,
} from "@/components/tournaments/TournamentRegistrationFlow";
import type { SlotBoardRow } from "@/components/tournaments/SlotBoard";
import { createClient } from "@/lib/supabase/server";
import { formatTournamentDateTime } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

export const metadata: Metadata = { title: "Join Tournament | LEVELLEDUP" };

type TournamentRow = {
  id: string; tournament_id: string; name: string; status: string;
  scheduled_start_at: string; registration_opens_at: string;
  registration_closes_at: string; roster_lock_at: string;
  roster_min_players: number; roster_max_players: number;
  game_mode: string; perspective: string; entry_fee_minor: number;
  currency: string; archived_at: string | null;
};
type MembershipRow = { team_id: string; role: RegistrationTeam["role"] };
type TeamRow = { id: string; name: string; team_id: string; short_name: string | null };
type RegistrationRow = {
  id: string; team_id: string; status: RegistrationRecord["status"];
  roster_status: RegistrationRecord["rosterStatus"]; roster_revision: number;
  slot_number: number | null; initial_session_id: string | null;
};
type StageRow = { id: string };
type SessionRow = {
  id: string; display_name: string; session_number: number;
  scheduled_start_at: string | null; scheduled_end_at: string | null;
  entry_fee_minor: number; fee_currency: string;
  status: "planned" | "open" | "live" | "completed" | "cancelled";
};
type RosterRow = {
  id: string; team_id: string; display_name: string; pubg_uid: string;
  pubg_ign: string | null; role: RegistrationTeam["role"];
  roster_number: number;
};
type SnapshotRow = Omit<RosterRow, "team_id"> & {
  registration_id: string;
  revision_number: number;
  source_roster_member_id: string;
};
type PaymentRow = {
  id: string; registration_id: string; status: "pending" | "verified" | "rejected";
  expected_amount_minor: number; currency: string; reference_id: string;
  submitted_at: string;
};
type CreditRow = {
  registration_id: string; amount_minor: number; currency: string;
  status: "available" | "used" | "refunded";
};
type SlotBoardDatabaseRow = {
  tournament_name: string; tournament_code: string; stage_id: string;
  stage_name: string;
  tier_label: string | null; stage_number: number; lobby_label: string;
  lobby_id: string; lobby_code: string; lobby_order: number;
  lobby_capacity: number; slot_number: number; assignment_id: string | null;
  registration_id: string | null; team_name: string | null;
  team_code: string | null; team_status: "active" | "disbanded" | null;
};

function formatMoney(value: number, currency: string) {
  const fractionDigits = currencyFractionDigits(currency);
  const amount = value / 10 ** fractionDigits;
  try {
    return new Intl.NumberFormat("en-PK", {
      style: "currency", currency, minimumFractionDigits: 0,
      maximumFractionDigits: fractionDigits,
    }).format(amount);
  } catch {
    return `${currency} ${amount}`;
  }
}

export default async function TournamentRegistrationPage({
  params,
}: { params: Promise<{ tournamentId: string }> }) {
  const publicId = (await params).tournamentId.trim().toUpperCase();
  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(publicId)) notFound();

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect(`/login?next=${encodeURIComponent(`/tournaments/${publicId}/register`)}`);

  const tournamentResult = await supabase.from("tournaments").select(
    "id, tournament_id, name, status, scheduled_start_at, registration_opens_at, registration_closes_at, roster_lock_at, roster_min_players, roster_max_players, game_mode, perspective, entry_fee_minor, currency, archived_at",
  ).eq("tournament_id", publicId).maybeSingle();
  if (tournamentResult.error) throw new Error("Unable to load tournament registration.");
  if (!tournamentResult.data) notFound();
  const tournament = tournamentResult.data as TournamentRow;

  const [membershipResult, stageOneResult] = await Promise.all([
    supabase.from("team_roster_members")
      .select("team_id, role").eq("profile_id", user.id).eq("status", "active")
      .eq("role", "captain")
      .order("created_at", { ascending: false }),
    supabase.from("tournament_stages")
      .select("id")
      .eq("tournament_id", tournament.id)
      .eq("stage_number", 1)
      .maybeSingle(),
  ]);
  if (membershipResult.error) throw new Error("Unable to load active teams.");
  if (stageOneResult.error) throw new Error("Unable to load Tournament Stage 1.");
  const memberships = (membershipResult.data ?? []) as MembershipRow[];
  const teamIds = memberships.map((membership) => membership.team_id);
  const stageOne = stageOneResult.data as StageRow | null;

  const sessionResult = stageOne
    ? await supabase.from("tournament_stage_sessions")
        .select("id, display_name, session_number, scheduled_start_at, scheduled_end_at, entry_fee_minor, fee_currency, status")
        .eq("tournament_id", tournament.id)
        .eq("stage_id", stageOne.id)
        .order("session_number", { ascending: true })
    : { data: [] as SessionRow[], error: null };
  if (sessionResult.error) throw new Error("Unable to load Stage 1 Sessions.");

  // Selection availability is a display hint; the RPC rechecks database time.
  // eslint-disable-next-line react-hooks/purity
  const now = Date.now();
  const sessions: RegistrationSession[] = ((sessionResult.data ?? []) as SessionRow[]).map((session) => ({
    id: session.id,
    name: session.display_name,
    sessionNumber: session.session_number,
    scheduleLabel: session.scheduled_start_at
      ? session.scheduled_end_at
        ? `${formatTournamentDateTime(session.scheduled_start_at)} → ${formatTournamentDateTime(session.scheduled_end_at)}`
        : formatTournamentDateTime(session.scheduled_start_at)
      : null,
    entryFeeLabel: formatMoney(session.entry_fee_minor, session.fee_currency),
    entryFeeMinor: session.entry_fee_minor,
    currency: session.fee_currency,
    selectable: ["planned", "open"].includes(session.status)
      && (!session.scheduled_start_at || new Date(session.scheduled_start_at).getTime() > now),
  }));

  const [teamResult, registrationResult, rosterResult] = await Promise.all([
    teamIds.length ? supabase.from("teams").select("id, name, team_id, short_name").in("id", teamIds).eq("status", "active") : Promise.resolve({ data: [] as TeamRow[], error: null }),
    teamIds.length ? supabase.from("tournament_registrations").select("id, team_id, status, roster_status, roster_revision, slot_number, initial_session_id").eq("tournament_id", tournament.id).in("team_id", teamIds).in("status", ["pending", "confirmed"]) : Promise.resolve({ data: [] as RegistrationRow[], error: null }),
    teamIds.length ? supabase.from("team_roster_members").select("id, team_id, display_name, pubg_uid, pubg_ign, role, roster_number").in("team_id", teamIds).eq("status", "active").order("roster_number", { ascending: true }) : Promise.resolve({ data: [] as RosterRow[], error: null }),
  ]);
  if (teamResult.error || registrationResult.error || rosterResult.error) throw new Error("Unable to load registration details.");

  const registrationRows = (registrationResult.data ?? []) as RegistrationRow[];
  const registrationIds = registrationRows.map((item) => item.id);
  const snapshotResult = registrationIds.length
    ? await supabase.from("tournament_registration_roster").select("id, registration_id, display_name, pubg_uid, pubg_ign, role, roster_number, revision_number, source_roster_member_id").in("registration_id", registrationIds).order("roster_number", { ascending: true })
    : { data: [] as SnapshotRow[], error: null };
  if (snapshotResult.error) throw new Error("Unable to load finalized tournament Squads.");
  const paymentResult = registrationIds.length
    ? await supabase.from("tournament_registration_payments")
        .select("id, registration_id, status, expected_amount_minor, currency, reference_id, submitted_at")
        .in("registration_id", registrationIds)
        .order("submitted_at", { ascending: false })
    : { data: [] as PaymentRow[], error: null };
  if (paymentResult.error) throw new Error("Unable to load tournament payment history.");
  const creditResult = registrationIds.length
    ? await supabase.rpc("levelledup_get_my_tournament_credits")
    : { data: [] as CreditRow[], error: null };
  if (creditResult.error) throw new Error("Unable to load tournament credit history.");

  const teamById = new Map(((teamResult.data ?? []) as TeamRow[]).map((team) => [team.id, team]));
  const teams: RegistrationTeam[] = memberships.flatMap((membership) => {
    const team = teamById.get(membership.team_id);
    return team ? [{ id: team.id, name: team.name, teamId: team.team_id, shortName: team.short_name, role: membership.role }] : [];
  });
  const snapshots = (snapshotResult.data ?? []) as SnapshotRow[];
  const payments = (paymentResult.data ?? []) as PaymentRow[];
  const credits = (creditResult.data ?? []) as CreditRow[];
  const registrations: RegistrationRecord[] = registrationRows.map((item) => ({
    id: item.id, teamId: item.team_id, status: item.status,
    rosterStatus: item.roster_status, rosterRevision: item.roster_revision,
    slotNumber: item.slot_number, initialSessionId: item.initial_session_id,
    credit: (() => {
      const credit = credits.find((itemCredit) => itemCredit.registration_id === item.id);
      const verifiedPayment = payments.find((payment) =>
        payment.registration_id === item.id && payment.status === "verified"
      );
      return credit ? {
        amount: formatMoney(credit.amount_minor, credit.currency),
        sourceReferenceId: verifiedPayment?.reference_id ?? "Unavailable",
        status: credit.status,
      } : null;
    })(),
    payments: payments.filter((payment) => payment.registration_id === item.id).map((payment) => ({
      id: payment.id, status: payment.status,
      expectedAmount: formatMoney(payment.expected_amount_minor, payment.currency),
      referenceId: payment.reference_id, submittedAt: payment.submitted_at,
    })),
    snapshot: snapshots.filter((member) =>
      member.registration_id === item.id && member.revision_number === item.roster_revision
    ).map((member) => ({
      id: member.id, displayName: member.display_name, pubgUid: member.pubg_uid,
      pubgIgn: member.pubg_ign, role: member.role, rosterNumber: member.roster_number,
      sourceRosterMemberId: member.source_roster_member_id,
    })),
  }));
  const rosterMembers: RegistrationRosterMember[] = ((rosterResult.data ?? []) as RosterRow[]).map((member) => ({
    id: member.id, teamId: member.team_id, displayName: member.display_name,
    pubgUid: member.pubg_uid, pubgIgn: member.pubg_ign, role: member.role,
    rosterNumber: member.roster_number,
  }));

  const slotBoardResult = await supabase.rpc("levelledup_get_tournament_slot_board", {
    p_tournament_code: publicId,
  });
  if (slotBoardResult.error) throw new Error("Unable to load tournament lobby assignments.");
  const slotBoardRows: SlotBoardRow[] = ((slotBoardResult.data ?? []) as SlotBoardDatabaseRow[]).map((row) => ({
    tournamentName: row.tournament_name, tournamentCode: row.tournament_code,
    stageId: row.stage_id, stageName: row.stage_name,
    tierLabel: row.tier_label, stageNumber: row.stage_number,
    lobbyId: row.lobby_id, lobbyLabel: row.lobby_label,
    lobbyCode: row.lobby_code, lobbyOrder: row.lobby_order,
    lobbyCapacity: row.lobby_capacity, slotNumber: row.slot_number,
    assignmentId: row.assignment_id, registrationId: row.registration_id,
    teamName: row.team_name, teamCode: row.team_code,
    teamStatus: row.team_status,
  }));

  if (process.env.NODE_ENV !== "production") {
    console.info(
      `[Tournament registration: loaded state] ${JSON.stringify({
        tournamentCode: publicId,
        gameMode: tournament.game_mode,
        rosterMinimum: tournament.roster_min_players,
        rosterMaximum: tournament.roster_max_players,
        rosterLockAt: tournament.roster_lock_at,
        teams: teams.map((team) => ({
          teamReference: team.teamId,
          role: team.role,
          activeRosterCount: rosterMembers.filter((member) => member.teamId === team.id).length,
        })),
        registrations: registrations.map((registration) => ({
          status: registration.status,
          rosterStatus: registration.rosterStatus,
          snapshotCount: registration.snapshot.length,
        })),
      })}`,
    );
  }

  const canBegin = tournament.status === "registration_open" && !tournament.archived_at
    && now >= new Date(tournament.registration_opens_at).getTime()
    && now < new Date(tournament.registration_closes_at).getTime()
    && now < new Date(tournament.scheduled_start_at).getTime();

  return (
    <>
      <AuthenticatedHeader />
      <main className="min-h-svh px-5 pb-14 pt-[calc(var(--header-height)+2.5rem)] sm:px-8 sm:pb-20 lg:px-10">
        <div className="mx-auto w-full max-w-6xl">
          <Link href="/#tournaments" className="text-[0.58rem] font-semibold uppercase tracking-[0.15em] text-foreground-muted hover:text-accent">← Live Scrims</Link>
          <header className="mt-7 border-b border-border pb-7">
            <div className="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
              <div className="min-w-0">
                <p className="type-eyebrow text-accent">Tournament registration</p>
                <h1 className="type-display mt-4 break-words text-[clamp(2.75rem,8vw,5.75rem)] uppercase leading-[0.9]">{tournament.name}</h1>
                <p className="mt-4 font-mono text-[0.6rem] uppercase tracking-[0.14em] text-foreground-muted">{tournament.tournament_id}</p>
              </div>
              <dl className="grid shrink-0 grid-cols-2 gap-4 border border-border-strong p-4 text-xs sm:min-w-80">
                <div><dt className="text-[0.5rem] uppercase tracking-[0.14em] text-foreground-subtle">Starts</dt><dd className="mt-1">{formatTournamentDateTime(tournament.scheduled_start_at)}</dd></div>
                <div><dt className="text-[0.5rem] uppercase tracking-[0.14em] text-foreground-subtle">Format</dt><dd className="mt-1 uppercase">{tournament.game_mode} · {tournament.perspective}</dd></div>
              </dl>
            </div>
          </header>
          <TournamentRegistrationFlow
            key={registrations.map((registration) => `${registration.id}:${registration.rosterRevision}:${registration.initialSessionId ?? "none"}`).join("|")}
            canBeginRegistration={canBegin}
            initialRegistrationFeeLabel={formatMoney(
              tournament.entry_fee_minor,
              tournament.currency,
            )}
            registrations={registrations}
            isFreeTournament={tournament.entry_fee_minor === 0}
            registrationClosesAt={formatTournamentDateTime(tournament.registration_closes_at)}
            registrationClosePassed={now >= new Date(tournament.registration_closes_at).getTime()}
            rosterLockAt={formatTournamentDateTime(tournament.roster_lock_at)}
            rosterLockPassed={now >= new Date(tournament.roster_lock_at).getTime()}
            rosterMaxPlayers={tournament.roster_max_players}
            rosterMembers={rosterMembers}
            rosterMinPlayers={tournament.roster_min_players}
            sessions={sessions}
            slotBoardRows={slotBoardRows}
            teams={teams}
            tournamentPublicId={publicId}
            tournamentStatus={tournament.status}
          />
        </div>
      </main>
    </>
  );
}
