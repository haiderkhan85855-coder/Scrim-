"use client";

import { useActionState, useEffect, useMemo, useState } from "react";

import {
  cancelMatch,
  completeMatch,
  finalizeMatchResult,
  generateLobbyMatches,
  getMatchResultDetails,
  openPreMatch,
  reopenMatch,
  saveMatchPlayerResults,
  saveMatchResults,
  type MatchParticipation,
  type MatchResultDetail,
  type RegistrationActionState,
} from "@/app/admin/tournaments/[tournamentId]/actions";
import PreMatchLobbyHost from "@/components/admin/PreMatchLobbyHost";
import MatchRoomCard from "@/components/admin/MatchRoomCard";
import type { SlotBoardRow } from "@/components/tournaments/SlotBoard";
import type {
  AdminLobbyMatch,
  AdminRosterEntry,
  AdminTournamentLobby,
  AdminTournamentSession,
  AdminTournamentStage,
} from "./types";

const initialActionState: RegistrationActionState = {};

type TournamentMatchResultsProps = {
  canManage: boolean;
  lobbies: AdminTournamentLobby[];
  matches: AdminLobbyMatch[];
  rosters: AdminRosterEntry[];
  sessions: AdminTournamentSession[];
  stages: AdminTournamentStage[];
  slotBoardRows: SlotBoardRow[];
  tournamentPublicId: string;
};

type ResultEntryState = {
  placement: string;
  kills: string;
  didNotPlay: boolean;
};

type PlayerRowState = {
  profileId: string | null;
  playerName: string;
  pubgUid: string;
  kills: string;
  damageDealt: string;
};

const emptyPlayerRow: PlayerRowState = {
  profileId: null,
  playerName: "",
  pubgUid: "",
  kills: "",
  damageDealt: "",
};

function ActionMessage({ state }: { state: RegistrationActionState }) {
  if (!state.error && !state.success) return null;
  return (
    <p
      role={state.error ? "alert" : "status"}
      className={`mt-3 text-xs leading-5 ${
        state.error ? "text-red-400" : "text-emerald-400"
      }`}
    >
      {state.error ?? state.success}
    </p>
  );
}

function StatusBadge({ status }: { status: AdminLobbyMatch["status"] }) {
  const styles: Record<AdminLobbyMatch["status"], string> = {
    scheduled: "border-border-strong text-foreground-muted",
    pre_match: "border-sky-400/40 text-sky-300",
    live: "border-amber-400/40 text-amber-300",
    completed: "border-emerald-400/40 text-emerald-300",
    cancelled: "border-red-400/40 text-red-300",
  };
  return (
    <span
      className={`rounded-[2px] border px-2 py-1 text-[0.55rem] font-semibold uppercase tracking-[0.12em] ${styles[status]}`}
    >
      {status}
    </span>
  );
}

