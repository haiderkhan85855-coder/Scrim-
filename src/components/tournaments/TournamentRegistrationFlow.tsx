"use client";

import { useActionState, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";

import {
  beginTournamentRegistration,
  finalizeTournamentRoster,
  selectRegistrationInitialSession,
  submitManualTournamentPayment,
  withdrawTournamentRegistration,
  type RegistrationFlowActionState,
} from "@/app/tournaments/[tournamentId]/register/actions";
import { CopyPubgUid } from "@/components/team/CopyPubgUid";
import { SlotBoard, type SlotBoardRow } from "@/components/tournaments/SlotBoard";
import { Button } from "@/components/ui/Button";

export type RegistrationTeam = {
  id: string;
  name: string;
  teamId: string;
  shortName: string | null;
  role: "captain" | "co_captain" | "player";
};

export type RegistrationRosterMember = {
  id: string;
  teamId: string;
  displayName: string;
  pubgUid: string;
  pubgIgn: string | null;
  role: RegistrationTeam["role"];
  rosterNumber: number;
};

export type RegistrationSession = {
  id: string;
  name: string;
  sessionNumber: number;
  scheduleLabel: string | null;
  entryFeeLabel: string;
  entryFeeMinor: number;
  currency: string;
  selectable: boolean;
};

export type RegistrationRecord = {
  id: string;
  teamId: string;
  status: "pending" | "confirmed";
  rosterStatus: "draft" | "finalized" | "locked";
  rosterRevision: number;
  slotNumber: number | null;
  initialSessionId: string | null;
  credit: {
    amount: string;
    sourceReferenceId: string;
    status: "available" | "used" | "refunded";
  } | null;
  payments: {
    id: string;
    status: "pending" | "verified" | "rejected";
    expectedAmount: string;
    referenceId: string;
    submittedAt: string;
  }[];
  snapshot: (Omit<RegistrationRosterMember, "teamId"> & {
    sourceRosterMemberId: string;
  })[];
};

type Props = {
  canBeginRegistration: boolean;
  initialRegistrationFeeLabel: string;
  isFreeTournament: boolean;
  registrations: RegistrationRecord[];
  rosterLockAt: string;
  rosterLockPassed: boolean;
  registrationClosesAt: string;
  registrationClosePassed: boolean;
  rosterMaxPlayers: number;
  rosterMembers: RegistrationRosterMember[];
  rosterMinPlayers: number;
  sessions: RegistrationSession[];
  slotBoardRows: SlotBoardRow[];
  teams: RegistrationTeam[];
  tournamentPublicId: string;
  tournamentStatus: string;
};

const initialState: RegistrationFlowActionState = {};
const roleLabels = {
  captain: "Captain",
  player: "Player",
  co_captain: "Co-Captain",
} as const;

function Feedback({ state }: { state: RegistrationFlowActionState }) {
  if (!state.error && !state.success) return null;
  return (
    <p
      role={state.error ? "alert" : "status"}
      className={`mt-4 text-xs ${state.error ? "text-[#ff8a65]" : "text-[#79d49b]"}`}
    >
      {state.error ?? `✓ ${state.success}`}
    </p>
  );
}

function SectionHeading({ number, eyebrow, title }: { number: string; eyebrow: string; title: string }) {
  return (
    <div className="flex items-center gap-3">
      <span className="flex h-7 w-7 items-center justify-center border border-accent/35 text-[0.55rem] font-semibold text-accent">
        {number}
      </span>
      <div>
        <p className="text-[0.56rem] font-semibold uppercase tracking-[0.17em] text-accent">{eyebrow}</p>
        <h2 className="mt-1 text-xl font-semibold uppercase text-foreground">{title}</h2>
      </div>
    </div>
  );
}

export function TournamentRegistrationFlow({
  canBeginRegistration,
  initialRegistrationFeeLabel,
  isFreeTournament,
  registrations,
  rosterLockAt,
  rosterLockPassed,
  registrationClosesAt,
  registrationClosePassed,
  rosterMaxPlayers,
  rosterMembers,
  rosterMinPlayers,
  sessions,
  slotBoardRows,
  teams,
  tournamentPublicId,
  tournamentStatus,
}: Props) {
  const router = useRouter();
  const initialTeamId = registrations.find((registration) =>
    teams.some((team) => team.id === registration.teamId),
  )?.teamId ?? teams[0]?.id ?? "";
  const [selectedTeamId, setSelectedTeamId] = useState(initialTeamId);
  const [selectedSessionId, setSelectedSessionId] = useState(
    registrations.find((registration) => registration.teamId === initialTeamId)?.initialSessionId ?? "",
  );
  const [selectedRosterIds, setSelectedRosterIds] = useState<string[]>([]);
  const [editingSquad, setEditingSquad] = useState(false);
  const [confirmingWithdrawal, setConfirmingWithdrawal] = useState(false);
  const [beginState, beginAction, beginPending] = useActionState(beginTournamentRegistration, initialState);
  const [finalizeState, finalizeAction, finalizePending] = useActionState(finalizeTournamentRoster, initialState);
  const [sessionState, sessionAction, sessionPending] = useActionState(selectRegistrationInitialSession, initialState);
  const [paymentState, paymentAction, paymentPending] = useActionState(submitManualTournamentPayment, initialState);
  const [withdrawState, withdrawAction, withdrawPending] = useActionState(withdrawTournamentRegistration, initialState);

  useEffect(() => {
    if (beginState.success || finalizeState.success || sessionState.success || paymentState.success || withdrawState.success) router.refresh();
  }, [beginState.success, finalizeState.success, sessionState.success, paymentState.success, withdrawState.success, router]);
  const selectedTeam = teams.find((team) => team.id === selectedTeamId);
  const registration = registrations.find((item) => item.teamId === selectedTeamId);
  const latestPayment = registration?.payments[0];
  const selectedSession = sessions.find((session) => session.id === registration?.initialSessionId);
  const selectableSessions = sessions.filter((session) => session.selectable);
  const tournamentCancelled = tournamentStatus === "cancelled";
  const availableRoster = useMemo(
    () => rosterMembers.filter((member) => member.teamId === selectedTeamId),
    [rosterMembers, selectedTeamId],
  );
  const isCaptain = selectedTeam?.role === "captain";
  const isManager =
    selectedTeam?.role === "captain" || selectedTeam?.role === "co_captain";
  const canSelectInitialSession = Boolean(
    isManager && registration?.status === "pending" && !registration.payments.length
      && !tournamentCancelled,
  );
  const countValid = selectedRosterIds.length >= rosterMinPlayers && selectedRosterIds.length <= rosterMaxPlayers;
  const canFinalize = Boolean(
    isManager && registration && ["pending", "confirmed"].includes(registration.status)
      && ["draft", "finalized"].includes(registration.rosterStatus)
      && !rosterLockPassed && !tournamentCancelled,
  );
  const showSquadEditor = registration?.rosterStatus === "draft" || editingSquad;
  const currentAssignment = slotBoardRows
    .filter((row) => row.registrationId === registration?.id && row.assignmentId)
    .at(-1);

  function toggleMember(id: string) {
    setSelectedRosterIds((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
  }

  return (
    <div className="mt-8 grid gap-5">
      <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
        <SectionHeading number="01" eyebrow="Team selection" title="Choose your squad" />
        {tournamentCancelled ? (
          <div className="mt-5 border border-[#ff8a65]/40 bg-[#ff8a65]/[0.05] p-5">
            <p className="text-[0.56rem] font-semibold uppercase tracking-[0.16em] text-[#ff8a65]">Tournament cancelled</p>
            {registration?.credit?.status === "available" ? (
              <>
                <p className="mt-3 text-lg font-semibold text-foreground">Credit available: <span className="text-[#79d49b]">{registration.credit.amount}</span></p>
                <p className="mt-2 text-xs text-foreground-muted">Original payment / reference: <span className="font-mono text-foreground">{registration.credit.sourceReferenceId}</span></p>
              </>
            ) : registration?.credit ? (
              <p className="mt-3 text-sm font-semibold text-foreground">Credit status: <span className="capitalize text-foreground-muted">{registration.credit.status}</span></p>
            ) : (
              <p className="mt-3 text-sm text-foreground-muted">No verified paid registration was found for this team.</p>
            )}
            <p className="mt-3 max-w-3xl text-xs leading-5 text-foreground-muted">Future options will let your team use this credit for another tournament or request a manual cash refund. Neither action is available yet.</p>
          </div>
        ) : null}
        <p className="mt-5 max-w-3xl text-sm leading-6 text-foreground-muted">
          A captain can create a pending registration now and finalize the tournament Squad later. Current team size does not block registration.
        </p>
        {teams.length ? (
          <fieldset className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
            <legend className="sr-only">Choose an active team</legend>
            {teams.map((team) => (
              <label key={team.id} className="flex cursor-pointer items-center gap-4 rounded-[2px] border border-border-strong p-4 hover:border-accent/55">
                <input
                  type="radio"
                  checked={selectedTeamId === team.id}
                  onChange={() => {
                    setSelectedTeamId(team.id);
                    setSelectedSessionId(
                      registrations.find((item) => item.teamId === team.id)?.initialSessionId ?? "",
                    );
                    setSelectedRosterIds([]);
                    setEditingSquad(false);
                  }}
                  className="h-4 w-4 accent-[var(--accent)]"
                />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-semibold uppercase">{team.name}</span>
                  <span className="mt-1 block text-[0.55rem] uppercase tracking-[0.14em] text-foreground-muted">
                    {team.teamId}{team.shortName ? ` · ${team.shortName}` : ""}
                  </span>
                </span>
                <span className="text-[0.52rem] font-semibold uppercase tracking-[0.13em] text-accent">{roleLabels[team.role]}</span>
              </label>
            ))}
          </fieldset>
        ) : (
          <div className="mt-5 border border-border p-5">
            <p className="text-sm text-foreground-muted">You must be the active Captain of a team before entering a tournament.</p>
            <Button href="/team" variant="secondary" className="mt-4">Go to My Team</Button>
          </div>
        )}
        {selectedTeam && isManager && !registration ? (
          <form action={beginAction} className="mt-5">
            <input type="hidden" name="team_id" value={selectedTeam.id} />
            <input type="hidden" name="tournament_public_id" value={tournamentPublicId} />
            <button type="submit" disabled={!canBeginRegistration || beginPending} className="min-h-11 rounded-[2px] bg-accent px-5 text-[0.6rem] font-semibold uppercase tracking-[0.15em] text-background disabled:opacity-40">
              {beginPending ? "Creating..." : "Begin Registration"}
            </button>
            {!canBeginRegistration ? <p className="mt-3 text-xs text-[#ff8a65]">{tournamentCancelled ? "This tournament has been cancelled." : "New registrations cannot begin outside the active registration window."}</p> : null}
            <Feedback state={beginState} />
          </form>
        ) : null}
        {registration ? (
          <div className="mt-5 border-t border-border pt-5">
            <p className="text-[0.55rem] font-semibold uppercase tracking-[0.16em] text-accent">
              {registration.rosterStatus === "draft" ? "Registration started" : "Squad finalized"}
            </p>
            <p className="mt-2 text-sm font-semibold text-foreground">
              {registration.rosterStatus === "draft"
                ? "Complete your tournament Squad"
                : registration.status === "pending"
                  ? "Awaiting tournament approval"
                  : "Tournament entry confirmed"}
            </p>
            <div className="mt-4 flex flex-wrap gap-2 text-[0.54rem] font-semibold uppercase tracking-[0.13em]">
              <span className="border border-accent/30 px-3 py-2 text-accent">Registration {registration.status}</span>
              <span className="border border-border-strong px-3 py-2 text-foreground-muted">Squad {registration.rosterStatus}</span>
            </div>
            {isManager && !tournamentCancelled ? (
              <div className="mt-5 border border-[#ff8a65]/30 bg-[#ff8a65]/[0.025] p-4">
                <p className="text-[0.54rem] font-semibold uppercase tracking-[0.14em] text-[#ff8a65]">
                  Withdraw team
                </p>
                <p className="mt-2 max-w-3xl text-xs leading-5 text-foreground-muted">
                  {registrationClosePassed
                    ? "Registration has closed. A voluntary withdrawal now does not create LevelledUp credit."
                    : `Withdraw before ${registrationClosesAt} to convert eligible unused paid entries into full payer-owned LevelledUp credit.`}
                </p>
                {confirmingWithdrawal ? (
                  <div className="mt-4">
                    <p className="text-xs leading-5 text-foreground">
                      Confirm withdrawal? The registration and financial history remain permanent.
                    </p>
                    <form action={withdrawAction} className="mt-3 flex flex-wrap gap-2">
                      <input type="hidden" name="registration_id" value={registration.id} />
                      <input type="hidden" name="tournament_public_id" value={tournamentPublicId} />
                      <button type="submit" disabled={withdrawPending} className="min-h-11 rounded-[2px] border border-[#ff8a65] bg-[#ff8a65] px-4 text-[0.56rem] font-semibold uppercase tracking-[0.14em] text-background disabled:opacity-40">
                        {withdrawPending ? "Withdrawing..." : "Confirm Withdrawal"}
                      </button>
                      <button type="button" disabled={withdrawPending} onClick={() => setConfirmingWithdrawal(false)} className="min-h-11 rounded-[2px] border border-border-strong px-4 text-[0.56rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted disabled:opacity-40">
                        Keep Registration
                      </button>
                    </form>
                  </div>
                ) : (
                  <button type="button" onClick={() => setConfirmingWithdrawal(true)} className="mt-4 min-h-11 rounded-[2px] border border-[#ff8a65]/55 px-4 text-[0.56rem] font-semibold uppercase tracking-[0.14em] text-[#ff8a65]">
                    Withdraw Registration
                  </button>
                )}
                <Feedback state={withdrawState} />
              </div>
            ) : null}
          </div>
        ) : null}
        {registration?.status === "confirmed" && currentAssignment ? (
          <div className="mt-5 border border-accent/35 bg-accent/[0.05] p-5">
            <p className="text-[0.55rem] font-semibold uppercase tracking-[0.16em] text-accent">Your Assignment</p>
            <p className="type-display mt-2 text-2xl uppercase">
              {currentAssignment.stageName}{currentAssignment.tierLabel ? ` / ${currentAssignment.tierLabel}` : ""}
            </p>
            <p className="mt-2 text-sm font-semibold uppercase text-foreground">
              {currentAssignment.lobbyLabel} · Slot {String(currentAssignment.slotNumber).padStart(2, "0")}
            </p>
          </div>
        ) : null}
      </section>

      {registration ? (
        <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
          <SectionHeading number="02" eyebrow="Initial attempt" title="Choose your Session" />
          <p className="mt-5 max-w-3xl text-sm leading-6 text-foreground-muted">
            Select the exact Stage 1 Session this registration will enter. The Session price shown here is the authoritative price for one exact Session attempt; it is separate from the initial Tournament registration fee.
          </p>

          {selectedSession ? (
            <div className="mt-5 border border-[#79d49b]/35 bg-[#79d49b]/[0.04] p-4 sm:p-5">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p className="text-[0.54rem] font-semibold uppercase tracking-[0.15em] text-[#79d49b]">Selected Session</p>
                  <p className="mt-2 text-lg font-semibold text-foreground">{selectedSession.name}</p>
                  {selectedSession.scheduleLabel ? (
                    <p className="mt-2 text-xs leading-5 text-foreground-muted">{selectedSession.scheduleLabel}</p>
                  ) : (
                    <p className="mt-2 text-xs text-foreground-muted">Date and time to be announced</p>
                  )}
                </div>
                <div className="sm:text-right">
                  <p className="text-[0.52rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">Session attempt price</p>
                  <p className="mt-2 text-base font-semibold text-foreground">{selectedSession.entryFeeLabel}</p>
                  {selectedSession.entryFeeMinor === 0 ? (
                    <p className="mt-1 text-xs font-semibold text-[#79d49b]">Free · no payment required</p>
                  ) : null}
                </div>
              </div>
            </div>
          ) : registration.initialSessionId ? (
            <p role="alert" className="mt-5 border border-[#ff8a65]/40 bg-[#ff8a65]/[0.04] p-4 text-sm text-[#ff8a65]">
              The selected Session is preserved, but its details are currently unavailable. Payment remains blocked.
            </p>
          ) : null}

          {canSelectInitialSession ? (
            selectableSessions.length ? (
              <form action={sessionAction} className="mt-5">
                <input type="hidden" name="registration_id" value={registration.id} />
                <input type="hidden" name="tournament_public_id" value={tournamentPublicId} />
                <fieldset className="grid gap-3 md:grid-cols-2">
                  <legend className="sr-only">Available Stage 1 Sessions</legend>
                  {selectableSessions.map((session) => {
                    const selected = selectedSessionId === session.id;
                    return (
                      <label
                        key={session.id}
                        className={`flex min-h-24 cursor-pointer items-start gap-3 rounded-[2px] border p-4 transition-colors ${selected ? "border-accent bg-accent/[0.06]" : "border-border-strong hover:border-accent/55"}`}
                      >
                        <input
                          type="radio"
                          name="session_id"
                          value={session.id}
                          checked={selected}
                          onChange={() => setSelectedSessionId(session.id)}
                          className="mt-1 h-4 w-4 shrink-0 accent-[var(--accent)]"
                        />
                        <span className="min-w-0 flex-1">
                          <span className="block text-sm font-semibold text-foreground">{session.name}</span>
                          <span className="mt-1 block text-xs leading-5 text-foreground-muted">
                            {session.scheduleLabel ?? "Date and time to be announced"}
                          </span>
                          <span className={`mt-2 block text-xs font-semibold ${session.entryFeeMinor === 0 ? "text-[#79d49b]" : "text-accent"}`}>
                            Session attempt: {session.entryFeeLabel}{session.entryFeeMinor === 0 ? " · No payment required" : ""}
                          </span>
                        </span>
                      </label>
                    );
                  })}
                </fieldset>
                <button
                  type="submit"
                  disabled={sessionPending || !selectedSessionId || selectedSessionId === registration.initialSessionId}
                  className="mt-4 min-h-11 w-full rounded-[2px] bg-accent px-5 text-[0.6rem] font-semibold uppercase tracking-[0.15em] text-background disabled:opacity-40 sm:w-auto"
                >
                  {sessionPending ? "Saving..." : registration.initialSessionId ? "Change Session" : "Save Session"}
                </button>
                <Feedback state={sessionState} />
              </form>
            ) : (
              <p role="alert" className="mt-5 border border-[#ff8a65]/40 bg-[#ff8a65]/[0.04] p-4 text-sm text-[#ff8a65]">
                No future Stage 1 Sessions are currently available. Payment cannot continue.
              </p>
            )
          ) : registration.payments.length ? (
            <p className="mt-4 text-xs leading-5 text-foreground-muted">
              Session selection is locked because payment history already exists.
            </p>
          ) : registration.status === "confirmed" ? (
            <p className="mt-4 text-xs leading-5 text-foreground-muted">
              This confirmed registration&apos;s initial Session is locked.
            </p>
          ) : null}
        </section>
      ) : null}

      {registration ? (
        <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <SectionHeading number="03" eyebrow="Tournament Squad" title="Finalize your players" />
            <p className="text-xs leading-5 text-foreground-muted sm:text-right">Lock deadline<br /><span className="font-semibold text-foreground">{rosterLockAt}</span></p>
          </div>
          {showSquadEditor ? (
            <>
              <p className="mt-5 text-sm leading-6 text-foreground-muted">
                Select {rosterMinPlayers === rosterMaxPlayers ? rosterMinPlayers : `${rosterMinPlayers}–${rosterMaxPlayers}`} eligible player{rosterMaxPlayers === 1 ? "" : "s"}. No partial selection is persisted.
              </p>
              <form action={finalizeAction} className="mt-5">
                <input type="hidden" name="registration_id" value={registration.id} />
                <input type="hidden" name="tournament_public_id" value={tournamentPublicId} />
                <div className="grid gap-3 md:grid-cols-2">
                  {availableRoster.map((member) => {
                    const selected = selectedRosterIds.includes(member.id);
                    const maximumReached = !selected && selectedRosterIds.length >= rosterMaxPlayers;
                    return (
                      <label key={member.id} className={`rounded-[2px] border p-4 ${selected ? "border-accent bg-accent/[0.05]" : "border-border-strong"} ${canFinalize && !maximumReached ? "cursor-pointer" : "opacity-60"}`}>
                        <div className="flex items-start gap-3">
                          <input type="checkbox" name="roster_member_ids" value={member.id} checked={selected} disabled={!canFinalize || maximumReached} onChange={() => toggleMember(member.id)} className="mt-0.5 h-4 w-4 accent-[var(--accent)]" />
                          <span className="min-w-0 flex-1">
                            <span className="flex justify-between gap-2"><strong className="text-sm">#{String(member.rosterNumber).padStart(2, "0")} · {member.displayName}</strong><span className="text-[0.5rem] uppercase tracking-[0.12em] text-accent">{roleLabels[member.role]}</span></span>
                            <span className="mt-1 block text-xs text-foreground-muted">PUBG IGN: {member.pubgIgn ?? "Not provided"}</span>
                            <span className="mt-2 block font-mono text-xs">PUBG UID: {member.pubgUid}</span>
                          </span>
                        </div>
                      </label>
                    );
                  })}
                </div>
                {!availableRoster.length ? <p className="mt-3 text-sm text-[#ff8a65]">No eligible active Squad members are available.</p> : null}
                {availableRoster.length > 0 && availableRoster.length < rosterMinPlayers ? (
                  <p className="mt-3 text-sm text-[#ff8a65]">
                    This team currently has {availableRoster.length} active Squad member{availableRoster.length === 1 ? "" : "s"}, but at least {rosterMinPlayers} are required to finalize.
                  </p>
                ) : null}
                <div className="mt-5 flex flex-wrap items-center gap-3">
                  <button type="submit" disabled={!canFinalize || !countValid || finalizePending} className="min-h-11 rounded-[2px] bg-accent px-5 text-[0.6rem] font-semibold uppercase tracking-[0.15em] text-background disabled:opacity-40">
                    {finalizePending ? "Finalizing..." : editingSquad ? "Finalize Updated Squad" : "Finalize Squad"}
                  </button>
                  {editingSquad ? (
                    <button type="button" disabled={finalizePending} onClick={() => {
                      setEditingSquad(false);
                      setSelectedRosterIds([]);
                    }} className="min-h-11 rounded-[2px] border border-border-strong px-5 text-[0.6rem] font-semibold uppercase tracking-[0.15em] text-foreground-muted hover:border-accent hover:text-accent disabled:opacity-40">
                      Cancel
                    </button>
                  ) : null}
                  <span className="text-xs font-semibold text-foreground">
                    Selected {selectedRosterIds.length} / {rosterMaxPlayers} maximum
                  </span>
                </div>
                <p className="mt-3 text-xs text-foreground-muted">
                  Minimum required to finalize: {rosterMinPlayers}.
                </p>
                {rosterLockPassed ? <p className="mt-3 text-xs text-[#ff8a65]">The tournament Squad-lock deadline has passed.</p> : null}
                <Feedback state={finalizeState} />
              </form>
            </>
          ) : (
            <>
              <div className="mt-5 border border-[#79d49b]/30 bg-[#79d49b]/[0.04] p-4">
                <p className="text-sm font-semibold text-[#79d49b]">✓ Squad finalized</p>
                <p className="mt-2 text-xs leading-5 text-foreground-muted">
                  {registration.status === "pending" ? "Awaiting tournament approval. " : "Tournament entry confirmed. "}
                  This submitted Squad revision is an immutable tournament snapshot.
                </p>
                {!rosterLockPassed && !tournamentCancelled && registration.rosterStatus === "finalized" && isManager ? (
                  <button type="button" onClick={() => {
                    const activeMemberIds = new Set(availableRoster.map((member) => member.id));
                    setSelectedRosterIds(registration.snapshot
                      .map((member) => member.sourceRosterMemberId)
                      .filter((memberId) => activeMemberIds.has(memberId)));
                    setEditingSquad(true);
                  }} className="mt-4 min-h-10 rounded-[2px] border border-accent/50 px-4 text-[0.56rem] font-semibold uppercase tracking-[0.14em] text-accent hover:bg-accent/[0.07]">
                    Edit Squad
                  </button>
                ) : null}
                {rosterLockPassed ? <p className="mt-3 text-xs text-foreground-muted">The Squad lock has passed. This selection can no longer be changed.</p> : null}
              </div>
              <div className="mt-5 grid gap-3 md:grid-cols-2">
                {registration.snapshot.map((member) => (
                  <div key={member.id} className="rounded-[2px] border border-border-strong p-4">
                    <div className="flex justify-between gap-3"><div><strong className="text-sm">#{String(member.rosterNumber).padStart(2, "0")} · {member.displayName}</strong><p className="mt-1 text-xs text-foreground-muted">PUBG IGN: {member.pubgIgn ?? "Not provided"}</p></div><span className="text-[0.5rem] uppercase tracking-[0.12em] text-accent">{roleLabels[member.role]}</span></div>
                    <div className="mt-3"><CopyPubgUid value={member.pubgUid} /></div>
                  </div>
                ))}
              </div>
            </>
          )}
        </section>
      ) : null}

      {registration && !isFreeTournament ? (
        <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
          <SectionHeading number="04" eyebrow="Payment" title="Registration payment" />
          <p className="mt-5 max-w-3xl text-sm leading-6 text-foreground-muted">
            The Initial Registration Fee is set by this Tournament and is separate from the selected Session&apos;s attempt price. Future retry purchases are not available here. Submit only the transaction or reference ID; LevelledUp never requests wallet PINs, passwords or OTPs.
          </p>
          <div className="mt-5 grid gap-3 md:grid-cols-2">
            <div className="border border-border-strong p-4 sm:p-5">
              <p className="text-[0.56rem] font-semibold uppercase tracking-[0.16em] text-accent">Manual payment</p>
              <p className="mt-3 text-sm leading-6 text-foreground-muted">
                Initial Registration Fee: <strong className="text-foreground">{initialRegistrationFeeLabel}</strong>
              </p>
              {tournamentCancelled ? (
                <p className="mt-4 text-sm text-foreground-muted">Payment activity is closed because this tournament was cancelled.</p>
              ) : !selectedSession ? (
                <p className="mt-4 text-sm font-semibold text-[#ff8a65]">Select and save an available Stage 1 Session before continuing to payment.</p>
              ) : !selectedSession.selectable ? (
                <p className="mt-4 text-sm font-semibold text-[#ff8a65]">The selected Session is no longer available for payment.</p>
              ) : latestPayment?.status === "verified" ? (
                <p className="mt-4 text-sm font-semibold text-[#79d49b]">✓ Payment verified</p>
              ) : latestPayment?.status === "pending" ? (
                <p className="mt-4 text-sm font-semibold text-accent">Payment pending verification</p>
              ) : registration.rosterStatus === "draft" ? (
                <p className="mt-4 text-xs leading-5 text-foreground-muted">Finalize the tournament Squad before submitting payment.</p>
              ) : (
                <form action={paymentAction} className="mt-4">
                  <input type="hidden" name="registration_id" value={registration.id} />
                  <input type="hidden" name="tournament_public_id" value={tournamentPublicId} />
                  <label className="block text-[0.54rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">
                    Transaction / reference ID
                    <input name="reference_id" required minLength={3} maxLength={120} autoComplete="off" placeholder="Enter payment reference" className="mt-2 min-h-11 w-full border border-border-strong bg-background px-3 text-sm normal-case tracking-normal text-foreground outline-none focus:border-accent" />
                  </label>
                  <button type="submit" disabled={paymentPending} className="mt-3 min-h-11 rounded-[2px] bg-accent px-5 text-[0.58rem] font-semibold uppercase tracking-[0.14em] text-background disabled:opacity-40">
                    {paymentPending ? "Submitting..." : "Submit for verification"}
                  </button>
                  <Feedback state={paymentState} />
                </form>
              )}
              {latestPayment?.status === "rejected" ? <p className="mt-3 text-xs text-[#ff8a65]">The previous submission was rejected. Check the reference and submit a new payment attempt.</p> : null}
            </div>
            <div className="border border-border-strong p-4 sm:p-5">
              <p className="text-[0.56rem] font-semibold uppercase tracking-[0.16em] text-accent">Online payment</p>
              <p className="mt-3 text-sm leading-6 text-foreground-muted">A secure external merchant checkout will be connected later. LevelledUp will not collect wallet PINs, OTPs, or payment credentials.</p>
              <button type="button" disabled className="mt-4 min-h-11 border border-border-strong px-5 text-[0.58rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted disabled:cursor-not-allowed disabled:opacity-60">Pay securely · Coming soon</button>
            </div>
          </div>
          {registration.payments.length ? (
            <div className="mt-4 border-t border-border pt-4">
              <p className="text-[0.54rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">Payment history</p>
              <div className="mt-3 grid gap-2">
                {registration.payments.map((payment) => (
                  <div key={payment.id} className="flex flex-col gap-1 border border-border px-3 py-2 text-xs sm:flex-row sm:items-center sm:justify-between">
                    <span className="font-mono text-foreground">{payment.referenceId}</span>
                    <span className="uppercase text-foreground-muted">{payment.expectedAmount} · {payment.status}</span>
                  </div>
                ))}
              </div>
            </div>
          ) : null}
        </section>
      ) : null}

      {registration?.status === "confirmed" ? (
        <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
          <SectionHeading number={isFreeTournament ? "04" : "05"} eyebrow="Competition assignment" title="Lobby slot board" />
          <div className="mt-5">
            <SlotBoard
              highlightedRegistrationId={registration.id}
              rows={slotBoardRows}
            />
          </div>
        </section>
      ) : null}

    </div>
  );
}
