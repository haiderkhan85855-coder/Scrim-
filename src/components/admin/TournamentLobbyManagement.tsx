"use client";

import { useActionState, useMemo, useState } from "react";

import {
  createSessionLobby,
  deleteTournamentLobby,
  generateSessionLobbies,
  reassignRegistrationSlot,
  renameTournamentLobby,
  resizeTournamentLobby,
  type RegistrationActionState,
} from "@/app/admin/tournaments/[tournamentId]/actions";
import type {
  AdminTournamentLobby,
  AdminTournamentRegistration,
  AdminTournamentSession,
} from "@/components/admin/types";
import type { SlotBoardRow } from "@/components/tournaments/SlotBoard";

const initialState: RegistrationActionState = {};

const controlClass =
  "min-h-10 rounded-[2px] border border-border-strong bg-background px-3 text-xs text-foreground outline-none transition-colors focus:border-accent";
const buttonClass =
  "inline-flex min-h-10 items-center justify-center rounded-[2px] border px-4 text-[0.56rem] font-semibold uppercase tracking-[0.13em] transition-colors disabled:pointer-events-none disabled:opacity-40";
const labelClass =
  "text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted";

function Feedback({ state }: { state: RegistrationActionState }) {
  if (!state.error && !state.success) return null;

  return (
    <p
      className={`mt-3 text-xs leading-5 ${
        state.error ? "text-[#ff8a65]" : "text-[#79d49b]"
      }`}
      role={state.error ? "alert" : "status"}
    >
      {state.error ?? `✓ ${state.success}`}
    </p>
  );
}