export function TournamentMatchResults({
  canManage,
  lobbies,
  matches,
  rosters,
  sessions,
  stages,
  slotBoardRows,
  tournamentPublicId,
}: TournamentMatchResultsProps) {
  const [generateState, generateAction] = useActionState(
    generateLobbyMatches,
    initialActionState,
  );
  const [saveState, saveAction] = useActionState(
    saveMatchResults,
    initialActionState,
  );
  const [finalizeState, finalizeAction] = useActionState(
    finalizeMatchResult,
    initialActionState,
  );
  const [completeState, completeAction] = useActionState(
    completeMatch,
    initialActionState,
  );
  const [openLobbyState, openLobbyAction] = useActionState(
    openPreMatch,
    initialActionState,
  );
  const [cancelState, cancelAction] = useActionState(
    cancelMatch,
    initialActionState,
  );
  const [reopenState, reopenAction] = useActionState(
    reopenMatch,
    initialActionState,
  );
  const [playersState, playersAction] = useActionState(
    saveMatchPlayerResults,
    initialActionState,
  );

  const stageNumberByStageId = useMemo(() => {
    const map = new Map<string, number>();
    for (const stage of stages) map.set(stage.id, stage.stageNumber);
    return map;
  }, [stages]);

  const sortedSessions = useMemo(
    () =>
      [...sessions].sort((a, b) => {
        const stageA = stageNumberByStageId.get(a.stageId) ?? 0;
        const stageB = stageNumberByStageId.get(b.stageId) ?? 0;
        if (stageA !== stageB) return stageA - stageB;
        return a.sessionNumber - b.sessionNumber;
      }),
    [sessions, stageNumberByStageId],
  );

  const [sessionId, setSessionId] = useState(
    sortedSessions[0]?.id ?? "",
  );
  const sessionLobbies = useMemo(
    () => lobbies.filter((lobby) => lobby.sessionId === sessionId),
    [lobbies, sessionId],
  );
  const [lobbyId, setLobbyId] = useState(sessionLobbies[0]?.id ?? "");

  useEffect(() => {
    setSessionId(sortedSessions[0]?.id ?? "");
  }, [sortedSessions]);
  useEffect(() => {
    setLobbyId(sessionLobbies[0]?.id ?? "");
  }, [sessionLobbies]);

  const lobbyMatches = useMemo(
    () =>
      matches
        .filter((match) => match.lobbyId === lobbyId)
        .sort((a, b) => a.matchNumber - b.matchNumber),
    [matches, lobbyId],
  );
  const [matchId, setMatchId] = useState(lobbyMatches[0]?.id ?? "");
  useEffect(() => {
    setMatchId(lobbyMatches[0]?.id ?? "");
  }, [lobbyMatches]);

  const selectedMatch = lobbyMatches.find((match) => match.id === matchId);
  const selectedLobby = sessionLobbies.find((lobby) => lobby.id === lobbyId);
  const selectedSession = sortedSessions.find(
    (session) => session.id === sessionId,
  );

  const [details, setDetails] = useState<MatchResultDetail[] | null>(null);
  const [participations, setParticipations] = useState<MatchParticipation[]>([]);

  const lobbyTeams = useMemo(
    () =>
      slotBoardRows.filter(
        (row) => row.lobbyId === lobbyId && row.assignmentId && row.registrationId,
      ),
    [slotBoardRows, lobbyId],
  );

  // Once a result is recorded for a match, its participation proof is frozen:
  // the form offers only the teams that played, no matter how lobby
  // assignments change afterwards. Before the first result there is no proof
  // yet, so the form falls back to the current lobby assignments.
  const participationLocked = participations.length > 0;
  const formTeams = useMemo(
    () =>
      participationLocked
        ? participations.map((participation) => ({
            registrationId: participation.registrationId,
            teamName: participation.teamName,
            teamCode: participation.teamCode,
          }))
        : lobbyTeams,
    [participationLocked, participations, lobbyTeams],
  );

  const [detailsLoading, setDetailsLoading] = useState(false);
  const [detailsError, setDetailsError] = useState<string | null>(null);
  const [showCancelForm, setShowCancelForm] = useState(false);
  const [showReopenForm, setShowReopenForm] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    if (!matchId) {
      setDetails(null);
      setParticipations([]);
      return;
    }
    let cancelled = false;
    setDetailsLoading(true);
    setDetailsError(null);
    getMatchResultDetails(matchId).then((result) => {
      if (cancelled) return;
      setDetailsLoading(false);
      if (result.error || !result.results) {
        setDetailsError(result.error ?? "Match results could not be loaded.");
        setDetails(null);
        setParticipations([]);
        return;
      }
      setDetails(result.results);
      setParticipations(result.participations ?? []);
    });
    return () => {
      cancelled = true;
    };
  }, [matchId, refreshKey]);

  useEffect(() => {
    if (saveState.success || finalizeState.success || playersState.success) {
      setRefreshKey((key) => key + 1);
    }
  }, [saveState.success, finalizeState.success, playersState.success]);

  const [entries, setEntries] = useState<Record<string, ResultEntryState>>({});
  useEffect(() => {
    const seeded: Record<string, ResultEntryState> = {};
    for (const team of formTeams) {
      const existing = details?.find(
        (result) => result.registrationId === team.registrationId,
      );
      seeded[team.registrationId as string] = {
        placement: existing && !existing.didNotPlay ? String(existing.placement) : "",
        kills: existing && !existing.didNotPlay ? String(existing.kills) : "",
        didNotPlay: existing?.didNotPlay ?? false,
      };
    }
    setEntries(seeded);
  }, [formTeams, details]);

  const [openPlayerEditor, setOpenPlayerEditor] = useState<string | null>(null);
  const [playerRows, setPlayerRows] = useState<PlayerRowState[]>([]);
  const [playerResultId, setPlayerResultId] = useState<string | null>(null);

  function openPlayers(result: MatchResultDetail) {
    setPlayerResultId(result.resultId);
    setPlayerRows(
      result.players.length
        ? result.players.map((player) => ({
            profileId: player.profileId,
            playerName: player.playerName,
            pubgUid: player.pubgUid ?? "",
            kills: String(player.kills),
            damageDealt: String(player.damageDealt),
          }))
        : [{ ...emptyPlayerRow }],
    );
    setOpenPlayerEditor(result.resultId);
  }

  const rosterByRegistration = useMemo(() => {
    const grouped = new Map<string, AdminRosterEntry[]>();
    for (const entry of rosters) {
      const list = grouped.get(entry.registrationId) ?? [];
      list.push(entry);
      grouped.set(entry.registrationId, list);
    }
    return grouped;
  }, [rosters]);

  const resultsPayload = useMemo(() => {
    const payload: Array<{
      registrationId: string;
      placement: number | null;
      kills: number | null;
      did_not_play: boolean;
    }> = [];
    for (const team of formTeams) {
      const entry = entries[team.registrationId as string];
      if (!entry) continue;
      if (entry.didNotPlay) {
        payload.push({
          registrationId: team.registrationId as string,
          placement: null,
          kills: null,
          did_not_play: true,
        });
        continue;
      }
      if (!entry.placement.trim()) continue;
      payload.push({
        registrationId: team.registrationId as string,
        placement: Number(entry.placement),
        kills: Number(entry.kills || 0),
        did_not_play: false,
      });
    }
    return payload;
  }, [entries, formTeams]);

  const playersPayload = useMemo(
    () =>
      playerRows
        .filter((row) => row.playerName.trim())
        .map((row) => ({
          profileId: row.profileId,
          playerName: row.playerName.trim(),
          pubgUid: row.pubgUid.trim() || null,
          kills: Number(row.kills || 0),
          damageDealt: Number(row.damageDealt || 0),
        })),
    [playerRows],
  );

  const configuredMatchCount = selectedSession ? (
    <span className="text-foreground-muted">
      {selectedSession.defaultMatchesPerLobby ?? "not set"} matches configured
      for this session
    </span>
  ) : null;

  return (
    <section id="match-results" className="scroll-mt-28 pt-10">
      <p className="text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-accent">
        Match operations
      </p>
      <h2 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
        Match results
      </h2>
      <p className="mt-3 max-w-3xl text-sm leading-6 text-foreground-muted">
        Generate the matches for a lobby, then enter each team&apos;s placement
        and kills. Teams are picked from this lobby only, so a result can never
        land on the wrong lobby&apos;s team. Player data is optional at submit
        time and can be added or edited later.
      </p>

      <div className="mt-6 flex flex-wrap items-end gap-4">
        <label className="flex flex-col gap-2">
          <span className="text-[0.55rem] font-semibold uppercase tracking-[0.14em] text-foreground-subtle">
            Session
          </span>
          <select
            value={sessionId}
            onChange={(event) => setSessionId(event.target.value)}
            className="rounded-[2px] border border-border-strong bg-background-elevated px-3 py-2.5 text-sm text-foreground"
          >
            {sortedSessions.map((session) => (
              <option key={session.id} value={session.id}>
                Stage {stageNumberByStageId.get(session.stageId) ?? "—"} —
                Session {session.sessionNumber}
              </option>
            ))}
          </select>
        </label>
        <div className="flex flex-wrap gap-2">
          {sessionLobbies.map((lobby) => (
            <button
              key={lobby.id}
              type="button"
              onClick={() => setLobbyId(lobby.id)}
              className={`rounded-[2px] border px-4 py-2.5 text-[0.6rem] font-semibold uppercase tracking-[0.13em] transition-colors ${
                lobby.id === lobbyId
                  ? "border-accent bg-accent text-background"
                  : "border-border-strong text-foreground-muted hover:border-accent hover:text-accent"
              }`}
            >
              {lobby.label}
            </button>
          ))}
          {sessionLobbies.length === 0 ? (
            <p className="text-sm text-foreground-muted">
              Create a lobby in this session first.
            </p>
          ) : null}
        </div>
      </div>

      {selectedLobby ? (
        <div className="mt-6">
          {canManage && lobbyMatches.length === 0 ? (
            <form
              action={generateAction}
              className="flex flex-wrap items-end gap-3 rounded-[2px] border border-border-strong bg-background-elevated/60 p-4"
            >
              <input
                type="hidden"
                name="tournament_public_id"
                value={tournamentPublicId}
              />
              <input type="hidden" name="lobby_id" value={selectedLobby.id} />
              <label className="flex flex-col gap-2">
                <span className="text-[0.55rem] font-semibold uppercase tracking-[0.14em] text-foreground-subtle">
                  Map rotation (optional, comma separated)
                </span>
                <input
                  name="map_rotation"
                  placeholder="erangel, miramar"
                  className="w-56 rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm text-foreground"
                />
              </label>
              <button
                type="submit"
                className="rounded-[2px] bg-accent px-5 py-2.5 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-background transition-opacity hover:opacity-90"
              >
                Generate matches
              </button>
              <span className="pb-2.5 text-xs">{configuredMatchCount}</span>
            </form>
          ) : null}
          <ActionMessage state={generateState} />

          {lobbyMatches.length > 0 ? (
            <>
              <div className="mt-4 flex flex-wrap gap-2">
                {lobbyMatches.map((match) => (
                  <button
                    key={match.id}
                    type="button"
                    onClick={() => setMatchId(match.id)}
                    className={`flex items-center gap-2 rounded-[2px] border px-4 py-2.5 text-[0.6rem] font-semibold uppercase tracking-[0.13em] transition-colors ${
                      match.id === matchId
                        ? "border-accent bg-accent text-background"
                        : "border-border-strong text-foreground-muted hover:border-accent hover:text-accent"
                    }`}
                  >
                    Match {match.matchNumber}
                    <StatusBadge status={match.status} />
                    {match.playersPendingCount > 0 ? (
                      <span className="rounded-[2px] bg-amber-400/20 px-1.5 py-0.5 text-amber-300">
                        {match.playersPendingCount} pending
                      </span>
                    ) : null}
                  </button>
                ))}
              </div>

              {selectedMatch ? (
                <div className="mt-6 rounded-[2px] border border-border-strong bg-background-elevated/40">
                  <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border-strong p-4 sm:p-5">
                    <div>
                      <h3 className="type-display text-xl uppercase">
                        Match {selectedMatch.matchNumber} —{" "}
                        {selectedMatch.mapDisplayName}
                      </h3>
                      <p className="mt-1 text-xs text-foreground-muted">
                        {selectedMatch.resultCount} results ·{" "}
                        {selectedMatch.finalizedCount} finalized ·{" "}
                        {selectedMatch.playersPendingCount} waiting on player
                        data
                      </p>
                    </div>
                    <div className="flex flex-wrap items-center gap-3">
                      <StatusBadge status={selectedMatch.status} />
                      {canManage && selectedMatch.status === "scheduled" ? (
                        <form action={openLobbyAction}>
                          <input
                            type="hidden"
                            name="tournament_public_id"
                            value={tournamentPublicId}
                          />
                          <input
                            type="hidden"
                            name="match_id"
                            value={selectedMatch.id}
                          />
                          <button
                            type="submit"
                            className="rounded-[2px] border border-sky-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-sky-300 transition-colors hover:bg-sky-400/10"
                          >
                            Open pre-match lobby
                          </button>
                        </form>
                      ) : null}
                      {canManage &&
                      (selectedMatch.status === "scheduled" ||
                        selectedMatch.status === "pre_match" ||
                        selectedMatch.status === "live") ? (
                        <>
                          {selectedMatch.status === "live" ? (
                          <form action={completeAction}>
                            <input
                              type="hidden"
                              name="tournament_public_id"
                              value={tournamentPublicId}
                            />
                            <input
                              type="hidden"
                              name="match_id"
                              value={selectedMatch.id}
                            />
                            <button
                              type="submit"
                              className="rounded-[2px] border border-emerald-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-emerald-300 transition-colors hover:bg-emerald-400/10"
                            >
                              Complete match
                            </button>
                          </form>
                          ) : null}
                          <button
                            type="button"
                            onClick={() =>
                              setShowCancelForm((value) => !value)
                            }
                            className="rounded-[2px] border border-red-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-red-300 transition-colors hover:bg-red-400/10"
                          >
                            Cancel match
                          </button>
                        </>
                      ) : null}
                      {canManage && selectedMatch.status === "completed" ? (
                        <button
                          type="button"
                          onClick={() =>
                            setShowReopenForm((value) => !value)
                          }
                          className="rounded-[2px] border border-amber-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-amber-300 transition-colors hover:bg-amber-400/10"
                        >
                          Reopen for corrections
                        </button>
                      ) : null}
                    </div>
                  </div>
                  <ActionMessage state={openLobbyState} />
                  <ActionMessage state={completeState} />
                  {showCancelForm &&
                  canManage &&
                  (selectedMatch.status === "scheduled" ||
                    selectedMatch.status === "pre_match" ||
                    selectedMatch.status === "live") ? (
                    <form
                      action={cancelAction}
                      className="border-b border-border-strong p-4 sm:p-5"
                    >
                      <input
                        type="hidden"
                        name="tournament_public_id"
                        value={tournamentPublicId}
                      />
                      <input
                        type="hidden"
                        name="match_id"
                        value={selectedMatch.id}
                      />
                      <label className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted">
                        Reason for cancelling — required, logged
                      </label>
                      <div className="mt-2 flex gap-2">
                        <input
                          type="text"
                          name="reason"
                          required
                          placeholder="Why is this match being cancelled?"
                          className="flex-1 rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm"
                        />
                        <button
                          type="submit"
                          className="rounded-[2px] border border-red-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-red-300 transition-colors hover:bg-red-400/10"
                        >
                          Confirm cancellation
                        </button>
                      </div>
                      <ActionMessage state={cancelState} />
                    </form>
                  ) : null}
                  {showReopenForm &&
                  canManage &&
                  selectedMatch.status === "completed" ? (
                    <form
                      action={reopenAction}
                      className="border-b border-border-strong p-4 sm:p-5"
                    >
                      <input
                        type="hidden"
                        name="tournament_public_id"
                        value={tournamentPublicId}
                      />
                      <input
                        type="hidden"
                        name="match_id"
                        value={selectedMatch.id}
                      />
                      <label className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted">
                        Reason for reopening — required, logged
                      </label>
                      <div className="mt-2 flex gap-2">
                        <input
                          type="text"
                          name="reason"
                          required
                          placeholder="What needs correcting?"
                          className="flex-1 rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm"
                        />
                        <button
                          type="submit"
                          className="rounded-[2px] border border-amber-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-amber-300 transition-colors hover:bg-amber-400/10"
                        >
                          Confirm reopen
                        </button>
                      </div>
                      <ActionMessage state={reopenState} />
                    </form>
                  ) : null}
                  {selectedMatch.status === "pre_match" ? (
                    <div className="border-b border-border-strong p-4 sm:p-5">
                      <PreMatchLobbyHost
                        matchId={selectedMatch.id}
                        tournamentPublicId={tournamentPublicId}
                      />
                    </div>
                  ) : null}
                  {canManage && selectedMatch.status !== "cancelled" ? (
                    <MatchRoomCard
                      matchId={selectedMatch.id}
                      tournamentPublicId={tournamentPublicId}
                    />
                  ) : null}

                  {detailsLoading ? (
                    <p className="p-5 text-sm text-foreground-muted">
                      Loading results…
                    </p>
                  ) : detailsError ? (
                    <p role="alert" className="p-5 text-sm text-red-400">
                      {detailsError}
                    </p>
                  ) : (
                    <>
                      {canManage && selectedMatch.status === "live" ? (
                        <form
                          action={saveAction}
                          className="border-b border-border-strong p-4 sm:p-5"
                        >
                          <input
                            type="hidden"
                            name="tournament_public_id"
                            value={tournamentPublicId}
                          />
                          <input
                            type="hidden"
                            name="match_id"
                            value={selectedMatch.id}
                          />
                          <input
                            type="hidden"
                            name="results_json"
                            value={JSON.stringify(resultsPayload)}
                          />
                          <h4 className="text-[0.6rem] font-semibold uppercase tracking-[0.14em] text-foreground-subtle">
                            Enter team results
                          </h4>
                          <p className="mt-1 text-xs text-foreground-muted">
                            {participationLocked
                              ? "Only the teams recorded as playing this match are listed — the lobby roster is frozen once results begin."
                              : `Only teams assigned to ${selectedLobby.label} are listed. Tick DNP for teams that did not play — recorded as Did Not Play, never zero.`}
                          </p>
                          <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                            {formTeams.map((team) => {
                              const entry = entries[
                                team.registrationId as string
                              ] ?? { placement: "", kills: "", didNotPlay: false };
                              return (
                                <div
                                  key={team.registrationId}
                                  className={`flex items-center gap-2 rounded-[2px] border p-2.5 ${
                                    entry.didNotPlay
                                      ? "border-border bg-background/40 opacity-60"
                                      : "border-border-strong bg-background"
                                  }`}
                                >
                                  <span className="min-w-0 flex-1 truncate text-xs font-semibold text-foreground">
                                    {team.teamName}
                                  </span>
                                  <label className="flex shrink-0 items-center gap-1 text-[0.6rem] uppercase tracking-wide text-foreground-muted">
                                    <input
                                      type="checkbox"
                                      checked={entry.didNotPlay}
                                      onChange={(event) =>
                                        setEntries((prev) => ({
                                          ...prev,
                                          [team.registrationId as string]: {
                                            placement: "",
                                            kills: "",
                                            didNotPlay: event.target.checked,
                                          },
                                        }))
                                      }
                                      className="h-3.5 w-3.5 accent-[var(--accent)]"
                                    />
                                    DNP
                                  </label>
                                  <input
                                    inputMode="numeric"
                                    placeholder="#"
                                    aria-label={`Placement for ${team.teamName}`}
                                    value={entry.placement}
                                    disabled={entry.didNotPlay}
                                    onChange={(event) =>
                                      setEntries((prev) => ({
                                        ...prev,
                                        [team.registrationId as string]: {
                                          placement: event.target.value.replace(
                                            /[^0-9]/g,
                                            "",
                                          ),
                                          kills: prev[
                                            team.registrationId as string
                                          ]?.kills ?? "",
                                          didNotPlay: false,
                                        },
                                      }))
                                    }
                                    className="w-14 rounded-[2px] border border-border-strong bg-background-elevated px-2 py-1.5 text-center text-sm text-foreground disabled:opacity-40"
                                  />
                                  <input
                                    inputMode="numeric"
                                    placeholder="kills"
                                    aria-label={`Kills for ${team.teamName}`}
                                    value={entry.kills}
                                    disabled={entry.didNotPlay}
                                    onChange={(event) =>
                                      setEntries((prev) => ({
                                        ...prev,
                                        [team.registrationId as string]: {
                                          placement:
                                            prev[
                                              team.registrationId as string
                                            ]?.placement ?? "",
                                          kills: event.target.value.replace(
                                            /[^0-9]/g,
                                            "",
                                          ),
                                          didNotPlay: false,
                                        },
                                      }))
                                    }
                                    className="w-16 rounded-[2px] border border-border-strong bg-background-elevated px-2 py-1.5 text-center text-sm text-foreground disabled:opacity-40"
                                  />
                                </div>
                              );
                            })}
                          </div>
                          {formTeams.length === 0 ? (
                            <p className="mt-3 text-sm text-foreground-muted">
                              No teams are assigned to this lobby yet.
                            </p>
                          ) : (
                            <button
                              type="submit"
                              disabled={resultsPayload.length === 0}
                              className="mt-4 rounded-[2px] bg-accent px-5 py-2.5 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-background transition-opacity hover:opacity-90 disabled:opacity-40"
                            >
                              Save results as draft
                            </button>
                          )}
                          <ActionMessage state={saveState} />
                        </form>
                      ) : null}

                      <div className="p-4 sm:p-5">
                        <h4 className="text-[0.6rem] font-semibold uppercase tracking-[0.14em] text-foreground-subtle">
                          Saved results
                        </h4>
                        {(details ?? []).length === 0 ? (
                          <p className="mt-3 text-sm text-foreground-muted">
                            No results entered yet.
                          </p>
                        ) : (
                          <ul className="mt-3 space-y-2">
                            {(details ?? []).map((result) => (
                              <li
                                key={result.resultId}
                                className={`rounded-[2px] border p-3 ${
                                  result.didNotPlay
                                    ? "border-border bg-background/40 opacity-60"
                                    : "border-border-strong bg-background"
                                }`}
                              >
                                <div className="flex flex-wrap items-center gap-3">
                                  {result.didNotPlay ? (
                                    <span className="flex h-8 items-center justify-center rounded-[2px] bg-foreground-subtle/15 px-2 text-[0.6rem] font-bold uppercase tracking-wide text-foreground-subtle">
                                      DNP
                                    </span>
                                  ) : (
                                    <span className="flex h-8 w-8 items-center justify-center rounded-[2px] bg-accent/15 text-sm font-bold text-accent">
                                      {result.placement}
                                    </span>
                                  )}
                                  <div className="min-w-0 flex-1">
                                    <p className="truncate text-sm font-semibold text-foreground">
                                      {result.teamName}
                                      <span className="ml-2 font-mono text-[0.65rem] text-foreground-subtle">
                                        {result.teamCode}
                                      </span>
                                    </p>
                                    {result.didNotPlay ? (
                                      <p className="text-xs uppercase tracking-wide text-foreground-subtle">
                                        Did Not Play
                                      </p>
                                    ) : (
                                      <p className="text-xs text-foreground-muted">
                                        {result.kills} kills ·{" "}
                                        {result.totalPoints} pts
                                        {result.players.length === 0 ? (
                                          <span className="ml-2 rounded-[2px] bg-amber-400/20 px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase tracking-wide text-amber-300">
                                            Player data pending
                                          </span>
                                        ) : (
                                          <span className="ml-2 text-foreground-subtle">
                                            {result.players.length} players
                                            recorded
                                          </span>
                                        )}
                                      </p>
                                    )}
                                  </div>
                                  <span
                                    className={`rounded-[2px] border px-2 py-1 text-[0.55rem] font-semibold uppercase tracking-[0.12em] ${
                                      result.status === "final"
                                        ? "border-emerald-400/40 text-emerald-300"
                                        : "border-border-strong text-foreground-muted"
                                    }`}
                                  >
                                    {result.status}
                                  </span>
                                  {canManage ? (
                                    <div className="flex gap-2">
                                      {!result.didNotPlay ? (
                                        <button
                                          type="button"
                                          onClick={() => openPlayers(result)}
                                          className="rounded-[2px] border border-border-strong px-3 py-1.5 text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-foreground-muted transition-colors hover:border-accent hover:text-accent"
                                        >
                                          Player data
                                        </button>
                                      ) : null}
                                      {result.status === "draft" &&
                                      selectedMatch.status !== "completed" &&
                                      selectedMatch.status !== "cancelled" ? (
                                        <form action={finalizeAction}>
                                          <input
                                            type="hidden"
                                            name="tournament_public_id"
                                            value={tournamentPublicId}
                                          />
                                          <input
                                            type="hidden"
                                            name="result_id"
                                            value={result.resultId}
                                          />
                                          <button
                                            type="submit"
                                            className="rounded-[2px] border border-accent/50 px-3 py-1.5 text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-accent transition-colors hover:bg-accent hover:text-background"
                                          >
                                            Finalize
                                          </button>
                                        </form>
                                      ) : null}
                                    </div>
                                  ) : null}
                                </div>

                                {openPlayerEditor === result.resultId ? (
                                  <div className="mt-3 border-t border-border-strong pt-3">
                                    {(rosterByRegistration.get(
                                      result.registrationId,
                                    ) ?? []).length > 0 ? (
                                      <div className="mb-3 flex flex-wrap gap-2">
                                        {(
                                          rosterByRegistration.get(
                                            result.registrationId,
                                          ) ?? []
                                        ).map((member) => (
                                          <button
                                            key={`${member.pubgUid}-${member.displayName}`}
                                            type="button"
                                            onClick={() =>
                                              setPlayerRows((prev) => [
                                                ...prev,
                                                {
                                                  profileId: member.profileId,
                                                  playerName: member.displayName,
                                                  pubgUid: member.pubgUid,
                                                  kills: "",
                                                  damageDealt: "",
                                                },
                                              ])
                                            }
                                            className="rounded-[2px] border border-border-strong px-2.5 py-1.5 text-[0.65rem] font-semibold uppercase tracking-wide text-foreground-muted transition-colors hover:border-accent hover:text-accent"
                                          >
                                            + {member.displayName}
                                          </button>
                                        ))}
                                      </div>
                                    ) : null}
                                    <div className="space-y-2">
                                      {playerRows.map((row, index) => (
                                        <div
                                          key={index}
                                          className="grid grid-cols-2 gap-2 sm:grid-cols-[1fr_1fr_5rem_6rem_auto]"
                                        >
                                          <input
                                            placeholder="Player name"
                                            aria-label="Player name"
                                            value={row.playerName}
                                            onChange={(event) =>
                                              setPlayerRows((prev) =>
                                                prev.map((r, i) =>
                                                  i === index
                                                    ? {
                                                        ...r,
                                                        playerName:
                                                          event.target.value,
                                                      }
                                                    : r,
                                                ),
                                              )
                                            }
                                            className="rounded-[2px] border border-border-strong bg-background-elevated px-2.5 py-2 text-sm text-foreground"
                                          />
                                          <input
                                            placeholder="PUBG UID"
                                            aria-label="PUBG UID"
                                            value={row.pubgUid}
                                            onChange={(event) =>
                                              setPlayerRows((prev) =>
                                                prev.map((r, i) =>
                                                  i === index
                                                    ? {
                                                        ...r,
                                                        pubgUid:
                                                          event.target.value,
                                                      }
                                                    : r,
                                                ),
                                              )
                                            }
                                            className="rounded-[2px] border border-border-strong bg-background-elevated px-2.5 py-2 text-sm text-foreground"
                                          />
                                          <input
                                            inputMode="numeric"
                                            placeholder="Kills"
                                            aria-label="Player kills"
                                            value={row.kills}
                                            onChange={(event) =>
                                              setPlayerRows((prev) =>
                                                prev.map((r, i) =>
                                                  i === index
                                                    ? {
                                                        ...r,
                                                        kills:
                                                          event.target.value.replace(
                                                            /[^0-9]/g,
                                                            "",
                                                          ),
                                                      }
                                                    : r,
                                                ),
                                              )
                                            }
                                            className="rounded-[2px] border border-border-strong bg-background-elevated px-2.5 py-2 text-sm text-foreground"
                                          />
                                          <input
                                            inputMode="numeric"
                                            placeholder="Damage"
                                            aria-label="Player damage"
                                            value={row.damageDealt}
                                            onChange={(event) =>
                                              setPlayerRows((prev) =>
                                                prev.map((r, i) =>
                                                  i === index
                                                    ? {
                                                        ...r,
                                                        damageDealt:
                                                          event.target.value.replace(
                                                            /[^0-9]/g,
                                                            "",
                                                          ),
                                                      }
                                                    : r,
                                                ),
                                              )
                                            }
                                            className="rounded-[2px] border border-border-strong bg-background-elevated px-2.5 py-2 text-sm text-foreground"
                                          />
                                          <button
                                            type="button"
                                            onClick={() =>
                                              setPlayerRows((prev) =>
                                                prev.filter(
                                                  (_, i) => i !== index,
                                                ),
                                              )
                                            }
                                            className="rounded-[2px] border border-red-400/40 px-3 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-red-300"
                                          >
                                            Remove
                                          </button>
                                        </div>
                                      ))}
                                    </div>
                                    <div className="mt-3 flex flex-wrap gap-2">
                                      <button
                                        type="button"
                                        onClick={() =>
                                          setPlayerRows((prev) => [
                                            ...prev,
                                            { ...emptyPlayerRow },
                                          ])
                                        }
                                        className="rounded-[2px] border border-border-strong px-3 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-foreground-muted transition-colors hover:border-accent hover:text-accent"
                                      >
                                        + Add player
                                      </button>
                                      {canManage ? (
                                        <form action={playersAction}>
                                          <input
                                            type="hidden"
                                            name="tournament_public_id"
                                            value={tournamentPublicId}
                                          />
                                          <input
                                            type="hidden"
                                            name="result_id"
                                            value={playerResultId ?? ""}
                                          />
                                          <input
                                            type="hidden"
                                            name="players_json"
                                            value={JSON.stringify(
                                              playersPayload,
                                            )}
                                          />
                                          <button
                                            type="submit"
                                            className="rounded-[2px] bg-accent px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-background transition-opacity hover:opacity-90"
                                          >
                                            Save player data
                                          </button>
                                        </form>
                                      ) : null}
                                      <button
                                        type="button"
                                        onClick={() =>
                                          setOpenPlayerEditor(null)
                                        }
                                        className="rounded-[2px] px-3 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-foreground-subtle"
                                      >
                                        Close
                                      </button>
                                    </div>
                                    <ActionMessage state={playersState} />
                                  </div>
                                ) : null}
                              </li>
                            ))}
                          </ul>
                        )}
                        <ActionMessage state={finalizeState} />
                      </div>
                    </>
                  )}
                </div>
              ) : null}
            </>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}

export function TournamentPendingTasks({
  playersPendingCount,
}: {
  playersPendingCount: number;
}) {
  if (playersPendingCount <= 0) return null;
  return (
    <div className="mt-6 rounded-[2px] border border-amber-400/40 bg-amber-400/10 p-4 sm:p-5">
      <p className="text-[0.6rem] font-semibold uppercase tracking-[0.16em] text-amber-300">
        Pending tasks
      </p>
      <ul className="mt-2 space-y-1.5">
        <li>
          <a
            href="#match-results"
            className="text-sm text-foreground underline decoration-amber-400/50 underline-offset-4 hover:text-amber-300"
          >
            {playersPendingCount} team{" "}
            {playersPendingCount === 1 ? "result still needs" : "results still need"}{" "}
            player data →
          </a>
        </li>
      </ul>
    </div>
  );
}
