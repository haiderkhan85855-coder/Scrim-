"use client";

import Link from "next/link";
import { useActionState, useState } from "react";

import {
  cancelTournament,
  closeTournamentRegistration,
  openTournamentRegistration,
  retireTournament,
  type TournamentActionState,
} from "@/app/admin/actions";
import { TournamentForm } from "@/components/admin/TournamentForm";
import type {
  AdminTournament,
  TournamentStatus,
} from "@/components/admin/types";
import { formatTournamentDateTime } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

const initialState: TournamentActionState = {};
const smallButton =
  "inline-flex min-h-9 items-center justify-center rounded-[2px] border px-3 text-[0.56rem] font-semibold uppercase tracking-[0.14em] transition-colors disabled:pointer-events-none disabled:opacity-40";

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

function Feedback({ states }: { states: TournamentActionState[] }) {
  const error = states.find((state) => state.error)?.error;
  const success = states.find((state) => state.success)?.success;
  if (!error && !success) return null;

  return (
    <p
      role={error ? "alert" : "status"}
      className={`mt-3 text-xs leading-5 ${
        error ? "text-[#ff8a65]" : "text-[#79d49b]"
      }`}
    >
      {error ?? `✓ ${success}`}
    </p>
  );
}

function LifecycleControls({ tournament }: { tournament: AdminTournament }) {
  const [openState, openAction, openPending] = useActionState(
    openTournamentRegistration,
    initialState,
  );
  const [closeState, closeAction, closePending] = useActionState(
    closeTournamentRegistration,
    initialState,
  );
  const [cancelState, cancelAction, cancelPending] = useActionState(
    cancelTournament,
    initialState,
  );
  const [retireState, retireAction, retirePending] = useActionState(
    retireTournament,
    initialState,
  );
  const [confirmingCancel, setConfirmingCancel] = useState(false);
  const [confirmingRetire, setConfirmingRetire] = useState(false);
  const [confirmation, setConfirmation] = useState("");
  const [retireConfirmation, setRetireConfirmation] = useState("");
  const isPending =
    openPending || closePending || cancelPending || retirePending;
  const cancellationMatches =
    confirmation.trim().toUpperCase() === tournament.tournamentId;
  const retirementMatches =
    retireConfirmation.trim().toUpperCase() === tournament.tournamentId;

  return (
    <div className="mt-5 border-t border-border pt-5">
      <div className="flex flex-wrap gap-2">
        {tournament.status === "draft" ? (
          <form action={openAction}>
            <input type="hidden" name="tournament_id" value={tournament.id} />
            <input
              type="hidden"
              name="public_tournament_id"
              value={tournament.tournamentId}
            />
            <button
              type="submit"
              disabled={isPending}
              className={`${smallButton} border-accent bg-accent text-background hover:bg-accent-hover`}
            >
              {openPending ? "Opening..." : "Open Registration"}
            </button>
          </form>
        ) : null}

        {tournament.status === "registration_open" ? (
          <form action={closeAction}>
            <input type="hidden" name="tournament_id" value={tournament.id} />
            <input
              type="hidden"
              name="public_tournament_id"
              value={tournament.tournamentId}
            />
            <button
              type="submit"
              disabled={isPending}
              className={`${smallButton} border-accent text-accent hover:bg-accent/[0.06]`}
            >
              {closePending ? "Closing..." : "Close Registration"}
            </button>
          </form>
        ) : null}

        {!(["completed", "cancelled"] as TournamentStatus[]).includes(
          tournament.status,
        ) ? (
          <button
            type="button"
            onClick={() => setConfirmingCancel(true)}
            disabled={isPending}
            className={`${smallButton} border-[#ff8a65]/40 text-[#ff8a65] hover:bg-[#ff8a65]/[0.05]`}
          >
            Cancel Tournament
          </button>
        ) : null}

        {!tournament.archivedAt ? (
          <button
            type="button"
            onClick={() => {
              setConfirmingCancel(false);
              setConfirmingRetire(true);
            }}
            disabled={isPending}
            className={`${smallButton} border-[#ff5c5c]/50 text-[#ff7777] hover:bg-[#ff5c5c]/[0.07]`}
          >
            Delete Tournament
          </button>
        ) : null}
      </div>

      {confirmingCancel &&
      tournament.status !== "completed" &&
      tournament.status !== "cancelled" ? (
        <div className="mt-4 rounded-[2px] border border-[#ff8a65]/35 bg-[#ff8a65]/[0.04] p-4">
          <p className="text-xs leading-5 text-foreground-muted">
            Cancellation preserves registrations, Squads, slots, payments and competition history. Every verified paid registration will receive a team credit equal to the tournament entry fee. Type
            <span className="mx-1 font-semibold text-[#ff8a65]">
              {tournament.tournamentId}
            </span>
            to confirm.
          </p>
          <form action={cancelAction} className="mt-3">
            <input type="hidden" name="tournament_id" value={tournament.id} />
            <input
              type="hidden"
              name="public_tournament_id"
              value={tournament.tournamentId}
            />
            <input
              name="confirmation"
              value={confirmation}
              onChange={(event) => setConfirmation(event.target.value)}
              disabled={cancelPending}
              autoComplete="off"
              className="h-10 w-full max-w-sm rounded-[2px] border border-border-strong bg-background px-3 text-sm uppercase tracking-[0.08em] text-foreground outline-none focus:border-[#ff8a65]"
              placeholder={tournament.tournamentId}
            />
            <div className="mt-3 flex flex-wrap gap-2">
              <button
                type="submit"
                disabled={!cancellationMatches || cancelPending}
                className={`${smallButton} border-[#ff8a65] bg-[#ff8a65] text-background`}
              >
                {cancelPending ? "Cancelling..." : "Confirm Cancellation"}
              </button>
              <button
                type="button"
                onClick={() => {
                  setConfirmingCancel(false);
                  setConfirmation("");
                }}
                disabled={cancelPending}
                className={`${smallButton} border-border-strong text-foreground-muted`}
              >
                Keep Tournament
              </button>
            </div>
          </form>
        </div>
      ) : null}

      {confirmingRetire && !tournament.archivedAt ? (
        <div className="mt-4 rounded-[2px] border border-[#ff5c5c]/45 bg-[#ff5c5c]/[0.05] p-4">
          <p className="text-xs font-semibold uppercase tracking-[0.12em] text-[#ff7777]">
            Historical data warning
          </p>
          <p className="mt-2 max-w-3xl text-xs leading-5 text-foreground-muted">
            This action may affect player and team history. Only an untouched
            draft can be physically deleted. If registrations, Squad snapshots,
            slots, matches, results, standings, payouts, reviews, or other history
            exists, LevelledUp will preserve every record and archive the
            tournament instead. If cancellation is required, verified paid registrations receive team credit entitlements before the tournament is archived.
          </p>
          <p className="mt-3 text-xs leading-5 text-foreground-muted">
            Type
            <span className="mx-1 font-semibold text-[#ff7777]">
              {tournament.tournamentId}
            </span>
            to continue.
          </p>
          <form action={retireAction} className="mt-3">
            <input type="hidden" name="tournament_id" value={tournament.id} />
            <input
              type="hidden"
              name="public_tournament_id"
              value={tournament.tournamentId}
            />
            <input
              name="confirmation"
              value={retireConfirmation}
              onChange={(event) => setRetireConfirmation(event.target.value)}
              disabled={retirePending}
              autoComplete="off"
              aria-label="Confirm permanent Tournament ID"
              className="h-10 w-full max-w-sm rounded-[2px] border border-border-strong bg-background px-3 text-sm uppercase tracking-[0.08em] text-foreground outline-none focus:border-[#ff5c5c]"
              placeholder={tournament.tournamentId}
            />
            <div className="mt-3 flex flex-wrap gap-2">
              <button
                type="submit"
                disabled={!retirementMatches || retirePending}
                className={`${smallButton} border-[#ff5c5c] bg-[#ff5c5c] text-background`}
              >
                {retirePending ? "Checking History..." : "Confirm Delete"}
              </button>
              <button
                type="button"
                onClick={() => {
                  setConfirmingRetire(false);
                  setRetireConfirmation("");
                }}
                disabled={retirePending}
                className={`${smallButton} border-border-strong text-foreground-muted`}
              >
                Keep Tournament
              </button>
            </div>
          </form>
        </div>
      ) : null}

      <Feedback
        states={[openState, closeState, cancelState, retireState]}
      />
    </div>
  );
}

