import type { Metadata } from "next";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";

import { TournamentRegistrationManagement } from "@/components/admin/TournamentRegistrationManagement";
import { TournamentSessionEntryVisibility } from "@/components/admin/TournamentSessionEntryVisibility";
import { TournamentPaymentManagement } from "@/components/admin/TournamentPaymentManagement";
import { TournamentLobbyManagement } from "@/components/admin/TournamentLobbyManagement";
import { TournamentStageSessionManagement } from "@/components/admin/TournamentStageSessionManagement";
import type {
  AdminSessionSetupCheck,
  AdminStageSetup,
  AdminTournamentCredit,
  AdminTournamentLobby,
  AdminTournamentPayment,
  AdminTournamentRegistration,
  AdminTournamentSession,
  AdminTournamentSessionEntry,
  AdminTournamentStage,
  TournamentGameMode,
  TournamentPerspective,
  TournamentRegistrationStatus,
  TournamentRewardModel,
  TournamentRosterRole,
  TournamentRosterStatus,
  TournamentStatus,
} from "@/components/admin/types";
import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import type { SlotBoardRow } from "@/components/tournaments/SlotBoard";
import {
  getCurrentAdminAccess,
  hasRequiredAdminRole,
} from "@/lib/auth/admin";
import { createClient } from "@/lib/supabase/server";
import { formatTournamentDateTime } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

export const metadata: Metadata = {
  title: "Manage Tournament | LEVELLEDUP",
};

type TournamentRow = {
  id: string;
  tournament_id: string;
  name: string;
  description: string | null;
  status: TournamentStatus;
  scheduled_start_at: string;
  scheduled_end_at: string | null;
  registration_opens_at: string;
  registration_closes_at: string;
  max_team_slots: number;
  default_lobby_capacity: number;
  max_lobbies: number;
  matches_per_day: number;
  number_of_days: number;
  game_mode: TournamentGameMode;
  perspective: TournamentPerspective;
  entry_fee_minor: number;
  currency: string;
  reward_model: TournamentRewardModel;
  prize_pool_minor: number | null;
  per_kill_reward_minor: number | null;
  archived_at: string | null;
};

type RegistrationRow = {
  id: string;
  team_id: string;
  status: TournamentRegistrationStatus;
  roster_status: TournamentRosterStatus;
  roster_revision: number;
  slot_number: number | null;
  initial_session_id: string | null;
  registered_at: string;
};

type TeamRow = {
  id: string;
  name: string;
  team_id: string;
  status: "active" | "disbanded";
};

