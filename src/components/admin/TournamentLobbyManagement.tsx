"use client";

import { useActionState, useMemo, useState } from "react";

import {
  createTournamentLobby,
  reassignRegistrationSlot,
  type RegistrationActionState,
} from "@/app/admin/tournaments/[tournamentId]/actions";
import type {
  AdminTournamentLobby,
  AdminTournamentRegistration,
} from "@/components/admin/types";
import type { SlotBoardRow } from "@/components/tournaments/SlotBoard";

const initialState: RegistrationActionState = {};

const controlClass =
  "min-h-10 rounded-[2px] border border-border-strong bg-background px-3 text-xs text-foreground outline-none transition-colors focus:border-accent";
const buttonClass =
  "inline-flex min-h-10 items-center justify-center rounded-[2px] border px-4 text-[0.56rem] font-semibold uppercase tracking-[0.13em] transition-colors disabled:pointer-events-none disabled:opacity-40";

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
  slotBoardRows,
  tournamentPublicId,
}: {
  canManage: boolean;
  defaultLobbyCapacity: number;
  lobbies: AdminTournamentLobby[];
  maxLobbies: number;
  registrations: AdminTournamentRegistration[];
  slotBoardRows: SlotBoardRow[];
  tournamentPublicId: string;
}) {
  const [selectedLobbyId, setSelectedLobbyId] = useState(lobbies[0]?.id ?? "");
  const [createState, createAction, createPending] = useActionState(
    createTournamentLobby,
    initialState,
  );
  const [assignState, assignAction, assignPending] = useActionState(
    reassignRegistrationSlot,
    initialState,
  );

  const selectedLobby =
    lobbies.find((lobby) => lobby.id === selectedLobbyId) ?? lobbies[0] ?? null;
  const confirmedRegistrations = registrations.filter(
    (registration) => registration.status === "confirmed",
  );
  const selectedRows = useMemo(
    () =>
      selectedLobby
        ? slotBoardRows
            .filter(
              (row) =>
                row.stageNumber === 1 && row.lobbyId === selectedLobby.id,
            )
            .sort((left, right) => left.slotNumber - right.slotNumber)
        : [],
    [selectedLobby, slotBoardRows],
  );
  const assignedCount = selectedRows.filter((row) => row.assignmentId).length;
  const lobbyLimitReached = lobbies.length >= maxLobbies;

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
            Registration capacity is tournament-wide. Each lobby has its own
            independent slot numbers, and confirmed teams are placed manually.
          </p>
        </div>

        <form action={createAction} className="flex flex-wrap items-end gap-2">
          <input
            type="hidden"
            name="tournament_public_id"
            value={tournamentPublicId}
          />
          <label className="grid gap-1.5">
            <span className="text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted">
              New lobby capacity
            </span>
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
            disabled={createPending || !canManage || lobbyLimitReached}
            className={`${buttonClass} border-border-strong text-foreground hover:border-accent hover:text-accent`}
          >
            {createPending ? "Creating..." : "Add Lobby"}
          </button>
        </form>
      </div>

      {lobbyLimitReached ? (
        <p className="mt-3 text-xs text-foreground-muted">
          This tournament has reached its configured maximum of {maxLobbies}{" "}
          lobbies.
        </p>
      ) : null}
      <Feedback state={createState} />

      {lobbies.length ? (
        <>
          <div
            className="mt-6 flex gap-2 overflow-x-auto pb-1"
            role="tablist"
            aria-label="Tournament lobbies"
          >
            {lobbies.map((lobby) => {
              const selected = lobby.id === selectedLobby?.id;
              return (
                <button
                  key={lobby.id}
                  type="button"
                  role="tab"
                  aria-selected={selected}
                  onClick={() => setSelectedLobbyId(lobby.id)}
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
                    {assignedCount} / {selectedLobby.capacity} slots assigned
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
                <input type="hidden" name="lobby_id" value={selectedLobby.id} />
                <label className="grid gap-1.5">
                  <span className="text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted">
                    Confirmed team
                  </span>
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
                      <option key={registration.id} value={registration.id}>
                        {registration.teamName} · {registration.teamPublicId}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="grid gap-1.5">
                  <span className="text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted">
                    Slot
                  </span>
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
                    assignPending || !canManage || !confirmedRegistrations.length
                  }
                  className={`${buttonClass} border-accent bg-accent text-background hover:bg-accent-hover`}
                >
                  {assignPending ? "Assigning..." : "Assign Team"}
                </button>
              </form>
              <div className="px-4 pb-4 sm:px-5 sm:pb-5">
                <Feedback state={assignState} />
              </div>
            </div>
          ) : null}
        </>
      ) : (
        <div className="mt-6 rounded-[2px] border border-dashed border-border p-5 text-sm text-foreground-muted">
          No lobbies are configured. Add Lobby A to begin manual placement.
        </div>
      )}
    </section>
  );
}
