import type { AdminTournamentSessionEntry } from "@/components/admin/types";
import { formatTournamentDateTime } from "@/lib/tournaments/dateTime";

const sourceLabels: Record<string, string> = {
  free: "Free",
  registration: "Registration entitlement",
  paid: "Paid",
  earned: "Earned",
  credit: "Credit",
  admin_grant: "Admin grant",
};

function readableSource(sourceType: string) {
  const knownLabel = sourceLabels[sourceType];
  if (knownLabel) return knownLabel;

  const normalized = sourceType.trim().replaceAll("_", " ");
  if (!normalized) return "Unknown source";
  return normalized.charAt(0).toUpperCase() + normalized.slice(1);
}

export function TournamentSessionEntryVisibility({
  entries,
}: {
  entries: AdminTournamentSessionEntry[];
}) {
  return (
    <section id="session-entries" className="scroll-mt-28 pt-10">
      <div className="border-b border-border pb-5">
        <p className="text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-accent">
          Participation records
        </p>
        <h2 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
          Session Entries
        </h2>
        <p className="mt-3 max-w-3xl text-sm leading-6 text-foreground-muted">
          Read-only participation entitlements for each exact Tournament Session.
        </p>
      </div>

      {entries.length ? (
        <div className="mt-6 grid gap-3 xl:grid-cols-2">
          {entries.map((entry) => (
            <article
              key={entry.id}
              className="min-w-0 rounded-[2px] border border-border-strong bg-background-elevated/55 p-4 sm:p-5"
            >
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap gap-2">
                    <span
                      className={`rounded-[2px] border px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] ${
                        entry.status === "active"
                          ? "border-[#79d49b]/40 text-[#79d49b]"
                          : "border-[#ff8a65]/40 text-[#ff8a65]"
                      }`}
                    >
                      {entry.status}
                    </span>
                    <span className="rounded-[2px] border border-accent/30 px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-accent">
                      {readableSource(entry.sourceType)}
                    </span>
                  </div>
                  <h3 className="type-display mt-3 break-words text-2xl uppercase leading-none">
                    {entry.teamName}
                  </h3>
                  <p className="mt-2 font-mono text-[0.58rem] uppercase tracking-[0.12em] text-foreground-muted">
                    {entry.teamPublicId}
                  </p>
                </div>
                <div className="shrink-0 sm:text-right">
                  <p className="text-[0.5rem] uppercase tracking-[0.14em] text-foreground-subtle">
                    Created
                  </p>
                  <p className="mt-1 text-xs text-foreground-muted">
                    {formatTournamentDateTime(entry.createdAt)}
                  </p>
                </div>
              </div>

              <dl className="mt-5 grid gap-px overflow-hidden rounded-[2px] border border-border bg-border sm:grid-cols-3">
                {[
                  ["Stage", entry.stageName],
                  ["Session", entry.sessionName],
                  ["Registration", entry.registrationStatus],
                ].map(([label, value]) => (
                  <div key={label} className="min-w-0 bg-background/85 p-3">
                    <dt className="text-[0.48rem] font-semibold uppercase tracking-[0.13em] text-foreground-subtle">
                      {label}
                    </dt>
                    <dd className="mt-1 break-words text-xs font-semibold capitalize text-foreground">
                      {value}
                    </dd>
                  </div>
                ))}
              </dl>

              <div className="mt-4">
                <p className="text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-foreground-subtle">
                  Reason
                </p>
                <p className="mt-2 whitespace-pre-wrap break-words text-xs leading-5 text-foreground-muted">
                  {entry.reason}
                </p>
              </div>

              {entry.status === "cancelled" ? (
                <div className="mt-4 border-t border-[#ff8a65]/20 pt-4">
                  <p className="text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-[#ff8a65]">
                    Cancellation
                  </p>
                  <p className="mt-2 text-xs text-foreground-muted">
                    {entry.cancelledAt
                      ? formatTournamentDateTime(entry.cancelledAt)
                      : "Cancellation time unavailable"}
                  </p>
                  <p className="mt-2 whitespace-pre-wrap break-words text-xs leading-5 text-foreground-muted">
                    {entry.cancellationReason ?? "Cancellation reason unavailable"}
                  </p>
                </div>
              ) : null}
            </article>
          ))}
        </div>
      ) : (
        <div className="mt-6 rounded-[2px] border border-dashed border-border p-5 text-sm text-foreground-muted">
          No Session Entries have been created yet.
        </div>
      )}
    </section>
  );
}
