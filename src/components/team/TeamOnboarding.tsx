"use client";

import { useState } from "react";

import { CreateTeamForm } from "@/components/team/CreateTeamForm";
import { TeamLookup } from "@/components/team/TeamLookup";
import { Button } from "@/components/ui/Button";

type TeamOnboardingProps = {
  canCreate: boolean;
  additional?: boolean;
  teamLimitReached?: boolean;
};

export function TeamOnboarding({
  canCreate,
  additional = false,
  teamLimitReached = false,
}: TeamOnboardingProps) {
  const [createOpen, setCreateOpen] = useState(false);

  if (teamLimitReached) {
    return (
      <div className="mt-5 border-t border-border pt-5">
        <p className="text-sm font-medium text-foreground">
          Maximum of 3 teams reached
        </p>
        <p className="mt-2 text-sm leading-6 text-foreground-muted">
          Leave an existing Player or Substitute membership before joining or
          creating another team.
        </p>
        <div className="mt-5 flex flex-col gap-3 sm:flex-row">
          <Button type="button" variant="secondary" disabled>
            Join Another Team
          </Button>
          <Button type="button" disabled>
            Create Another Team
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className={`${additional ? "mt-5" : "mt-8 border-t border-border pt-7"}`}>
      <div className={additional ? "grid gap-4 md:grid-cols-2" : ""}>
        <section className={additional ? "rounded-[2px] border border-border bg-background/35 p-5" : ""}>
        <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
          {additional ? "Join another team" : "Join existing team"}
        </p>
          <TeamLookup />
        </section>

        {!additional ? (
          <div className="my-8 flex items-center gap-4" aria-hidden="true">
            <span className="h-px flex-1 bg-border" />
            <span className="text-[0.58rem] font-semibold uppercase tracking-[0.2em] text-foreground-subtle">
              Or
            </span>
            <span className="h-px flex-1 bg-border" />
          </div>
        ) : null}

        <section className={additional ? "rounded-[2px] border border-border bg-background/35 p-5" : ""}>
          <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
            {additional ? "Create another team" : "Create team"}
          </p>

          {createOpen ? (
            <CreateTeamForm canCreate={canCreate} />
          ) : (
            <Button
              type="button"
              onClick={() => setCreateOpen(true)}
              className="mt-5 w-full sm:w-auto"
            >
              {additional ? "Create Another Team" : "Create Team"}
            </Button>
          )}
        </section>
      </div>
    </div>
  );
}
