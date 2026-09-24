"use client";

import { useActionState, useState } from "react";

import {
  decideLeaveRequest,
  sendSupportMessage,
  type TeamMutationActionState,
} from "@/app/team/management-actions";

export type PendingLeaveRequest = {
  id: string;
  teamId: string;
  requesterName: string;
  isOwnRequest: boolean;
  createdAt: string;
};

const initialState: TeamMutationActionState = {};

const controlButtonClasses =
  "inline-flex min-h-9 items-center justify-center rounded-[2px] border px-3 text-[0.56rem] font-semibold uppercase tracking-[0.13em] transition-colors disabled:pointer-events-none disabled:opacity-40";

function ActionFeedback({ states }: { states: TeamMutationActionState[] }) {
  const error = states.map((state) => state.error).find(Boolean);
  const success = states.map((state) => state.success).find(Boolean);
  if (!error && !success) return null;
  return (
    <p
      className={`mt-2 text-xs leading-5 ${error ? "text-[#ff8a65]" : "text-[#79d49b]"}`}
      role={error ? "alert" : "status"}
    >
      {error ?? `✓ ${success}`}
    </p>
  );
}

// 24/7 support entry point for the captain: a message straight to the admin,
// which lands in the admin notification section.
export function SupportButton({
  teamId,
  teamName,
}: {
  teamId: string;
  teamName: string;
}) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState(sendSupportMessage, initialState);

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={`${controlButtonClasses} border-accent/50 text-accent hover:bg-accent hover:text-background`}
      >
        24/7 Support
      </button>

      {open ? (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-background/70 p-4 backdrop-blur-sm"
          role="dialog"
          aria-modal="true"
          aria-label={`Contact support for ${teamName}`}
        >
          <div className="w-full max-w-md rounded-[2px] border border-border-strong bg-background-elevated p-6">
            <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
              24/7 Support
            </p>
            <h3 className="type-display mt-3 text-2xl uppercase">
              Message the admin
            </h3>
            <p className="mt-2 text-xs leading-5 text-foreground-muted">
              As captain of {teamName}, send an issue or request straight to the
              admin. It appears in their notification section.
            </p>
            <form action={action} className="mt-4 grid gap-3">
              <input type="hidden" name="team_id" value={teamId} />
              <label className="grid gap-1.5">
                <span className="text-[0.54rem] uppercase tracking-[0.14em] text-foreground-subtle">
                  Your message
                </span>
                <textarea
                  name="message"
                  rows={4}
                  maxLength={2000}
                  required
                  disabled={pending}
                  placeholder="Describe the issue…"
                  className="min-h-24 rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm text-foreground outline-none focus:border-accent disabled:opacity-50"
                />
              </label>
              <div className="flex flex-wrap gap-2">
                <button
                  type="submit"
                  disabled={pending}
                  className={`${controlButtonClasses} border-accent bg-accent text-background hover:bg-accent-hover`}
                >
                  {pending ? "Sending…" : "Send Message"}
                </button>
                <button
                  type="button"
                  onClick={() => setOpen(false)}
                  disabled={pending}
                  className={`${controlButtonClasses} border-border-strong text-foreground-muted`}
                >
                  Cancel
                </button>
              </div>
            </form>
            <ActionFeedback states={[state]} />
            {state.success ? (
              <button
                type="button"
                onClick={() => setOpen(false)}
                className={`${controlButtonClasses} mt-3 border-border-strong text-foreground-muted`}
              >
                Close
              </button>
            ) : null}
          </div>
        </div>
      ) : null}
    </>
  );
}

// Pending leave requests, visible to the captain. Approving removes the
// member (history preserved); rejecting keeps them on the Squad.
export function LeaveRequestsPanel({
  requests,
}: {
  requests: PendingLeaveRequest[];
}) {
  const [decideState, decideAction, decidePending] = useActionState(
    decideLeaveRequest,
    initialState,
  );

  if (requests.length === 0) return null;

  return (
    <section
      className="rounded-[2px] border border-accent/30 bg-accent/[0.04] p-5 sm:p-6"
      aria-label="Pending leave requests"
    >
      <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
        Leave requests
      </p>
      <h3 className="type-display mt-3 text-2xl uppercase sm:text-3xl">
        Awaiting your decision
      </h3>
      <p className="mt-2 text-xs leading-5 text-foreground-muted">
        These Squad members asked to leave. Approve to remove them (their
        history is preserved), or reject to keep them on the Squad. Only you,
        the captain, can decide.
      </p>
      <ul className="mt-4 grid gap-3">
        {requests.map((request) => (
          <li
            key={request.id}
            className="flex flex-col gap-3 rounded-[2px] border border-border bg-background/60 p-4 sm:flex-row sm:items-center sm:justify-between"
          >
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-foreground">
                {request.requesterName}
              </p>
              <p className="mt-1 text-[0.58rem] uppercase tracking-[0.14em] text-foreground-muted">
                Requested{" "}
                {new Date(request.createdAt).toLocaleDateString("en-PK", {
                  day: "numeric",
                  month: "short",
                  year: "numeric",
                })}
              </p>
            </div>
            <div className="flex shrink-0 flex-wrap gap-2">
              <form action={decideAction}>
                <input type="hidden" name="request_id" value={request.id} />
                <input type="hidden" name="decision" value="approve" />
                <button
                  type="submit"
                  disabled={decidePending}
                  className={`${controlButtonClasses} border-[#79d49b]/50 text-[#79d49b] hover:bg-[#79d49b] hover:text-background`}
                >
                  {decidePending ? "Working…" : "Approve & Remove"}
                </button>
              </form>
              <form action={decideAction}>
                <input type="hidden" name="request_id" value={request.id} />
                <input type="hidden" name="decision" value="reject" />
                <button
                  type="submit"
                  disabled={decidePending}
                  className={`${controlButtonClasses} border-border-strong text-foreground-muted hover:border-[#ff8a65]/60 hover:text-[#ff8a65]`}
                >
                  {decidePending ? "Working…" : "Reject"}
                </button>
              </form>
            </div>
          </li>
        ))}
      </ul>
      <ActionFeedback states={[decideState]} />
    </section>
  );
}
