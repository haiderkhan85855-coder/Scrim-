"use client";

import { useActionState, useState } from "react";

import {
  confirmCancelledTournamentPayment,
  rejectCancelledTournamentPayment,
  rejectTournamentPayment,
  verifyTournamentPayment,
  type RegistrationActionState,
} from "@/app/admin/tournaments/[tournamentId]/actions";
import type { AdminTournamentCredit, AdminTournamentPayment, TournamentStatus } from "@/components/admin/types";
import { formatTournamentDateTime } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

const initialState: RegistrationActionState = {};
const buttonClass = "inline-flex min-h-9 items-center justify-center rounded-[2px] border px-3 text-[0.56rem] font-semibold uppercase tracking-[0.13em] disabled:pointer-events-none disabled:opacity-40";

function formatMoney(value: number, currency: string) {
  const digits = currencyFractionDigits(currency);
  const amount = value / 10 ** digits;
  try {
    return new Intl.NumberFormat("en-PK", {
      style: "currency", currency, minimumFractionDigits: 0,
      maximumFractionDigits: digits,
    }).format(amount);
  } catch {
    return `${currency} ${amount}`;
  }
}

function PaymentCard({ payment, tournamentCancelled, tournamentName, tournamentPublicId }: { payment: AdminTournamentPayment; tournamentCancelled: boolean; tournamentName: string; tournamentPublicId: string }) {
  const verifyHandler = tournamentCancelled
    ? confirmCancelledTournamentPayment
    : verifyTournamentPayment;
  const rejectHandler = tournamentCancelled
    ? rejectCancelledTournamentPayment
    : rejectTournamentPayment;
  const [verifyState, verifyAction, verifyPending] = useActionState(verifyHandler, initialState);
  const [rejectState, rejectAction, rejectPending] = useActionState(rejectHandler, initialState);
  const [decision, setDecision] = useState<"verify" | "reject" | null>(null);
  const pending = verifyPending || rejectPending;
  const feedback = verifyState.error ?? rejectState.error;
  const success = verifyState.success ?? rejectState.success;

  return (
    <article className="border border-border-strong bg-background-elevated/55 p-4 sm:p-5">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <span className={`inline-flex border px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] ${payment.status === "verified" ? "border-[#79d49b]/40 text-[#79d49b]" : payment.status === "rejected" ? "border-[#ff8a65]/40 text-[#ff8a65]" : "border-accent/35 text-accent"}`}>{payment.status}</span>
          <h3 className="type-display mt-3 text-2xl uppercase sm:text-3xl">{payment.teamName}</h3>
          <p className="mt-2 font-mono text-[0.58rem] uppercase tracking-[0.12em] text-foreground-muted">{payment.teamPublicId}</p>
        </div>
        <div className="sm:text-right">
          <p className="text-[0.5rem] uppercase tracking-[0.14em] text-foreground-subtle">Submitted</p>
          <p className="mt-1 text-xs text-foreground-muted">{formatTournamentDateTime(payment.submittedAt)}</p>
        </div>
      </div>
      <dl className="mt-5 grid gap-3 border-t border-border pt-4 sm:grid-cols-3">
        <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Tournament</dt><dd className="mt-1 text-sm font-semibold">{tournamentName}</dd></div>
        <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Payment amount</dt><dd className="mt-1 text-sm font-semibold">{formatMoney(payment.expectedAmountMinor, payment.currency)}</dd></div>
        <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Transaction / reference ID</dt><dd className="mt-1 break-all font-mono text-sm">{payment.referenceId}</dd></div>
      </dl>
      {payment.referenceConflict ? (
        <div
          role="alert"
          className="mt-4 border border-[#ff8a65]/45 bg-[#ff8a65]/[0.06] px-3 py-2 text-xs leading-5 text-[#ffb09a]"
        >
          Duplicate reference conflict. This normalized reference is attached
          to another pending or verified manual payment. Reject the duplicate
          attempt before verifying the genuine payment.
        </div>
      ) : null}
      {payment.status === "pending" ? (
        <div className="mt-5 border-t border-border pt-4">
          <div className="flex flex-wrap gap-2">
            <button type="button" disabled={pending || payment.referenceConflict} onClick={() => setDecision("verify")} className={`${buttonClass} border-[#79d49b]/50 text-[#79d49b]`}>{tournamentCancelled ? "Confirm Genuine" : "Verify"}</button>
            <button type="button" disabled={pending} onClick={() => setDecision("reject")} className={`${buttonClass} border-[#ff8a65]/50 text-[#ff8a65]`}>Reject</button>
          </div>
          {decision ? (
            <form action={decision === "verify" ? verifyAction : rejectAction} className="mt-3 flex flex-wrap gap-2 border border-border bg-background/60 p-3">
              <input type="hidden" name="payment_id" value={payment.id} />
              <input type="hidden" name="tournament_public_id" value={tournamentPublicId} />
              <p className="w-full text-xs text-foreground-muted">{decision === "verify" ? tournamentCancelled ? "Confirm that this preserved payment was genuine. Verification and the matching cancellation credit will be created together." : "Confirm that this payment has been checked against the receiving account." : "Reject this submission. The attempt remains in payment history."}</p>
              <button type="submit" disabled={pending} className={`${buttonClass} ${decision === "verify" ? "border-[#79d49b] bg-[#79d49b] text-background" : "border-[#ff8a65] bg-[#ff8a65] text-background"}`}>{pending ? "Updating..." : decision === "verify" ? tournamentCancelled ? "Confirm & Create Credit" : "Confirm Verification" : "Confirm Rejection"}</button>
              <button type="button" disabled={pending} onClick={() => setDecision(null)} className={`${buttonClass} border-border-strong text-foreground-muted`}>Go Back</button>
            </form>
          ) : null}
          {feedback || success ? <p role={feedback ? "alert" : "status"} className={`mt-3 text-xs ${feedback ? "text-[#ff8a65]" : "text-[#79d49b]"}`}>{feedback ?? `✓ ${success}`}</p> : null}
        </div>
      ) : null}
    </article>
  );
}

