"use client";

import { useActionState, useState } from "react";

import {
  approveRegistration,
  rejectRegistration,
  type RegistrationActionState,
} from "@/app/admin/tournaments/[tournamentId]/actions";
import type {
  AdminTournamentRegistration,
  TournamentRegistrationStatus,
  TournamentRosterRole,
} from "@/components/admin/types";
import { CopyPubgUid } from "@/components/team/CopyPubgUid";
import { formatTournamentDateTime } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

const initialState: RegistrationActionState = {};

const statusOrder: TournamentRegistrationStatus[] = [
  "pending",
  "confirmed",
  "rejected",
  "withdrawn",
];

const statusLabels: Record<TournamentRegistrationStatus, string> = {
  pending: "Pending",
  confirmed: "Confirmed",
  rejected: "Rejected",
  withdrawn: "Withdrawn",
};

const roleLabels: Record<TournamentRosterRole, string> = {
  captain: "Captain",
  co_captain: "Co-Captain",
  player: "Player",
};

const rosterStatusLabels = {
  draft: "Squad Draft",
  finalized: "Squad Finalized",
  locked: "Squad Locked",
} as const;

const actionButton =
  "inline-flex min-h-9 items-center justify-center rounded-[2px] border px-3 text-[0.56rem] font-semibold uppercase tracking-[0.13em] transition-colors disabled:pointer-events-none disabled:opacity-40";