export function TournamentLobbyManagement({
  canManage,
  defaultLobbyCapacity,
  lobbies,
  maxLobbies,
  registrations,
  sessions,
  sessionTeamCounts,
  slotBoardRows,
  tournamentPublicId,
}: {
  canManage: boolean;
  defaultLobbyCapacity: number;
  lobbies: AdminTournamentLobby[];
  maxLobbies: number;
  registrations: AdminTournamentRegistration[];
  sessions: AdminTournamentSession[];
  sessionTeamCounts: Record<string, number>;
  slotBoardRows: SlotBoardRow[];
  tournamentPublicId: string;
}) {
  const [selectedSessionId, setSelectedSessionId] = useState(
    sessions[0]?.id ?? "",
  );
  const [selectedLobbyId, setSelectedLobbyId] = useState("");
  const [teamsPerLobby, setTeamsPerLobby] = useState(
    String(defaultLobbyCapacity),
  );
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  const [createState, createAction, createPending] = useActionState(
    createSessionLobby,
    initialState,
  );
  const [generateState, generateAction, generatePending] = useActionState(
    generateSessionLobbies,
    initialState,
  );
  const [assignState, assignAction, assignPending] = useActionState(
    reassignRegistrationSlot,
    initialState,
  );
  const [renameState, renameAction, renamePending] = useActionState(
    renameTournamentLobby,
    initialState,
  );
  const [resizeState, resizeAction, resizePending] = useActionState(
    resizeTournamentLobby,
    initialState,
  );
  const [deleteState, deleteAction, deletePending] = useActionState(
    deleteTournamentLobby,
    initialState,
  );

  const selectedSession =
    sessions.find((session) => session.id === selectedSessionId) ??
    sessions[0] ??
    null;
  const sessionLobbies = useMemo(
    () =>
      selectedSession
        ? lobbies
            .filter((lobby) => lobby.sessionId === selectedSession.id)
            .sort((a, b) => a.order - b.order)
        : [],
    [lobbies, selectedSession],
  );
  const selectedLobby =
    sessionLobbies.find((lobby) => lobby.id === selectedLobbyId) ??
    sessionLobbies[0] ??
    null;
  const teamCount = selectedSession
    ? (sessionTeamCounts[selectedSession.id] ?? 0)
    : 0;
  const perLobby = Number(teamsPerLobby);
  const suggestedLobbyCount =
    Number.isSafeInteger(perLobby) && perLobby > 0
      ? Math.max(1, Math.ceil(teamCount / perLobby))
      : 1;

  const confirmedRegistrations = registrations.filter(
    (registration) => registration.status === "confirmed",
  );
  const selectedRows = useMemo(
    () =>
      selectedLobby
        ? slotBoardRows
            .filter((row) => row.lobbyId === selectedLobby.id)
            .sort((left, right) => left.slotNumber - right.slotNumber)
        : [],
    [selectedLobby, slotBoardRows],
  );
  const assignedCount = selectedRows.filter((row) => row.assignmentId).length;
  const sessionLobbyLimitReached = sessionLobbies.length >= maxLobbies;

  const pickSession = (sessionId: string) => {
    setSelectedSessionId(sessionId);
    setSelectedLobbyId("");
    setConfirmingDelete(false);
  };

  return (
    <section className="pt-10" aria-labelledby="lobby-management-heading">
      <div className="flex flex-col gap-4 border-b border-border pb-5 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-accent">
            Tournament groups
          </p>
          <h2
            id="lobby-management-heading"
            className="type-display mt-3 text-3xl uppercase sm:text-4xl"
          >
            Lobbies
          </h2>
          <p className="mt-3 max-w-2xl text-sm leading-6 text-foreground-muted">
            Lobbies live inside a session. Pick the session, decide how many
            teams go in each lobby, and place confirmed teams manually. You can
            rename, resize, or remove empty lobbies at any point before the
            competition starts.
          </p>
        </div>

        <label className="grid gap-1.5">
          <span className={labelClass}>Session</span>
          <select
            className={`${controlClass} min-w-56`}
            value={selectedSession?.id ?? ""}
            onChange={(event) => pickSession(event.target.value)}
          >
            {sessions.map((session) => (
              <option key={session.id} value={session.id}>
                {session.displayName} ·{" "}
                {sessionTeamCounts[session.id] ?? 0} teams
              </option>
            ))}
          </select>
        </label>
      </div>

      {!sessions.length ? (
        <p className="mt-6 text-sm text-foreground-muted">
          No sessions exist yet. Create a session first, then build its
          lobbies here.
        </p>
      ) : (
        <>
          <div className="mt-6 grid gap-4 lg:grid-cols-2">
            <form
              action={createAction}
              className="rounded-[2px] border border-border-strong bg-background-elevated/40 p-4 sm:p-5"
            >
              <input
                type="hidden"
                name="tournament_public_id"
                value={tournamentPublicId}
              />
              <input
                type="hidden"
                name="session_id"
                value={selectedSession?.id ?? ""}
              />
              <h3 className="text-[0.6rem] font-semibold uppercase tracking-[0.15em] text-foreground">
                Add one lobby
              </h3>
              <div className="mt-3 flex flex-wrap items-end gap-2">
                <label className="grid gap-1.5">
                  <span className={labelClass}>Teams in this lobby</span>
                  <input
                    className={`${controlClass} w-28`}
                    type="number"
                    name="capacity"
                    min={1}
                    max={100}
                    defaultValue={defaultLobbyCapacity}
                    required
                  />
                </label>
                <button
                  type="submit"
                  disabled={
                    createPending ||
                    !canManage ||
                    !selectedSession ||
                    sessionLobbyLimitReached
                  }
                  className={`${buttonClass} border-border-strong text-foreground hover:border-accent hover:text-accent`}
                >
                  {createPending ? "Creating..." : "Add Lobby"}
                </button>
              </div>
              <Feedback state={createState} />
            </form>

            <form
              action={generateAction}
              className="rounded-[2px] border border-border-strong bg-background-elevated/40 p-4 sm:p-5"
            >
              <input
                type="hidden"
                name="tournament_public_id"
                value={tournamentPublicId}
              />
              <input
                type="hidden"
                name="session_id"
                value={selectedSession?.id ?? ""}
              />
              <h3 className="text-[0.6rem] font-semibold uppercase tracking-[0.15em] text-foreground">
                Generate lobbies for this session
              </h3>
              <div className="mt-3 flex flex-wrap items-end gap-2">
                <label className="grid gap-1.5">
                  <span className={labelClass}>Teams per lobby</span>
                  <input
                    className={`${controlClass} w-28`}
                    type="number"
                    name="teams_per_lobby"
                    min={1}
                    max={100}
                    value={teamsPerLobby}
                    onChange={(event) =>
                      setTeamsPerLobby(event.target.value)
                    }
                    required
                  />
                </label>
                <label className="grid gap-1.5">
                  <span className={labelClass}>Lobby count</span>
                  <input
                    className={`${controlClass} w-28`}
                    type="number"
                    name="lobby_count"
                    min={1}
                    max={26}
                    defaultValue={suggestedLobbyCount}
                    key={`${selectedSession?.id}-${suggestedLobbyCount}`}
                    required
                  />
                </label>
                <button
                  type="submit"
                  disabled={
                    generatePending ||
                    !canManage ||
                    !selectedSession ||
                    sessionLobbyLimitReached
                  }
                  className={`${buttonClass} border-accent bg-accent text-background hover:bg-accent-hover`}
                >
                  {generatePending ? "Generating..." : "Generate"}
                </button>
              </div>
              <p className="mt-2 text-xs text-foreground-muted">
                {teamCount} {teamCount === 1 ? "team" : "teams"} in this
                session
                {Number.isSafeInteger(perLobby) && perLobby > 0
                  ? ` → ${suggestedLobbyCount} ${suggestedLobbyCount === 1 ? "lobby" : "lobbies"} suggested`
                  : ""}
                .
              </p>
              <Feedback state={generateState} />
            </form>
          </div>

          {sessionLobbyLimitReached ? (
            <p className="mt-3 text-xs text-foreground-muted">
              This session has reached its configured maximum of {maxLobbies}{" "}
              lobbies.
            </p>
          ) : null}

          {sessionLobbies.length ? (
            <>
              <div
                className="mt-6 flex gap-2 overflow-x-auto pb-1"
                role="tablist"
                aria-label="Session lobbies"
              >
                {sessionLobbies.map((lobby) => {
                  const selected = lobby.id === selectedLobby?.id;
                  return (
                    <button
                      key={lobby.id}
                      type="button"
                      role="tab"
                      aria-selected={selected}
                      onClick={() => {
                        setSelectedLobbyId(lobby.id);
                        setConfirmingDelete(false);
                      }}
                      className={`shrink-0 rounded-[2px] border px-4 py-2.5 text-[0.58rem] font-semibold uppercase tracking-[0.14em] transition-colors ${
                        selected
                          ? "border-accent bg-accent text-background"
                          : "border-border-strong text-foreground-muted hover:border-accent hover:text-accent"
                      }`}
                    >
                      {lobby.label}
                    </button>
                  );
                })}
              </div>

              {selectedLobby ? (
                <div
                  role="tabpanel"
                  className="mt-4 overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated/55"
                >
                  <div className="flex flex-col gap-2 border-b border-border p-4 sm:flex-row sm:items-center sm:justify-between sm:p-5">
                    <div>
                      <h3 className="type-display text-2xl uppercase sm:text-3xl">
                        {selectedLobby.label}
                      </h3>
                      <p className="mt-1 text-xs text-foreground-muted">
                        {assignedCount} / {selectedLobby.capacity} slots
                        assigned · {selectedLobby.status}
                      </p>
                    </div>
                    <span className="font-mono text-[0.54rem] uppercase tracking-[0.13em] text-foreground-subtle">
                      Lobby-local slots
                    </span>
                  </div>

                  <div className="grid gap-px bg-border sm:grid-cols-2 xl:grid-cols-4">
                    {selectedRows.map((slot) => (
                      <div
                        key={slot.slotNumber}
                        className="flex min-h-16 items-center gap-3 bg-background px-4 py-3"
                      >
                        <span className="w-7 shrink-0 font-mono text-xs font-semibold text-accent">
                          {String(slot.slotNumber).padStart(2, "0")}
                        </span>
                        <div className="min-w-0 flex-1">
                          <p
                            className={`truncate text-xs font-semibold uppercase ${
                              slot.teamName
                                ? "text-foreground"
                                : "text-foreground-subtle"
                            }`}
                          >
                            {slot.teamName ?? "Open"}
                          </p>
                          {slot.teamCode ? (
                            <p className="mt-1 font-mono text-[0.5rem] uppercase tracking-[0.11em] text-foreground-muted">
                              {slot.teamCode}
                            </p>
                          ) : null}
                        </div>
                      </div>
                    ))}
                  </div>

                  <form
                    action={assignAction}
                    className="grid gap-3 border-t border-border p-4 sm:grid-cols-[minmax(0,1fr)_8rem_auto] sm:items-end sm:p-5"
                  >
                    <input
                      type="hidden"
                      name="tournament_public_id"
                      value={tournamentPublicId}
                    />
                    <input
                      type="hidden"
                      name="lobby_id"
                      value={selectedLobby.id}
                    />
                    <label className="grid gap-1.5">
                      <span className={labelClass}>Confirmed team</span>
                      <select
                        className={controlClass}
                        name="registration_id"
                        required
                        defaultValue=""
                      >
                        <option value="" disabled>
                          Select team
                        </option>
                        {confirmedRegistrations.map((registration) => (
                          <option
                            key={registration.id}
                            value={registration.id}
                          >
                            {registration.teamName} ·{" "}
                            {registration.teamPublicId}
                          </option>
                        ))}
                      </select>
                    </label>
                    <label className="grid gap-1.5">
                      <span className={labelClass}>Slot</span>
                      <input
                        className={controlClass}
                        type="number"
                        name="slot_number"
                        min={1}
                        max={selectedLobby.capacity}
                        required
                      />
                    </label>
                    <button
                      type="submit"
                      disabled={
                        assignPending ||
                        !canManage ||
                        !confirmedRegistrations.length
                      }
                      className={`${buttonClass} border-accent bg-accent text-background hover:bg-accent-hover`}
                    >
                      {assignPending ? "Assigning..." : "Assign Team"}
                    </button>
                  </form>
                  <div className="px-4 pb-2 sm:px-5">
                    <Feedback state={assignState} />
                  </div>

                  <div className="grid gap-4 border-t border-border p-4 sm:p-5 lg:grid-cols-3">
                    <form action={renameAction} className="grid gap-2">
                      <input
                        type="hidden"
                        name="tournament_public_id"
                        value={tournamentPublicId}
                      />
                      <input
                        type="hidden"
                        name="lobby_id"
                        value={selectedLobby.id}
                      />
                      <label className="grid gap-1.5">
                        <span className={labelClass}>Rename lobby</span>
                        <input
                          key={selectedLobby.id}
                          className={controlClass}
                          name="label"
                          maxLength={80}
                          defaultValue={selectedLobby.label}
                          required
                        />
                      </label>
                      <button
                        type="submit"
                        disabled={renamePending || !canManage}
                        className={`${buttonClass} justify-self-start border-border-strong text-foreground hover:border-accent hover:text-accent`}
                      >
                        {renamePending ? "Renaming..." : "Rename"}
                      </button>
                      <Feedback state={renameState} />
                    </form>

                    <form action={resizeAction} className="grid gap-2">
                      <input
                        type="hidden"
                        name="tournament_public_id"
                        value={tournamentPublicId}
                      />
                      <input
                        type="hidden"
                        name="lobby_id"
                        value={selectedLobby.id}
                      />
                      <label className="grid gap-1.5">
                        <span className={labelClass}>
                          Teams in this lobby
                        </span>
                        <input
                          key={`cap-${selectedLobby.id}`}
                          className={`${controlClass} w-28`}
                          type="number"
                          name="capacity"
                          min={1}
                          max={100}
                          defaultValue={selectedLobby.capacity}
                          required
                        />
                      </label>
                      <button
                        type="submit"
                        disabled={resizePending || !canManage}
                        className={`${buttonClass} justify-self-start border-border-strong text-foreground hover:border-accent hover:text-accent`}
                      >
                        {resizePending ? "Updating..." : "Update size"}
                      </button>
                      <Feedback state={resizeState} />
                    </form>

                    <div className="grid gap-2 content-start">
                      <span className={labelClass}>Danger zone</span>
                      {confirmingDelete ? (
                        <form action={deleteAction} className="grid gap-2">
                          <input
                            type="hidden"
                            name="tournament_public_id"
                            value={tournamentPublicId}
                          />
                          <input
                            type="hidden"
                            name="lobby_id"
                            value={selectedLobby.id}
                          />
                          <p className="text-xs leading-5 text-foreground-muted">
                            Delete {selectedLobby.label}? Only empty lobbies
                            can be removed.
                          </p>
                          <div className="flex gap-2">
                            <button
                              type="submit"
                              disabled={deletePending || !canManage}
                              className={`${buttonClass} border-[#ff8a65] bg-[#ff8a65] text-background hover:opacity-90`}
                            >
                              {deletePending
                                ? "Deleting..."
                                : "Yes, delete"}
                            </button>
                            <button
                              type="button"
                              onClick={() => setConfirmingDelete(false)}
                              className={`${buttonClass} border-border-strong text-foreground hover:border-accent hover:text-accent`}
                            >
                              Cancel
                            </button>
                          </div>
                          <Feedback state={deleteState} />
                        </form>
                      ) : (
                        <button
                          type="button"
                          disabled={!canManage}
                          onClick={() => setConfirmingDelete(true)}
                          className={`${buttonClass} justify-self-start border-[#ff8a65] text-[#ff8a65] hover:bg-[#ff8a65] hover:text-background`}
                        >
                          Delete lobby
                        </button>
                      )}
                    </div>
                  </div>
                </div>
              ) : null}
            </>
          ) : (
            <div className="mt-6 rounded-[2px] border border-dashed border-border p-5 text-sm text-foreground-muted">
              No lobbies in this session yet. Add one above, or generate the
              full set in one go.
            </div>
          )}
        </>
      )}
    </section>
  );
}