export function TournamentPaymentManagement({ credits, entryFeeMinor, payments, tournamentName, tournamentPublicId, tournamentStatus }: { credits: AdminTournamentCredit[]; entryFeeMinor: number; payments: AdminTournamentPayment[]; tournamentName: string; tournamentPublicId: string; tournamentStatus: TournamentStatus }) {
  return (
    <section id="payments" className="scroll-mt-28 pt-10">
      <div className="border-b border-border pb-5">
        <p className="text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-accent">Payment operations</p>
        <h2 className="type-display mt-3 text-3xl uppercase sm:text-4xl">Payments</h2>
        <p className="mt-3 max-w-2xl text-sm leading-6 text-foreground-muted">Review manual transaction references without collecting wallet credentials, PINs, passwords or OTPs.</p>
      </div>
      {payments.length ? (
        <div className="mt-6 grid gap-3">{payments.map((payment) => <PaymentCard key={payment.id} payment={payment} tournamentCancelled={tournamentStatus === "cancelled"} tournamentName={tournamentName} tournamentPublicId={tournamentPublicId} />)}</div>
      ) : entryFeeMinor === 0 ? (
        <div className="mt-6 border border-dashed border-border p-5 text-sm text-foreground-muted">This is a free tournament. Payment verification is not required.</div>
      ) : (
        <div className="mt-6 border border-dashed border-border p-5 text-sm text-foreground-muted">No manual payment submissions yet.</div>
      )}
      <div className="mt-8 border-t border-border pt-7">
        <p className="text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-accent">Cancellation credits</p>
        <h3 className="type-display mt-3 text-2xl uppercase sm:text-3xl">Team Credit Entitlements</h3>
        <p className="mt-3 max-w-2xl text-sm leading-6 text-foreground-muted">Permanent credit records created from verified payments when the tournament is cancelled. Credit use and cash-refund execution are not available yet.</p>
        {credits.length ? (
          <div className="mt-5 grid gap-3">
            {credits.map((credit) => (
              <article key={credit.id} className="border border-border-strong bg-background-elevated/55 p-4 sm:p-5">
                <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                  <div>
                    <span className="inline-flex border border-[#79d49b]/40 px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-[#79d49b]">{credit.status}</span>
                    <h4 className="type-display mt-3 text-2xl uppercase sm:text-3xl">{credit.teamName}</h4>
                    <p className="mt-2 font-mono text-[0.58rem] uppercase tracking-[0.12em] text-foreground-muted">{credit.teamPublicId}</p>
                  </div>
                  <div className="sm:text-right">
                    <p className="text-[0.5rem] uppercase tracking-[0.14em] text-foreground-subtle">Created</p>
                    <p className="mt-1 text-xs text-foreground-muted">{formatTournamentDateTime(credit.createdAt)}</p>
                  </div>
                </div>
                <dl className="mt-5 grid gap-3 border-t border-border pt-4 sm:grid-cols-3">
                  <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Tournament</dt><dd className="mt-1 text-sm font-semibold">{tournamentName}</dd></div>
                  <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Credit value</dt><dd className="mt-1 text-sm font-semibold text-[#79d49b]">{formatMoney(credit.amountMinor, credit.currency)}</dd></div>
                  <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Original transaction / reference</dt><dd className="mt-1 break-all font-mono text-sm">{credit.sourceReferenceId}</dd></div>
                </dl>
              </article>
            ))}
          </div>
        ) : (
          <div className="mt-5 border border-dashed border-border p-5 text-sm text-foreground-muted">No cancellation credit entitlements for this tournament.</div>
        )}
      </div>
    </section>
  );
}