export function TournamentManagement({
  tournaments,
}: {
  tournaments: AdminTournament[];
}) {
  const [createOpen, setCreateOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [updatedTournamentId, setUpdatedTournamentId] = useState<string | null>(
    null,
  );

  return (
    <>
      <section className="mt-10 rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
        <div className="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
              Tournament setup
            </p>
            <h2 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
              Create Tournament
            </h2>
            <p className="mt-3 max-w-xl text-sm leading-6 text-foreground-muted">
              New tournaments remain private drafts until registration is opened.
              All date and time fields use Pakistan Standard Time (PKT).
            </p>
          </div>
          {!createOpen ? (
            <button
              type="button"
              onClick={() => setCreateOpen(true)}
              className="inline-flex min-h-11 shrink-0 items-center justify-center rounded-[2px] bg-accent px-5 text-[0.62rem] font-semibold uppercase tracking-[0.16em] text-background transition-colors hover:bg-accent-hover"
            >
              Create Tournament
            </button>
          ) : null}
        </div>

        {createOpen ? (
          <TournamentForm onCancel={() => setCreateOpen(false)} />
        ) : null}
      </section>

      <section className="mt-8">
        <div className="flex items-end justify-between gap-4 border-b border-border pb-5">
          <div>
            <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
              Tournament management
            </p>
            <h2 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
              Existing Tournaments
            </h2>
          </div>
          <p className="text-[0.58rem] font-semibold uppercase tracking-[0.15em] text-foreground-muted">
            {tournaments.length} total
          </p>
        </div>

        {tournaments.length ? (
          <div className="mt-5 grid gap-5">
            {tournaments.map((tournament) => (
              <article
                key={tournament.id}
                className="min-w-0 rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7"
              >
                <div className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-3">
                      <span className="rounded-[2px] border border-accent/30 bg-accent/[0.06] px-2.5 py-1 text-[0.52rem] font-semibold uppercase tracking-[0.14em] text-accent">
                        {statusLabels[tournament.status]}
                      </span>
                      {tournament.archivedAt ? (
                        <span className="rounded-[2px] border border-white/15 px-2.5 py-1 text-[0.52rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">
                          Archived
                        </span>
                      ) : null}
                      <span className="break-all text-[0.58rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
                        {tournament.tournamentId}
                      </span>
                    </div>
                    <h3 className="type-display mt-4 break-words text-3xl uppercase leading-none sm:text-4xl">
                      {tournament.name}
                    </h3>
                    {tournament.description ? (
                      <p className="mt-4 max-w-3xl text-sm leading-6 text-foreground-muted">
                        {tournament.description}
                      </p>
                    ) : null}
                  </div>

                  <div className="flex shrink-0 flex-wrap gap-2">
                    <Link
                      href={`/admin/tournaments/${tournament.tournamentId}`}
                      className={`${smallButton} border-accent text-accent hover:bg-accent/[0.06]`}
                    >
                      Manage Tournament
                    </Link>
                    {tournament.status === "draft" && !tournament.archivedAt ? (
                      <button
                        type="button"
                        onClick={() =>
                          setEditingId((current) => {
                            setUpdatedTournamentId(null);
                            return current === tournament.id ? null : tournament.id;
                          })
                        }
                        className={`${smallButton} border-border-strong text-foreground hover:border-accent hover:text-accent`}
                      >
                        {editingId === tournament.id
                          ? "Close Edit"
                          : "Edit Tournament"}
                      </button>
                    ) : null}
                  </div>
                </div>

                <dl className="mt-6 grid gap-x-6 gap-y-5 border-t border-border pt-6 sm:grid-cols-2 lg:grid-cols-4">
                  <div>
                    <dt className="text-[0.54rem] uppercase tracking-[0.15em] text-foreground-subtle">
                      Tournament Start
                    </dt>
                    <dd className="mt-2 text-xs leading-5 text-foreground">
                      {formatTournamentDateTime(tournament.scheduledStartAt)}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-[0.54rem] uppercase tracking-[0.15em] text-foreground-subtle">
                      Registration Window
                    </dt>
                    <dd className="mt-2 text-xs leading-5 text-foreground">
                      {formatTournamentDateTime(
                        tournament.registrationOpensAt,
                      )}
                      <span className="block text-foreground-muted">
                        to{" "}
                        {formatTournamentDateTime(
                          tournament.registrationClosesAt,
                        )}
                      </span>
                    </dd>
                  </div>
                  <div>
                    <dt className="text-[0.54rem] uppercase tracking-[0.15em] text-foreground-subtle">
                      Format
                    </dt>
                    <dd className="mt-2 text-xs uppercase leading-5 text-foreground">
                      {tournament.gameMode} · {tournament.perspective}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-[0.54rem] uppercase tracking-[0.15em] text-foreground-subtle">
                      Team Slots
                    </dt>
                    <dd className="mt-2 text-xs text-foreground">
                      {tournament.maxTeamSlots}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-[0.54rem] uppercase tracking-[0.15em] text-foreground-subtle">
                      Legacy Schedule Guide
                    </dt>
                    <dd className="mt-2 text-xs text-foreground">
                      {tournament.matchesPerDay}/day · {tournament.numberOfDays}{" "}
                      planned day{tournament.numberOfDays === 1 ? "" : "s"}
                      <span className="block text-foreground-muted">Presentation fields only</span>
                    </dd>
                  </div>
                  <div>
                    <dt className="text-[0.54rem] uppercase tracking-[0.15em] text-foreground-subtle">
                      Tournament Type
                    </dt>
                    <dd className="mt-2 text-xs text-foreground">
                      {tournament.entryFeeMinor === 0 ? "Free" : "Paid"}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-[0.54rem] uppercase tracking-[0.15em] text-foreground-subtle">
                      Initial Registration Fee
                    </dt>
                    <dd className="mt-2 text-xs text-foreground">
                      {tournament.entryFeeMinor === 0
                        ? "FREE"
                        : formatMoney(tournament.entryFeeMinor, tournament.currency)}
                    </dd>
                  </div>
                  <div className="sm:col-span-2">
                    <dt className="text-[0.54rem] uppercase tracking-[0.15em] text-foreground-subtle">
                      Reward
                    </dt>
                    <dd className="mt-2 text-xs text-foreground">
                      {tournament.rewardModel === "fixed_prize_pool"
                        ? `Fixed prize pool · ${formatMoney(
                            tournament.prizePoolMinor,
                            tournament.currency,
                          )}`
                        : `Per kill · ${formatMoney(
                            tournament.perKillRewardMinor,
                            tournament.currency,
                          )}`}
                    </dd>
                  </div>
                </dl>

                {editingId === tournament.id ? (
                  <div className="mt-6 border-t border-border pt-1">
                    <TournamentForm
                      key={tournament.id}
                      tournament={tournament}
                      onCancel={() => setEditingId(null)}
                      onSuccess={() => {
                        setEditingId(null);
                        setUpdatedTournamentId(tournament.id);
                      }}
                    />
                  </div>
                ) : (
                  <>
                    {updatedTournamentId === tournament.id ? (
                      <p
                        role="status"
                        className="mt-5 text-xs leading-5 text-[#79d49b]"
                      >
                        ✓ Tournament updated
                      </p>
                    ) : null}
                    <LifecycleControls tournament={tournament} />
                  </>
                )}
              </article>
            ))}
          </div>
        ) : (
          <div className="mt-5 rounded-[2px] border border-border-strong bg-background-elevated/45 p-7 text-sm leading-6 text-foreground-muted">
            No tournaments exist yet. Create the first private draft above.
          </div>
        )}
      </section>
    </>
  );
}
