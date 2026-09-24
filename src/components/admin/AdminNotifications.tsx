"use client";

import Link from "next/link";
import { useActionState } from "react";

import { markSupportMessageRead } from "@/app/admin/actions";

export type AdminSupportMessage = {
  id: string;
  teamName: string;
  senderName: string;
  message: string;
  createdAt: string;
  readAt: string | null;
};

export type AdminPaymentFlag = {
  tournamentPublicId: string;
  tournamentName: string;
  pendingCount: number;
  conflictCount: number;
};

const initialState: { error?: string; success?: string } = {};

function SupportMessageCard({ message }: { message: AdminSupportMessage }) {
  const [state, action, pending] = useActionState(
    markSupportMessageRead,
    initialState,
  );
  const unread = message.readAt === null;

  return (
    <article
      className={`rounded-[2px] border p-4 sm:p-5 ${
        unread
          ? "border-accent/40 bg-accent/[0.05]"
          : "border-border bg-background/50"
      }`}
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[0.55rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
            Support · {message.teamName} · {message.senderName}
          </p>
          <p className="mt-2 text-sm leading-6 text-foreground">
            {message.message}
          </p>
          <p className="mt-2 text-[0.58rem] uppercase tracking-[0.14em] text-foreground-subtle">
            {new Date(message.createdAt).toLocaleString("en-PK", {
              day: "numeric",
              month: "short",
              hour: "2-digit",
              minute: "2-digit",
            })}
          </p>
        </div>
        {unread ? (
          <form action={action} className="shrink-0">
            <input type="hidden" name="message_id" value={message.id} />
            <button
              type="submit"
              disabled={pending}
              className="inline-flex min-h-9 items-center justify-center rounded-[2px] border border-accent/50 px-3 text-[0.56rem] font-semibold uppercase tracking-[0.13em] text-accent transition-colors hover:bg-accent hover:text-background disabled:pointer-events-none disabled:opacity-40"
            >
              {pending ? "Working…" : "Mark read"}
            </button>
          </form>
        ) : (
          <span className="shrink-0 text-[0.55rem] font-semibold uppercase tracking-[0.16em] text-foreground-subtle">
            Read
          </span>
        )}
      </div>
      {state.error ? (
        <p className="mt-2 text-xs text-[#ff8a65]" role="alert">
          {state.error}
        </p>
      ) : null}
    </article>
  );
}

export function AdminNotifications({
  supportMessages,
  paymentFlags,
}: {
  supportMessages: AdminSupportMessage[];
  paymentFlags: AdminPaymentFlag[];
}) {
  const unreadCount = supportMessages.filter((m) => m.readAt === null).length;
  const paymentCount = paymentFlags.reduce(
    (sum, flag) => sum + flag.pendingCount + flag.conflictCount,
    0,
  );
  const total = unreadCount + paymentCount;

  if (total === 0 && supportMessages.length === 0) {
    return (
      <section
        className="mt-10 rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7"
        aria-label="Notifications"
      >
        <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
          Notifications
        </p>
        <p className="mt-3 text-sm leading-6 text-foreground-muted">
          All clear. No payment issues and no captain messages waiting.
        </p>
      </section>
    );
  }

  return (
    <section
      className="mt-10 rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7"
      aria-label="Notifications"
    >
      <div className="flex flex-wrap items-end justify-between gap-3 border-b border-border pb-5">
        <div>
          <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
            Notifications
          </p>
          <h2 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
            Needs your attention
          </h2>
        </div>
        <p className="shrink-0 text-[0.6rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
          {total} open
        </p>
      </div>

      {paymentFlags.length > 0 ? (
        <div className="mt-6">
          <p className="text-[0.58rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
            Payment issues
          </p>
          <ul className="mt-3 grid gap-3">
            {paymentFlags.map((flag) => (
              <li
                key={flag.tournamentPublicId}
                className="flex flex-col gap-3 rounded-[2px] border border-[#ff8a65]/30 bg-[#ff8a65]/[0.04] p-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-foreground">
                    {flag.tournamentName}
                  </p>
                  <p className="mt-1 text-xs leading-5 text-foreground-muted">
                    {flag.pendingCount > 0
                      ? `${flag.pendingCount} payment${flag.pendingCount === 1 ? "" : "s"} awaiting approval`
                      : null}
                    {flag.pendingCount > 0 && flag.conflictCount > 0 ? " · " : null}
                    {flag.conflictCount > 0
                      ? `${flag.conflictCount} duplicate reference${flag.conflictCount === 1 ? "" : "s"} flagged for review`
                      : null}
                  </p>
                </div>
                <Link
                  href={`/admin/tournaments/${flag.tournamentPublicId}#payments`}
                  className="inline-flex min-h-9 shrink-0 items-center justify-center rounded-[2px] border border-[#ff8a65]/50 px-3 text-[0.56rem] font-semibold uppercase tracking-[0.13em] text-[#ff8a65] transition-colors hover:bg-[#ff8a65] hover:text-background"
                >
                  Review payments
                </Link>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      <div className="mt-6">
        <p className="text-[0.58rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
          Captain messages {unreadCount > 0 ? `· ${unreadCount} unread` : ""}
        </p>
        {supportMessages.length > 0 ? (
          <div className="mt-3 grid gap-3">
            {supportMessages.map((message) => (
              <SupportMessageCard key={message.id} message={message} />
            ))}
          </div>
        ) : (
          <p className="mt-3 text-xs leading-5 text-foreground-subtle">
            No captain messages.
          </p>
        )}
      </div>
    </section>
  );
}
