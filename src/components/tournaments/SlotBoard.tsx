export type SlotBoardRow = {
  tournamentName: string;
  tournamentCode: string;
  stageId: string;
  stageName: string;
  tierLabel: string | null;
  stageNumber: number;
  lobbyId: string;
  lobbyLabel: string;
  lobbyCode: string;
  lobbyOrder: number;
  lobbyCapacity: number;
  slotNumber: number;
  assignmentId: string | null;
  registrationId: string | null;
  teamName: string | null;
  teamCode: string | null;
  teamStatus: "active" | "disbanded" | null;
};

function groupRows(rows: SlotBoardRow[]) {
  const groups = new Map<string, SlotBoardRow[]>();
  for (const row of rows) {
    const key = `${row.stageId}:${row.lobbyId}`;
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return [...groups.values()];
}

export function SlotBoard({
  rows,
  compact = false,
  highlightedRegistrationId = null,
}: {
  rows: SlotBoardRow[];
  compact?: boolean;
  highlightedRegistrationId?: string | null;
}) {
  if (!rows.length) {
    return (
      <div className="rounded-[2px] border border-dashed border-border p-5 text-sm text-foreground-muted">
        Competition lobbies have not been configured yet.
      </div>
    );
  }

  return (
    <div className="grid gap-5">
      {groupRows(rows).map((lobbyRows) => {
        const first = lobbyRows[0];
        return (
          <section
            key={`${first.stageNumber}:${first.lobbyOrder}`}
            className="overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated/55"
          >
            <header className="flex flex-col gap-3 border-b border-border p-4 sm:flex-row sm:items-end sm:justify-between sm:p-5">
              <div>
                <p className="text-[0.52rem] font-semibold uppercase tracking-[0.16em] text-accent">
                  {first.stageName}
                  {first.tierLabel ? ` / ${first.tierLabel}` : ""}
                </p>
                <h3 className="type-display mt-2 text-2xl uppercase sm:text-3xl">
                  {first.lobbyLabel}
                </h3>
              </div>
              {!compact ? (
                <p className="font-mono text-[0.55rem] uppercase tracking-[0.12em] text-foreground-muted">
                  {first.tournamentName} · {first.tournamentCode}
                </p>
              ) : null}
            </header>
            <div className={`grid gap-px bg-border ${compact ? "sm:grid-cols-2" : "sm:grid-cols-2 xl:grid-cols-4"}`}>
              {lobbyRows.map((slot) => (
                <div
                  key={slot.slotNumber}
                  className={`flex min-h-16 items-center gap-3 bg-background px-4 py-3 ${
                    slot.registrationId === highlightedRegistrationId && highlightedRegistrationId
                      ? "shadow-[inset_3px_0_0_var(--accent)] bg-accent/[0.06]"
                      : ""
                  }`}
                >
                  <span className="w-7 shrink-0 font-mono text-xs font-semibold text-accent">
                    {String(slot.slotNumber).padStart(2, "0")}
                  </span>
                  <div className="min-w-0 flex-1">
                    <p className={`truncate text-xs font-semibold uppercase ${slot.teamName ? "text-foreground" : "text-foreground-subtle"}`}>
                      {slot.teamName ?? "Open"}
                    </p>
                    {slot.teamCode ? (
                      <p className="mt-1 font-mono text-[0.5rem] uppercase tracking-[0.11em] text-foreground-muted">
                        {slot.teamCode}
                        {slot.registrationId === highlightedRegistrationId && highlightedRegistrationId
                          ? " · Your Team"
                          : ""}
                      </p>
                    ) : null}
                    {slot.teamStatus === "disbanded" ? (
                      <p className="mt-1 text-[0.5rem] font-semibold uppercase tracking-[0.12em] text-[#ff8a65]">
                        Disbanded
                      </p>
                    ) : null}
                  </div>
                </div>
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}