type RosterRow = {
  id: string;
  registration_id: string;
  display_name: string;
  pubg_uid: string;
  pubg_ign: string | null;
  role: TournamentRosterRole;
  revision_number: number;
};
type PaymentRow = {
  id: string; registration_id: string; team_id: string; session_id: string | null;
  status: "pending" | "verified" | "rejected";
  payment_method: "manual" | "gateway";
  expected_amount_minor: number; currency: string;
  reference_id: string; manual_reference_normalized: string | null;
  submitted_at: string;
};
type ActiveManualPaymentReferenceRow = {
  id: string;
  manual_reference_normalized: string;
};
type CreditRow = {
  id: string; registration_id: string; team_id: string;
  amount_minor: number; currency: string; source_reference_id: string;
  status: "available" | "used" | "refunded"; created_at: string;
};
type SlotBoardDatabaseRow = {
  tournament_name: string; tournament_code: string; stage_id: string;
  stage_name: string;
  tier_label: string | null; stage_number: number; lobby_label: string;
  lobby_id: string; lobby_code: string; lobby_order: number;
  lobby_capacity: number; slot_number: number; assignment_id: string | null;
  registration_id: string | null; team_name: string | null;
  team_code: string | null;
  team_status: "active" | "disbanded" | null;
};
type AdminLobbyDatabaseRow = {
  stage_id: string;
  stage_number: number;
  session_id: string;
  session_number: number;
  session_display_name: string;
  lobby_id: string;
  lobby_label: string;
  lobby_code: string;
  lobby_order: number;
  lobby_capacity: number;
  lobby_status: AdminTournamentLobby["status"];
};
type StageDatabaseRow = {
  id: string;
  tournament_id: string;
  stage_number: number;
  display_name: string;
  name_preset: AdminTournamentStage["namePreset"];
  custom_name: string | null;
  status: AdminTournamentStage["status"];
  matches_per_lobby: number | null;
  stage_fee_minor: number | null;
  fee_currency: string | null;
  retry_allowed: boolean;
  knockout_enabled: boolean;
  advancement_count: number | null;
  planned_lobby_count: number | null;
  concurrent_lobby_capacity: number | null;
  rules_locked_at: string | null;
  configuration_ready: boolean;
};
type SessionDatabaseRow = {
  id: string;
  tournament_id: string;
  stage_id: string;
  session_number: number;
  display_name: string;
  scheduled_start_at: string | null;
  scheduled_end_at: string | null;
  max_concurrent_lobbies: number | null;
  default_matches_per_lobby: number | null;
  entry_fee_minor: number;
  fee_currency: string;
  status: AdminTournamentSession["status"];
  is_legacy_backfill: boolean;
};
type StageSetupDatabaseRow = {
  stage_id: string;
  setup_state: string;
  actual_lobby_count: number;
  scheduled_lobby_count: number;
};
type SessionSetupCheckDatabaseRow = {
  stage_id: string;
  session_id: string | null;
  setup_complete: boolean;
  issues: string[] | null;
};
type SessionEntryDatabaseRow = {
  id: string;
  tournament_id: string;
  stage_id: string;
  session_id: string;
  registration_id: string;
  team_id: string;
  source_type: string;
  status: "active" | "cancelled";
  reason: string;
  created_at: string;
  cancelled_at: string | null;
  cancellation_reason: string | null;
};

const statusLabels: Record<TournamentStatus, string> = {
  draft: "Draft",
  registration_open: "Registration Open",
  registration_closed: "Registration Closed",
  live: "Live",
  completed: "Completed",
  cancelled: "Cancelled",
};

function formatMoney(value: number | null, currency: string) {
  if (value === null) return "Not set";
  const fractionDigits = currencyFractionDigits(currency);
  const amount = value / 10 ** fractionDigits;

  try {
    return new Intl.NumberFormat("en-PK", {
      style: "currency",
      currency,
      minimumFractionDigits: 0,
      maximumFractionDigits: fractionDigits,
    }).format(amount);
  } catch {
    return `${currency} ${amount}`;
  }
}