function formatMoney(value: number, currency: string) {
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

function Feedback({ states }: { states: RegistrationActionState[] }) {
  const error = states.find((state) => state.error)?.error;
  const success = states.find((state) => state.success)?.success;

  if (!error && !success) return null;

  return (
    <p
      className={`mt-3 text-xs leading-5 ${
        error ? "text-[#ff8a65]" : "text-[#79d49b]"
      }`}
      role={error ? "alert" : "status"}
    >
      {error ?? `✓ ${success}`}
    </p>
  );
}

function HiddenReferences({
  registration,
  tournamentPublicId,
}: {
  registration: AdminTournamentRegistration;
  tournamentPublicId: string;
}) {
  return (
    <>
      <input type="hidden" name="registration_id" value={registration.id} />
      <input
        type="hidden"
        name="tournament_public_id"
        value={tournamentPublicId}
      />
    </>
  );
}

function RegistrationCard({
  canApprove,
  isFull,
  registration,
  tournamentPublicId,
}: {
  canApprove: boolean;
  isFull: boolean;
  registration: AdminTournamentRegistration;
  tournamentPublicId: string;
}) {
  const [approveState, approveAction, approvePending] = useActionState(
    approveRegistration,
    initialState,
  );
  const [rejectState, rejectAction, rejectPending] = useActionState(
    rejectRegistration,
    initialState,
  );
  const [reviewMode, setReviewMode] = useState<"approve" | "reject" | null>(
    null,
  );
  const pending = approvePending || rejectPending;

  return (
    <article className="rounded-[2px] border border-border-strong bg-background-elevated/55 p-4 sm:p-5">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="rounded-[2px] border border-accent/25 bg-accent/[0.05] px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-accent">
              {statusLabels[registration.status]}
            </span>
            <span className="rounded-[2px] border border-border-strong px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted">
              {rosterStatusLabels[registration.rosterStatus]}
            </span>
            {registration.teamStatus === "disbanded" ? (
              <span className="rounded-[2px] border border-[#ff8a65]/40 px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-[#ff8a65]">
                Disbanded
              </span>
            ) : null}
            {registration.assignment ? (
              <span className="rounded-[2px] border border-white/15 px-2 py-1 font-mono text-[0.54rem] font-semibold uppercase tracking-[0.12em] text-foreground">
                {registration.assignment.lobbyLabel} · Slot{" "}
                {String(registration.assignment.slotNumber).padStart(2, "0")}
              </span>
            ) : registration.status === "confirmed" ? (
              <span className="rounded-[2px] border border-accent/35 px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-accent">
                Awaiting lobby assignment
              </span>
            ) : null}
            {!registration.initialSessionValid ? (
              <span className="rounded-[2px] border border-[#ff8a65]/40 px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-[#ff8a65]">
                Session required
              </span>
            ) : registration.paymentRequired ? (
              <span className={`rounded-[2px] border px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] ${registration.paymentStatus === "verified" ? "border-[#79d49b]/40 text-[#79d49b]" : registration.paymentStatus === "rejected" ? "border-[#ff8a65]/40 text-[#ff8a65]" : "border-accent/35 text-accent"}`}>
                Payment {registration.paymentStatus ?? "not submitted"}
              </span>
            ) : (
              <span className="rounded-[2px] border border-[#79d49b]/30 px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-[#79d49b]">Free entry</span>
            )}
          </div>
          <h4 className="type-display mt-3 break-words text-2xl uppercase leading-none sm:text-3xl">
            {registration.teamName}
          </h4>
          <p className="mt-2 font-mono text-[0.6rem] uppercase tracking-[0.12em] text-foreground-muted">
            {registration.teamPublicId}
          </p>
        </div>
        <div className="shrink-0 text-left sm:text-right">
          <p className="text-[0.5rem] uppercase tracking-[0.14em] text-foreground-subtle">
            Registered
          </p>
          <p className="mt-1 text-xs text-foreground-muted">
            {formatTournamentDateTime(registration.registeredAt)}
          </p>
        </div>
      </div>

      <div className="mt-5 border-t border-border pt-5">
        <h5 className="text-[0.58rem] font-semibold uppercase tracking-[0.16em] text-foreground">
          Initial Session
        </h5>
        {registration.initialSession ? (
          <div className="mt-3 grid gap-3 rounded-[2px] border border-border bg-background/60 p-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start">
            <div className="min-w-0">
              <p className="break-words text-sm font-semibold text-foreground">
                {registration.initialSession.name}
              </p>
              <p className="mt-1 text-xs leading-5 text-foreground-muted">
                {registration.initialSession.scheduledStartAt
                  ? registration.initialSession.scheduledEndAt
                    ? `${formatTournamentDateTime(registration.initialSession.scheduledStartAt)} → ${formatTournamentDateTime(registration.initialSession.scheduledEndAt)}`
                    : formatTournamentDateTime(registration.initialSession.scheduledStartAt)
                  : "Date and time to be announced"}
              </p>
            </div>
            <div className="sm:text-right">
              <p className="text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-foreground-subtle">
                Session attempt price
              </p>
              <p className="mt-1 text-sm font-semibold text-foreground">
                {formatMoney(
                  registration.initialSession.entryFeeMinor,
                  registration.initialSession.feeCurrency,
                )}
              </p>
              {registration.initialSession.entryFeeMinor === 0 ? (
                <p className="mt-1 text-xs font-semibold text-[#79d49b]">
                  No payment required
                </p>
              ) : null}
            </div>
          </div>
        ) : (
          <p role="alert" className="mt-3 border border-[#ff8a65]/40 bg-[#ff8a65]/[0.04] p-4 text-xs leading-5 text-[#ff8a65]">
            The selected initial Session is missing or invalid. Approval is blocked until the Captain saves a valid Stage 1 Session.
          </p>
        )}
      </div>

      <div className="mt-5 border-t border-border pt-5">
        <div className="flex items-center justify-between gap-3">
          <h5 className="text-[0.58rem] font-semibold uppercase tracking-[0.16em] text-foreground">
            Submitted Squad
          </h5>
          <span className="text-[0.52rem] uppercase tracking-[0.13em] text-foreground-subtle">
            {registration.roster.length} player
            {registration.roster.length === 1 ? "" : "s"}
          </span>
        </div>

        {registration.roster.length ? (
          <div className="mt-3 grid gap-2 lg:grid-cols-2">
            {registration.roster.map((member) => (
              <div
                key={member.id}
                className="min-w-0 rounded-[2px] border border-border bg-background/60 p-3"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="break-words text-sm font-semibold text-foreground">
                      {member.displayName}
                    </p>
                    <p className="mt-1 break-words text-xs text-foreground-muted">
                      PUBG IGN: {member.pubgIgn ?? "Not provided"}
                    </p>
                  </div>
                  <span className="shrink-0 text-[0.5rem] font-semibold uppercase tracking-[0.12em] text-accent">
                    {roleLabels[member.role]}
                  </span>
                </div>
                <div className="mt-3">
                  <p className="mb-1 text-[0.48rem] uppercase tracking-[0.13em] text-foreground-subtle">
                    PUBG UID
                  </p>
                  <CopyPubgUid value={member.pubgUid} />
                </div>
              </div>
            ))}
          </div>
        ) : (
          <p className="mt-3 text-xs leading-5 text-[#ff8a65]">
            The captain has not finalized this tournament Squad yet. This
            registration cannot be approved.
          </p>
        )}
      </div>

      {registration.status === "pending" ? (
        <div className="mt-5 border-t border-border pt-4">
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              className={`${actionButton} border-accent bg-accent text-background hover:bg-accent-hover`}
              disabled={
                pending ||
                isFull ||
                !canApprove ||
                !registration.initialSessionValid ||
                registration.rosterStatus === "draft" ||
                (registration.paymentRequired && registration.paymentStatus !== "verified")
              }
              onClick={() => setReviewMode("approve")}
            >
              Approve Registration
            </button>
            <button
              type="button"
              className={`${actionButton} border-[#ff8a65]/45 text-[#ff8a65] hover:bg-[#ff8a65]/[0.06]`}
              disabled={pending}
              onClick={() => setReviewMode("reject")}
            >
              Reject Registration
            </button>
          </div>

          {isFull ? (
            <p className="mt-3 text-xs text-[#ff8a65]">
              Tournament is full. Pending registrations remain preserved.
            </p>
          ) : !canApprove ? (
            <p className="mt-3 text-xs text-foreground-muted">
              Approval is unavailable after the tournament starts or outside
              registration operations.
            </p>
          ) : !registration.initialSessionValid ? (
            <p className="mt-3 text-xs text-[#ff8a65]">
              Approval requires a valid selected Stage 1 Session.
            </p>
          ) : registration.paymentRequired && registration.paymentStatus !== "verified" ? (
            <p className="mt-3 text-xs text-foreground-muted">A verified payment is required before this paid registration can be approved.</p>
          ) : null}

          {reviewMode ? (
            <div className="mt-3 rounded-[2px] border border-border bg-background/60 p-3">
              <p className="text-xs leading-5 text-foreground-muted">
                {reviewMode === "approve"
                  ? "Confirm approval. The database will recheck tournament capacity. Lobby and slot placement is managed separately."
                  : "Confirm rejection. The registration and submitted Squad will remain in tournament history."}
              </p>
              <form
                action={reviewMode === "approve" ? approveAction : rejectAction}
                className="mt-3 flex flex-wrap gap-2"
              >
                <HiddenReferences
                  registration={registration}
                  tournamentPublicId={tournamentPublicId}
                />
                <button
                  type="submit"
                  disabled={pending}
                  className={`${actionButton} ${
                    reviewMode === "approve"
                      ? "border-accent bg-accent text-background"
                      : "border-[#ff8a65] bg-[#ff8a65] text-background"
                  }`}
                >
                  {pending
                    ? "Updating..."
                    : reviewMode === "approve"
                      ? "Confirm Approval"
                      : "Confirm Rejection"}
                </button>
                <button
                  type="button"
                  disabled={pending}
                  onClick={() => setReviewMode(null)}
                  className={`${actionButton} border-border-strong text-foreground-muted`}
                >
                  Go Back
                </button>
              </form>
            </div>
          ) : null}

          <Feedback states={[approveState, rejectState]} />
        </div>
      ) : null}

      {registration.status === "confirmed" ? (
        <p className="mt-5 border-t border-border pt-4 text-xs text-foreground-muted">
          {registration.assignment
            ? `Assigned to ${registration.assignment.lobbyLabel} · Slot ${String(registration.assignment.slotNumber).padStart(2, "0")}.`
            : "Confirmed. Assign this team to a lobby and lobby-local slot in the Lobbies section."}
        </p>
      ) : null}
    </article>
  );
}

export function TournamentRegistrationManagement({
  canApprove,
  maxTeamSlots,
  registrations,
  tournamentPublicId,
}: {
  canApprove: boolean;
  maxTeamSlots: number;
  registrations: AdminTournamentRegistration[];
  tournamentPublicId: string;
}) {
  const confirmedCount = registrations.filter(
    (registration) => registration.status === "confirmed",
  ).length;
  const pendingCount = registrations.filter(
    (registration) => registration.status === "pending",
  ).length;
  const isFull = confirmedCount >= maxTeamSlots;

  return (
    <section id="registrations" className="scroll-mt-28 pt-10">
      <div className="flex flex-col gap-4 border-b border-border pb-5 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-accent">
            Registration operations
          </p>
          <h2 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
            Registrations
          </h2>
        </div>
        <div className="flex flex-wrap gap-2 text-[0.56rem] font-semibold uppercase tracking-[0.13em]">
          <span
            className={`rounded-[2px] border px-3 py-2 ${
              isFull
                ? "border-[#ff8a65]/40 text-[#ff8a65]"
                : "border-accent/30 text-accent"
            }`}
          >
            {confirmedCount} / {maxTeamSlots} Teams Confirmed
          </span>
          <span className="rounded-[2px] border border-border-strong px-3 py-2 text-foreground-muted">
            {pendingCount} Pending
          </span>
        </div>
      </div>

      <div className="mt-6 grid gap-8">
        {statusOrder.map((status) => {
          const grouped = registrations.filter(
            (registration) => registration.status === status,
          );

          return (
            <section key={status} aria-labelledby={`${status}-registrations`}>
              <div className="flex items-center justify-between gap-3">
                <h3
                  id={`${status}-registrations`}
                  className="text-[0.62rem] font-semibold uppercase tracking-[0.17em] text-foreground"
                >
                  {statusLabels[status]}
                </h3>
                <span className="font-mono text-xs text-foreground-subtle">
                  {String(grouped.length).padStart(2, "0")}
                </span>
              </div>

              {grouped.length ? (
                <div className="mt-3 grid gap-3">
                  {grouped.map((registration) => (
                    <RegistrationCard
                      key={registration.id}
                      canApprove={canApprove}
                      isFull={isFull}
                      registration={registration}
                      tournamentPublicId={tournamentPublicId}
                    />
                  ))}
                </div>
              ) : (
                <div className="mt-3 rounded-[2px] border border-dashed border-border p-5 text-xs text-foreground-subtle">
                  No {statusLabels[status].toLowerCase()} registrations.
                </div>
              )}
            </section>
          );
        })}
      </div>
    </section>
  );
}
