"use client";

import { useState } from "react";

import { RecruitmentRequestButton } from "@/components/team/RecruitmentRequestButton";
import { TeamLookup } from "@/components/team/TeamLookup";
import { Button } from "@/components/ui/Button";

export type RecruitmentListing = {
  teamName: string;
  teamPublicId: string;
  micRequired: boolean;
  captainNote: string | null;
};

type FindTeamExperienceProps = {
  listings: RecruitmentListing[];
  teamLimitReached: boolean;
};

type FindTeamView = "search" | "recruitment";

export function FindTeamExperience({
  listings,
  teamLimitReached,
}: FindTeamExperienceProps) {
  const [view, setView] = useState<FindTeamView>("search");

  return (
    <section className="relative overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated/65">
      <span
        className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-accent via-accent/30 to-transparent"
        aria-hidden="true"
      />

      <header className="p-5 pb-0 sm:p-8 sm:pb-0">
        <div className="flex flex-col gap-6 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h1 className="type-display text-[clamp(3rem,8vw,6.25rem)] uppercase leading-[0.88]">
              Find a team
            </h1>
          </div>
          <Button href="/team" variant="secondary" className="w-full sm:w-auto">
            My Teams
          </Button>
        </div>

        <div
          className="mt-8 flex gap-2 border-b border-border"
          role="tablist"
          aria-label="Find a team options"
        >
          {([
            ["search", "Search Team"],
            ["recruitment", "Recruitment"],
          ] as const).map(([value, label]) => (
            <button
              key={value}
              type="button"
              role="tab"
              id={`find-team-${value}-tab`}
              aria-controls={`find-team-${value}-panel`}
              aria-selected={view === value}
              onClick={() => setView(value)}
              className={`relative min-h-11 px-3 text-[0.6rem] font-semibold uppercase tracking-[0.17em] transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent sm:px-5 ${
                view === value
                  ? "text-accent after:absolute after:inset-x-0 after:bottom-[-1px] after:h-px after:bg-accent"
                  : "text-foreground-muted hover:text-foreground"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        <p className="max-w-2xl py-5 text-sm leading-7 text-foreground-muted sm:py-6">
          Search directly if you already know a team&apos;s LevelledUp ID, or
          browse teams currently looking for players.
        </p>
      </header>

      <div className="border-t border-border bg-background/25 p-5 sm:p-8">
        {view === "search" ? (
          <div
            id="find-team-search-panel"
            role="tabpanel"
            aria-labelledby="find-team-search-tab"
            className="max-w-xl"
          >
            <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
              Search team
            </p>
            <TeamLookup teamLimitReached={teamLimitReached} />
          </div>
        ) : (
          <div
            id="find-team-recruitment-panel"
            role="tabpanel"
            aria-labelledby="find-team-recruitment-tab"
          >
            <div className="flex items-end justify-between gap-4">
              <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
                Recruitment
              </p>
              <p className="text-[0.56rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
                {listings.length} open
              </p>
            </div>

            {teamLimitReached ? (
              <p className="mt-5 rounded-[2px] border border-border bg-background-elevated/65 p-4 text-sm leading-6 text-foreground-muted">
                You can browse recruitment, but requesting another team is
                disabled because you already have the maximum of 3 active teams.
              </p>
            ) : null}

            {listings.length > 0 ? (
              <div className="mt-5 grid gap-4 lg:grid-cols-2">
                {listings.map((listing, index) => (
                  <article
                    key={listing.teamPublicId}
                    className="rounded-[2px] border border-border bg-background-elevated/70 p-5 transition-colors hover:border-border-strong sm:p-6"
                  >
                    <div className="flex items-start justify-between gap-4">
                      <div className="min-w-0">
                        <h2 className="type-display break-words text-3xl uppercase sm:text-4xl">
                          {listing.teamName}
                        </h2>
                        <p className="mt-3 font-[family-name:var(--font-display)] text-sm tracking-[0.08em] text-accent">
                          {listing.teamPublicId}
                        </p>
                      </div>
                      <span className="shrink-0 text-[0.55rem] font-semibold tracking-[0.16em] text-foreground-subtle">
                        {String(index + 1).padStart(2, "0")}
                      </span>
                    </div>

                    <p className="mt-5 border-y border-border py-4 text-xs font-semibold uppercase tracking-[0.13em] text-foreground">
                      Microphone: {listing.micRequired ? "Required" : "Not required"}
                    </p>

                    {listing.captainNote ? (
                      <div className="mt-5">
                        <p className="text-[0.54rem] font-semibold uppercase tracking-[0.15em] text-foreground-muted">
                          Captain&apos;s Note
                        </p>
                        <p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-foreground">
                          {listing.captainNote}
                        </p>
                      </div>
                    ) : null}

                    <div className="mt-6">
                      <RecruitmentRequestButton
                        teamId={listing.teamPublicId}
                        teamLimitReached={teamLimitReached}
                      />
                    </div>
                  </article>
                ))}
              </div>
            ) : (
              <div className="mt-5 rounded-[2px] border border-border bg-background-elevated/55 p-6">
                <h2 className="type-display text-3xl uppercase">
                  Recruitment is quiet.
                </h2>
                <p className="mt-3 max-w-lg text-sm leading-7 text-foreground-muted">
                  No active teams have opened recruitment yet. Check back as
                  new squads enter the board.
                </p>
              </div>
            )}
          </div>
        )}
      </div>
    </section>
  );
}