export default async function AdminTournamentPage({
  params,
}: {
  params: Promise<{ tournamentId: string }>;
}) {
  const access = await getCurrentAdminAccess();

  if (!access || !hasRequiredAdminRole(access)) {
    const authClient = await createClient();
    const {
      data: { user },
    } = await authClient.auth.getUser();

    redirect(user ? "/" : "/login?next=/admin");
  }

  const { tournamentId: submittedTournamentId } = await params;
  const tournamentPublicId = submittedTournamentId.trim().toUpperCase();

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    notFound();
  }

  const supabase = await createClient();
  const { data: tournamentData, error: tournamentError } = await supabase
    .from("tournaments")
    .select(
      "id, tournament_id, name, description, status, scheduled_start_at, scheduled_end_at, registration_opens_at, registration_closes_at, max_team_slots, default_lobby_capacity, max_lobbies, matches_per_day, number_of_days, game_mode, perspective, entry_fee_minor, currency, reward_model, prize_pool_minor, per_kill_reward_minor, archived_at",
    )
    .eq("tournament_id", tournamentPublicId)
    .maybeSingle();

  if (tournamentError) {
    console.error("[Admin: tournament operations detail]", {
      code: tournamentError.code,
      message: tournamentError.message,
      tournamentPublicId,
      userReference: access.userId.slice(-6),
    });
    throw new Error("Unable to load tournament operations.");
  }

  if (!tournamentData) notFound();
  const tournament = tournamentData as TournamentRow;

  const { data: registrationData, error: registrationError } = await supabase
    .from("tournament_registrations")
    .select("id, team_id, status, roster_status, roster_revision, slot_number, initial_session_id, registered_at")
    .eq("tournament_id", tournament.id)
    .order("registered_at", { ascending: true });

  if (registrationError) {
    console.error("[Admin: tournament registrations]", {
      code: registrationError.code,
      message: registrationError.message,
      tournamentPublicId,
    });
    throw new Error("Unable to load tournament registrations.");
  }

  const registrationRows = (registrationData ?? []) as RegistrationRow[];
  const registrationIds = registrationRows.map((registration) => registration.id);
  const teamIds = [
    ...new Set(registrationRows.map((registration) => registration.team_id)),
  ];

  const [
    teamsResult,
    rosterResult,
    paymentResult,
    creditResult,
    slotBoardResult,
    lobbyResult,
    stagesResult,
    sessionsResult,
    sessionEntriesResult,
    stageSetupResult,
    sessionChecksResult,
  ] = await Promise.all([
    teamIds.length
      ? supabase.from("teams").select("id, name, team_id, status").in("id", teamIds)
      : Promise.resolve({ data: [] as TeamRow[], error: null }),
    registrationIds.length
      ? supabase
          .from("tournament_registration_roster")
          .select(
            "id, registration_id, display_name, pubg_uid, pubg_ign, role, revision_number",
          )
          .in("registration_id", registrationIds)
          .order("created_at", { ascending: true })
      : Promise.resolve({ data: [] as RosterRow[], error: null }),
    registrationIds.length
      ? supabase.from("tournament_registration_payments")
          .select("id, registration_id, team_id, session_id, status, payment_method, expected_amount_minor, currency, reference_id, manual_reference_normalized, submitted_at")
          .eq("tournament_id", tournament.id)
          .order("submitted_at", { ascending: false })
      : Promise.resolve({ data: [] as PaymentRow[], error: null }),
    supabase.from("tournament_team_credits")
      .select("id, registration_id, team_id, amount_minor, currency, source_reference_id, status, created_at")
      .eq("tournament_id", tournament.id)
      .order("created_at", { ascending: true }),
    supabase.rpc("levelledup_get_tournament_slot_board", {
      p_tournament_code: tournamentPublicId,
    }),
    supabase.rpc("levelledup_admin_get_tournament_lobbies", {
      p_tournament_code: tournamentPublicId,
    }),
    supabase
      .from("tournament_stages")
      .select(
        "id, tournament_id, stage_number, display_name, name_preset, custom_name, status, matches_per_lobby, stage_fee_minor, fee_currency, retry_allowed, knockout_enabled, advancement_count, planned_lobby_count, concurrent_lobby_capacity, rules_locked_at, configuration_ready",
      )
      .eq("tournament_id", tournament.id)
      .order("stage_number", { ascending: true }),
    supabase
      .from("tournament_stage_sessions")
      .select(
        "id, tournament_id, stage_id, session_number, display_name, scheduled_start_at, scheduled_end_at, max_concurrent_lobbies, default_matches_per_lobby, entry_fee_minor, fee_currency, status, is_legacy_backfill",
      )
      .eq("tournament_id", tournament.id)
      .order("session_number", { ascending: true }),
    supabase
      .from("tournament_session_entries")
      .select(
        "id, tournament_id, stage_id, session_id, registration_id, team_id, source_type, status, reason, created_at, cancelled_at, cancellation_reason",
      )
      .eq("tournament_id", tournament.id)
      .order("created_at", { ascending: false }),
    supabase.rpc("levelledup_admin_get_stage_setup", {
      p_tournament_id: tournament.id,
    }),
    supabase.rpc("levelledup_admin_get_stage_session_setup_checks", {
      p_tournament_id: tournament.id,
    }),
  ]);

  if (
    teamsResult.error ||
    rosterResult.error ||
    paymentResult.error ||
    creditResult.error ||
    slotBoardResult.error ||
    lobbyResult.error ||
    stagesResult.error ||
    sessionsResult.error ||
    sessionEntriesResult.error ||
    stageSetupResult.error ||
    sessionChecksResult.error
  ) {
    console.error("[Admin: tournament operation dependencies]", {
      rosterError: rosterResult.error?.message ?? null,
      paymentError: paymentResult.error?.message ?? null,
      creditError: creditResult.error?.message ?? null,
      teamError: teamsResult.error?.message ?? null,
      slotBoardError: slotBoardResult.error?.message ?? null,
      lobbyError: lobbyResult.error?.message ?? null,
      stagesError: stagesResult.error?.message ?? null,
      sessionsError: sessionsResult.error?.message ?? null,
      sessionEntriesError: sessionEntriesResult.error?.message ?? null,
      stageSetupError: stageSetupResult.error?.message ?? null,
      sessionChecksError: sessionChecksResult.error?.message ?? null,
      tournamentPublicId,
    });
    throw new Error("Unable to load tournament operations details.");
  }

  const teams = new Map(
    ((teamsResult.data ?? []) as TeamRow[]).map((team) => [team.id, team]),
  );
  const rosterByRegistration = new Map<string, RosterRow[]>();
  const paymentRows = (paymentResult.data ?? []) as PaymentRow[];
  const normalizedManualReferences = [
    ...new Set(
      paymentRows
        .filter(
          (payment) =>
            payment.payment_method === "manual" &&
            payment.status !== "rejected" &&
            payment.manual_reference_normalized,
        )
        .map((payment) => payment.manual_reference_normalized as string),
    ),
  ];
  const activeReferenceResult = normalizedManualReferences.length
    ? await supabase
        .from("tournament_registration_payments")
        .select("id, manual_reference_normalized")
        .eq("payment_method", "manual")
        .in("status", ["pending", "verified"])
        .in("manual_reference_normalized", normalizedManualReferences)
    : { data: [] as ActiveManualPaymentReferenceRow[], error: null };

  if (activeReferenceResult.error) {
    console.error("[Admin: duplicate payment references]", {
      code: activeReferenceResult.error.code,
      message: activeReferenceResult.error.message,
      tournamentPublicId,
    });
    throw new Error("Unable to validate manual payment references.");
  }

  const activeReferenceCounts = new Map<string, number>();
  for (const payment of (activeReferenceResult.data ?? []) as ActiveManualPaymentReferenceRow[]) {
    activeReferenceCounts.set(
      payment.manual_reference_normalized,
      (activeReferenceCounts.get(payment.manual_reference_normalized) ?? 0) + 1,
    );
  }
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
  const lobbies: AdminTournamentLobby[] = ((lobbyResult.data ?? []) as AdminLobbyDatabaseRow[]).map((lobby) => ({
    id: lobby.lobby_id,
    label: lobby.lobby_label,
    code: lobby.lobby_code,
    order: lobby.lobby_order,
    capacity: lobby.lobby_capacity,
    status: lobby.lobby_status,
    stageId: lobby.stage_id,
    stageNumber: lobby.stage_number,
    sessionId: lobby.session_id,
    sessionNumber: lobby.session_number,
    sessionDisplayName: lobby.session_display_name,
  }));
  const stages: AdminTournamentStage[] = (
    (stagesResult.data ?? []) as StageDatabaseRow[]
  ).map((stage) => ({
    id: stage.id,
    tournamentId: stage.tournament_id,
    stageNumber: stage.stage_number,
    displayName: stage.display_name,
    namePreset: stage.name_preset,
    customName: stage.custom_name,
    status: stage.status,
    matchesPerLobby: stage.matches_per_lobby,
    stageFeeMinor: stage.stage_fee_minor,
    feeCurrency: stage.fee_currency,
    retryAllowed: stage.retry_allowed,
    knockoutEnabled: stage.knockout_enabled,
    advancementCount: stage.advancement_count,
    plannedLobbyCount: stage.planned_lobby_count,
    concurrentLobbyCapacity: stage.concurrent_lobby_capacity,
    rulesLockedAt: stage.rules_locked_at,
    configurationReady: stage.configuration_ready,
  }));
  const sessions: AdminTournamentSession[] = (
    (sessionsResult.data ?? []) as SessionDatabaseRow[]
  ).map((session) => ({
    id: session.id,
    tournamentId: session.tournament_id,
    stageId: session.stage_id,
    sessionNumber: session.session_number,
    displayName: session.display_name,
    scheduledStartAt: session.scheduled_start_at,
    scheduledEndAt: session.scheduled_end_at,
    maxConcurrentLobbies: session.max_concurrent_lobbies,
    defaultMatchesPerLobby: session.default_matches_per_lobby,
    entryFeeMinor: session.entry_fee_minor,
    feeCurrency: session.fee_currency,
    status: session.status,
    isLegacyBackfill: session.is_legacy_backfill,
  }));
  const stageSetup: AdminStageSetup[] = (
    (stageSetupResult.data ?? []) as StageSetupDatabaseRow[]
  ).map((setup) => ({
    stageId: setup.stage_id,
    setupState: setup.setup_state,
    actualLobbyCount: setup.actual_lobby_count,
    scheduledLobbyCount: setup.scheduled_lobby_count,
  }));
  const sessionChecks: AdminSessionSetupCheck[] = (
    (sessionChecksResult.data ?? []) as SessionSetupCheckDatabaseRow[]
  ).map((check) => ({
    stageId: check.stage_id,
    sessionId: check.session_id,
    setupComplete: check.setup_complete,
    issues: check.issues ?? [],
  }));
  const sessionEntries: AdminTournamentSessionEntry[] = (
    (sessionEntriesResult.data ?? []) as SessionEntryDatabaseRow[]
  ).map((entry) => {
    const team = teams.get(entry.team_id);
    const stage = stages.find((candidate) => candidate.id === entry.stage_id);
    const session = sessions.find((candidate) => candidate.id === entry.session_id);
    const registration = registrationRows.find(
      (candidate) => candidate.id === entry.registration_id,
    );

    return {
      id: entry.id,
      teamName: team?.name ?? "Team record unavailable",
      teamPublicId: team?.team_id ?? "Unavailable",
      stageName: stage?.displayName ?? "Stage record unavailable",
      sessionName: session?.displayName ?? "Session record unavailable",
      registrationStatus: registration?.status ?? "Unavailable",
      status: entry.status,
      sourceType: entry.source_type,
      createdAt: entry.created_at,
      reason: entry.reason,
      cancelledAt: entry.cancelled_at,
      cancellationReason: entry.cancellation_reason,
    };
  });

  const sessionTeamCounts: Record<string, number> = {};
  for (const entry of (sessionEntriesResult.data ?? []) as SessionEntryDatabaseRow[]) {
    if (entry.status === "active") {
      sessionTeamCounts[entry.session_id] =
        (sessionTeamCounts[entry.session_id] ?? 0) + 1;
    }
  }

  for (const member of (rosterResult.data ?? []) as RosterRow[]) {
    const registration = registrationRows.find(
      (item) => item.id === member.registration_id,
    );
    if (!registration || member.revision_number !== registration.roster_revision) continue;
    const members = rosterByRegistration.get(member.registration_id) ?? [];
    members.push(member);
    rosterByRegistration.set(member.registration_id, members);
  }

  const registrations: AdminTournamentRegistration[] = registrationRows.map(
    (registration) => {
      const team = teams.get(registration.team_id);
      const initialSession = sessions.find(
        (session) => session.id === registration.initial_session_id,
      );
      const initialSessionStage = initialSession
        ? stages.find((stage) => stage.id === initialSession.stageId)
        : null;
      const initialSessionValid = Boolean(
        registration.initial_session_id &&
          initialSession &&
          initialSession.tournamentId === tournament.id &&
          initialSessionStage?.stageNumber === 1 &&
          ["planned", "open"].includes(initialSession.status),
      );
      const initialSessionPayment = initialSessionValid
        ? paymentRows.find(
            (payment) =>
              payment.registration_id === registration.id &&
              payment.session_id === registration.initial_session_id &&
              payment.expected_amount_minor === tournament.entry_fee_minor &&
              payment.currency === tournament.currency,
          )
        : null;
      const assignment = slotBoardRows
        .find(
          (row) =>
            row.stageNumber === 1 &&
            row.registrationId === registration.id &&
            row.assignmentId,
        );

      return {
        id: registration.id,
        teamName: team?.name ?? "Team record unavailable",
        teamPublicId: team?.team_id ?? "Unavailable",
        teamStatus: team?.status ?? "active",
        status: registration.status,
        rosterStatus: registration.roster_status,
        slotNumber: registration.slot_number,
        assignment: assignment ? {
          id: assignment.assignmentId as string,
          registrationId: registration.id,
          stageId: assignment.stageId,
          stageName: assignment.stageName,
          tierLabel: assignment.tierLabel,
          lobbyId: assignment.lobbyId,
          lobbyLabel: assignment.lobbyLabel,
          slotNumber: assignment.slotNumber,
        } : null,
        registeredAt: registration.registered_at,
        initialSession: initialSessionValid && initialSession ? {
          id: initialSession.id,
          name: initialSession.displayName,
          scheduledStartAt: initialSession.scheduledStartAt,
          scheduledEndAt: initialSession.scheduledEndAt,
          entryFeeMinor: initialSession.entryFeeMinor,
          feeCurrency: initialSession.feeCurrency,
        } : null,
        initialSessionValid,
        paymentRequired: initialSessionValid && tournament.entry_fee_minor > 0,
        paymentStatus: initialSessionPayment?.status ?? null,
        roster: (rosterByRegistration.get(registration.id) ?? []).map(
          (member) => ({
            id: member.id,
            displayName: member.display_name,
            pubgUid: member.pubg_uid,
            pubgIgn: member.pubg_ign,
            role: member.role,
          }),
        ),
      };
    },
  );
  const payments: AdminTournamentPayment[] = paymentRows.map((payment) => {
    const team = teams.get(payment.team_id);
    return {
      id: payment.id,
      registrationId: payment.registration_id,
      teamName: team?.name ?? "Team record unavailable",
      teamPublicId: team?.team_id ?? "Unavailable",
      status: payment.status,
      expectedAmountMinor: payment.expected_amount_minor,
      currency: payment.currency,
      referenceId: payment.reference_id,
      referenceConflict:
        payment.payment_method === "manual" &&
        payment.status !== "rejected" &&
        payment.manual_reference_normalized !== null &&
        (activeReferenceCounts.get(payment.manual_reference_normalized) ?? 0) > 1,
      submittedAt: payment.submitted_at,
    };
  });
  const credits: AdminTournamentCredit[] = ((creditResult.data ?? []) as CreditRow[]).map((credit) => {
    const team = teams.get(credit.team_id);
    return {
      id: credit.id,
      registrationId: credit.registration_id,
      teamName: team?.name ?? "Team record unavailable",
      teamPublicId: team?.team_id ?? "Unavailable",
      amountMinor: credit.amount_minor,
      currency: credit.currency,
      sourceReferenceId: credit.source_reference_id,
      status: credit.status,
      createdAt: credit.created_at,
    };
  });

  const confirmedCount = registrations.filter(
    (registration) => registration.status === "confirmed",
  ).length;
  const pendingCount = registrations.filter(
    (registration) => registration.status === "pending",
  ).length;
  // This authenticated page renders per request; the database still rechecks
  // the authoritative start time inside every mutation.
  // eslint-disable-next-line react-hooks/purity
  const beforeStart = Date.now() < new Date(tournament.scheduled_start_at).getTime();
  const registrationOperational =
    tournament.status === "registration_open" ||
    tournament.status === "registration_closed";
  const canManageRegistrations =
    beforeStart && registrationOperational && !tournament.archived_at;

  return (
    <>
      <AuthenticatedHeader />
      <main className="min-h-svh px-5 pb-14 pt-[calc(var(--header-height)+2.5rem)] sm:px-8 sm:pb-20 lg:px-10">
        <div className="mx-auto w-full max-w-7xl">
          <Link
            href="/admin"
            className="text-[0.58rem] font-semibold uppercase tracking-[0.15em] text-foreground-muted transition-colors hover:text-accent"
          >
            ← Tournament Management
          </Link>

          <header className="mt-7 border-b border-border pb-7">
            <div className="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-3">
                  <span className="rounded-[2px] border border-accent/30 bg-accent/[0.06] px-2.5 py-1 text-[0.52rem] font-semibold uppercase tracking-[0.14em] text-accent">
                    {statusLabels[tournament.status]}
                  </span>
                  {tournament.archived_at ? (
                    <span className="rounded-[2px] border border-white/15 px-2.5 py-1 text-[0.52rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">
                      Archived
                    </span>
                  ) : null}
                  <span className="font-mono text-[0.6rem] uppercase tracking-[0.13em] text-foreground-muted">
                    {tournament.tournament_id}
                  </span>
                </div>
                <h1 className="type-display mt-4 break-words text-[clamp(2.75rem,7vw,5.75rem)] uppercase leading-[0.9]">
                  {tournament.name}
                </h1>
              </div>
              <div className="flex shrink-0 flex-wrap gap-2">
                <a
                  href="#overview"
                  className="rounded-[2px] border border-accent bg-accent px-4 py-2 text-[0.58rem] font-semibold uppercase tracking-[0.14em] text-background"
                >
                  Overview
                </a>
                <a
                  href="#stages-sessions"
                  className="rounded-[2px] border border-border-strong px-4 py-2 text-[0.58rem] font-semibold uppercase tracking-[0.14em] text-foreground transition-colors hover:border-accent hover:text-accent"
                >
                  Stages &amp; Sessions
                </a>
                <a
                  href="#registrations"
                  className="rounded-[2px] border border-border-strong px-4 py-2 text-[0.58rem] font-semibold uppercase tracking-[0.14em] text-foreground transition-colors hover:border-accent hover:text-accent"
                >
                  Registrations
                </a>
                {tournament.entry_fee_minor > 0 || payments.length || credits.length ? (
                  <a
                    href="#payments"
                    className="rounded-[2px] border border-border-strong px-4 py-2 text-[0.58rem] font-semibold uppercase tracking-[0.14em] text-foreground transition-colors hover:border-accent hover:text-accent"
                  >
                    Payments
                  </a>
                ) : null}
              </div>
            </div>
          </header>

          <section id="overview" className="scroll-mt-28 pt-8">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p className="text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-accent">
                  Tournament operations
                </p>
                <h2 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
                  Overview
                </h2>
              </div>
              <div className="flex flex-wrap gap-2 text-[0.55rem] font-semibold uppercase tracking-[0.13em]">
                <span className="rounded-[2px] border border-accent/30 px-3 py-2 text-accent">
                  {confirmedCount} / {tournament.max_team_slots} Teams Confirmed
                </span>
                <span className="rounded-[2px] border border-border-strong px-3 py-2 text-foreground-muted">
                  {pendingCount} Pending
                </span>
              </div>
            </div>

            <dl className="mt-5 grid gap-px overflow-hidden rounded-[2px] border border-border-strong bg-border sm:grid-cols-2 lg:grid-cols-4">
              {[
                [
                  "Tournament Start",
                  formatTournamentDateTime(tournament.scheduled_start_at),
                ],
                [
                  "Tournament End",
                  formatTournamentDateTime(tournament.scheduled_end_at),
                ],
                [
                  "Registration Window",
                  `${formatTournamentDateTime(tournament.registration_opens_at)} → ${formatTournamentDateTime(tournament.registration_closes_at)}`,
                ],
                [
                  "Registration Capacity",
                  `${pendingCount + confirmedCount} active registrations · ${confirmedCount}/${tournament.max_team_slots} confirmed`,
                ],
                [
                  "Legacy Schedule Hint",
                  `${tournament.matches_per_day}/day × ${tournament.number_of_days} day${tournament.number_of_days === 1 ? "" : "s"} · presentation only`,
                ],
                [
                  "Runtime Match Plan",
                  "Configured per Stage → Session → Lobby",
                ],
                [
                  "Format",
                  `${tournament.game_mode.toUpperCase()} · ${tournament.perspective.toUpperCase()}`,
                ],
                [
                  "Tournament Type",
                  tournament.entry_fee_minor === 0 ? "Free" : "Paid",
                ],
                [
                  "Initial Registration Fee",
                  tournament.entry_fee_minor === 0
                    ? "FREE"
                    : formatMoney(tournament.entry_fee_minor, tournament.currency),
                ],
                [
                  "Reward Model",
                  tournament.reward_model === "fixed_prize_pool"
                    ? "Fixed Prize Pool"
                    : "Per Kill",
                ],
                [
                  tournament.reward_model === "fixed_prize_pool"
                    ? "Prize Pool"
                    : "Per-Kill Reward",
                  formatMoney(
                    tournament.reward_model === "fixed_prize_pool"
                      ? tournament.prize_pool_minor
                      : tournament.per_kill_reward_minor,
                    tournament.currency,
                  ),
                ],
              ].map(([label, value]) => (
                <div
                  key={label}
                  className="min-w-0 bg-background-elevated/80 p-4 sm:p-5"
                >
                  <dt className="text-[0.5rem] uppercase tracking-[0.14em] text-foreground-subtle">
                    {label}
                  </dt>
                  <dd className="mt-2 break-words text-xs leading-5 text-foreground">
                    {value}
                  </dd>
                </div>
              ))}
            </dl>
          </section>

          <TournamentStageSessionManagement
            canManage={
              !tournament.archived_at &&
              tournament.status !== "cancelled" &&
              tournament.status !== "completed"
            }
            isFreeTournament={tournament.entry_fee_minor === 0}
            sessionChecks={sessionChecks}
            sessions={sessions}
            stageSetups={stageSetup}
            stages={stages}
            tournamentId={tournament.id}
            tournamentCurrency={tournament.currency}
            tournamentPublicId={tournament.tournament_id}
          />

          <TournamentSessionEntryVisibility entries={sessionEntries} />

          <TournamentLobbyManagement
            canManage={beforeStart && !tournament.archived_at && tournament.status !== "cancelled" && tournament.status !== "completed"}
            defaultLobbyCapacity={tournament.default_lobby_capacity}
            lobbies={lobbies}
            maxLobbies={tournament.max_lobbies}
            registrations={registrations}
            sessions={sessions}
            sessionTeamCounts={sessionTeamCounts}
            slotBoardRows={slotBoardRows}
            tournamentPublicId={tournament.tournament_id}
          />

          <TournamentRegistrationManagement
            canApprove={canManageRegistrations}
            maxTeamSlots={tournament.max_team_slots}
            registrations={registrations}
            tournamentPublicId={tournament.tournament_id}
          />
          {tournament.entry_fee_minor > 0 || payments.length || credits.length ? (
            <TournamentPaymentManagement
              credits={credits}
              entryFeeMinor={tournament.entry_fee_minor}
              payments={payments}
              tournamentName={tournament.name}
              tournamentPublicId={tournament.tournament_id}
              tournamentStatus={tournament.status}
            />
          ) : null}
        </div>
      </main>
    </>
  );
}
