import type { PublicLeaderboardStanding } from "@/lib/leaderboard/public";

type PublicLeaderboardProps = {
  rows: PublicLeaderboardStanding[];
  compact?: boolean;
  animateRows?: boolean;
};

export function PublicLeaderboard({
  rows,
  compact = false,
  animateRows = false,
}: PublicLeaderboardProps) {
  return (
    <div
      className={compact ? "max-h-[24rem] overflow-y-auto overscroll-contain" : ""}
      tabIndex={compact && rows.length > 6 ? 0 : undefined}
      aria-label={compact && rows.length > 6 ? "Scrollable standings" : undefined}
    >
      <ol className="divide-y divide-white/[0.07] md:hidden">
        {rows.map((standing, index) => (
          <li
            key={standing.registrationId}
            data-leaderboard-row={animateRows ? "" : undefined}
            className="grid grid-cols-[2.25rem_minmax(0,1fr)] gap-3 px-4 py-4"
          >
            <Rank rank={index + 1} />
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold uppercase tracking-[0.05em] text-white">
                {standing.teamName}
              </p>
              <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 text-[0.55rem] uppercase tracking-[0.12em] text-white/40">
                <MobileStat label="Matches" value={standing.matches} />
                <MobileStat label="WWCD" value={standing.wins} />
                <MobileStat label="Kills" value={standing.kills} />
                <MobileStat label="Placement" value={standing.placementPoints} />
                <MobileStat label="Total points" value={standing.totalPoints} emphasized />
              </dl>
            </div>
          </li>
        ))}
      </ol>

      <div className="hidden min-w-[44rem] md:block" role="table" aria-label="Official LevelledUp standings">
        <div className="grid grid-cols-[3rem_minmax(12rem,1fr)_5rem_5rem_5rem_7rem_6rem] items-center border-b border-white/10 px-4 py-3 text-[0.48rem] font-semibold uppercase tracking-[0.15em] text-white/40" role="row">
          <span role="columnheader">Rank</span>
          <span role="columnheader">Squad</span>
          <span className="text-center" role="columnheader">Matches</span>
          <span className="text-center" role="columnheader">WWCD</span>
          <span className="text-center" role="columnheader">Kills</span>
          <span className="text-center" role="columnheader">Placement pts</span>
          <span className="text-right" role="columnheader">Total</span>
        </div>
        <div role="rowgroup">
          {rows.map((standing, index) => (
            <div
              key={standing.registrationId}
              data-leaderboard-row={animateRows ? "" : undefined}
              className="grid min-h-14 grid-cols-[3rem_minmax(12rem,1fr)_5rem_5rem_5rem_7rem_6rem] items-center border-b border-white/[0.07] px-4 last:border-0"
              role="row"
            >
              <div role="cell"><Rank rank={index + 1} /></div>
              <p className="truncate text-xs font-semibold uppercase tracking-[0.07em] text-white/90" role="cell">{standing.teamName}</p>
              <Stat value={standing.matches} />
              <Stat value={standing.wins} />
              <Stat value={standing.kills} />
              <Stat value={standing.placementPoints} />
              <div className="text-right text-base font-bold text-white" role="cell">{formatStat(standing.totalPoints)}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export function LeaderboardEmptyState({ compact = false }: { compact?: boolean }) {
  return (
    <div className={`flex flex-col items-center justify-center px-5 text-center ${compact ? "py-7 lg:min-h-48 lg:py-6" : "min-h-[24rem]"}`}>
      <span className="flex h-10 w-10 items-center justify-center rounded-full border border-accent/25 bg-accent/[0.07] text-accent lg:h-12 lg:w-12">
        <TrophyIcon />
      </span>
      <h3 className="mt-4 text-sm font-bold uppercase tracking-[0.12em] text-white lg:mt-5">
        Official standings pending
      </h3>
      <p className="mt-2 max-w-md text-sm leading-5 text-white/55 lg:leading-6">
        Standings will appear after official Match results are finalized and published.
      </p>
    </div>
  );
}

function Rank({ rank }: { rank: number }) {
  return (
    <span className={`inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-bold ${rank === 1 ? "bg-[#e8bb43] text-black" : rank <= 3 ? "bg-white/75 text-black" : "border border-white/15 text-white/65"}`}>
      {rank}
    </span>
  );
}

function Stat({ value }: { value: number | null }) {
  return <div className="text-center text-xs text-white/65" role="cell">{formatStat(value)}</div>;
}

function MobileStat({ label, value, emphasized = false }: { label: string; value: number | null; emphasized?: boolean }) {
  if (value === null) return null;
  return (
    <div className={emphasized ? "col-span-2 border-t border-white/10 pt-2" : ""}>
      <dt>{label}</dt>
      <dd className={`mt-0.5 text-sm font-semibold ${emphasized ? "text-accent" : "text-white/80"}`}>{value}</dd>
    </div>
  );
}

function formatStat(value: number | null) {
  return value === null ? "—" : value.toLocaleString("en-PK");
}

function TrophyIcon() {
  return (
    <svg aria-hidden viewBox="0 0 24 24" className="h-6 w-6" fill="none">
      <path d="M8 4h8v4a4 4 0 1 1-8 0V4Zm4 8v5m-4 3h8M8 6H4v2c0 3 1.5 4 4 4m8-6h4v2c0 3-1.5 4-4 4" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}
