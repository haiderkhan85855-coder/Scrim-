"use client";

import { useActionState } from "react";

import {
  type JoinTeamActionState,
  type LookupTeamActionState,
  type SearchTeamsActionState,
  lookupTeam,
  requestTeamJoin,
  searchTeamsByName,
} from "@/app/team/actions";
import { Button } from "@/components/ui/Button";

type TeamLookupProps = {
  teamLimitReached?: boolean;
};

const initialLookupState: LookupTeamActionState = {};
const initialJoinState: JoinTeamActionState = {};
const initialSearchState: SearchTeamsActionState = {};
const inputClasses =
  "mt-2 h-12 w-full rounded-[2px] border border-border-strong bg-background/70 px-4 font-[family-name:var(--font-display)] text-sm uppercase tracking-[0.12em] text-foreground outline-none transition-colors placeholder:font-[family-name:var(--font-sans)] placeholder:tracking-normal placeholder:text-foreground-subtle focus:border-accent focus:ring-1 focus:ring-accent/40 disabled:opacity-50";

export function TeamLookup({ teamLimitReached = false }: TeamLookupProps) {
  const [lookupState, lookupAction, isLookupPending] = useActionState(
    lookupTeam,
    initialLookupState,
  );
  const [joinState, joinAction, isJoinPending] = useActionState(
    requestTeamJoin,
    initialJoinState,
  );
  const [searchState, searchAction, isSearchPending] = useActionState(
    searchTeamsByName,
    initialSearchState,
  );

  if (lookupState.status === "found") {
    return (
      <div className="mt-5">
        {joinState.success ? (
          <p
            className="flex min-h-12 items-center gap-2 text-sm font-medium text-[#79d49b]"
            role="status"
          >
            <span aria-hidden="true">✓</span>
            Join request sent
          </p>
        ) : (
          <form action={joinAction}>
            <input type="hidden" name="team_id" value={lookupState.teamId} />
            <Button
              type="submit"
              disabled={isJoinPending || teamLimitReached}
              className="w-full sm:w-auto"
            >
              {isJoinPending ? "Sending..." : "Join Team"}
            </Button>

            <div
              aria-live="polite"
              aria-atomic="true"
              className="mt-3 min-h-5"
            >
              {teamLimitReached ? (
                <p className="text-sm leading-6 text-foreground-muted">
                  Maximum of 3 teams reached.
                </p>
              ) : null}
              {joinState.error ? (
                <p className="text-sm leading-6 text-[#ff8a65]" role="alert">
                  {joinState.error}
                </p>
              ) : null}
            </div>
          </form>
        )}
      </div>
    );
  }

  return (
    <>
    <form action={lookupAction} className="mt-5">
      <label className="block max-w-sm">
        <span className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
          LevelledUp Team ID
        </span>
        <input
          name="team_id"
          type="text"
          maxLength={9}
          required
          autoCapitalize="characters"
          autoComplete="off"
          spellCheck={false}
          disabled={isLookupPending}
          className={inputClasses}
          placeholder="LU-XXXXXX"
        />
      </label>

      <div aria-live="polite" aria-atomic="true" className="mt-3 min-h-5">
        {lookupState.error ? (
          <p className="text-sm leading-6 text-[#ff8a65]" role="alert">
            {lookupState.error}
          </p>
        ) : null}
      </div>

      <Button
        type="submit"
        variant="secondary"
        disabled={isLookupPending}
        className="w-full sm:w-auto"
      >
        {isLookupPending ? "Checking..." : "Find Team"}
      </Button>
    </form>

    <div className="mt-8 border-t border-border pt-6">
      <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
        Search by team name
      </p>
      <p className="mt-2 text-xs text-foreground-subtle">
        Matches current and former team names.
      </p>
      <form action={searchAction} className="mt-4">
        <label className="block max-w-sm">
          <span className="sr-only">Team name</span>
          <input
            name="name_query"
            type="text"
            minLength={2}
            maxLength={80}
            required
            autoComplete="off"
            spellCheck={false}
            disabled={isSearchPending}
            className={inputClasses}
            placeholder="e.g. Eagle Warriors"
          />
        </label>
        <div aria-live="polite" aria-atomic="true" className="mt-3 min-h-5">
          {searchState.error ? (
            <p className="text-sm leading-6 text-[#ff8a65]" role="alert">
              {searchState.error}
            </p>
          ) : null}
        </div>
        <Button
          type="submit"
          variant="secondary"
          disabled={isSearchPending}
          className="w-full sm:w-auto"
        >
          {isSearchPending ? "Searching..." : "Search Names"}
        </Button>
      </form>

      {searchState.searched ? (
        <div className="mt-5">
          {(searchState.results ?? []).length === 0 ? (
            <p className="text-sm text-foreground-muted">
              No teams match that name.
            </p>
          ) : (
            <ul className="space-y-2">
              {(searchState.results ?? []).map((result) => (
                <li
                  key={result.teamId}
                  className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-3"
                >
                  <p className="text-sm font-semibold text-foreground">
                    {result.name}
                    {result.formerName ? (
                      <span className="ml-2 text-xs font-normal text-foreground-muted">
                        formerly {result.formerName}
                      </span>
                    ) : null}
                  </p>
                  <p className="mt-1 font-mono text-[0.65rem] text-foreground-subtle">
                    {result.teamCode}
                    {result.matchedName !== result.name ? (
                      <span className="ml-2">
                        matched “{result.matchedName}”
                      </span>
                    ) : null}
                  </p>
                </li>
              ))}
            </ul>
          )}
        </div>
      ) : null}
    </div>
    </>
  );
}
