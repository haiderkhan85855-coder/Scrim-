"use client";

import { useActionState } from "react";

import {
  type JoinTeamActionState,
  requestTeamJoin,
} from "@/app/team/actions";
import { Button } from "@/components/ui/Button";

type RecruitmentRequestButtonProps = {
  teamId: string;
  teamLimitReached: boolean;
};

const initialState: JoinTeamActionState = {};

export function RecruitmentRequestButton({
  teamId,
  teamLimitReached,
}: RecruitmentRequestButtonProps) {
  const [state, action, isPending] = useActionState(
    requestTeamJoin,
    initialState,
  );

  if (state.success) {
    return (
      <p className="flex min-h-12 items-center gap-2 text-sm font-medium text-[#79d49b]" role="status">
        <span aria-hidden="true">✓</span>
        Join request sent
      </p>
    );
  }

  return (
    <form action={action}>
      <input type="hidden" name="team_id" value={teamId} />
      <Button
        type="submit"
        disabled={isPending || teamLimitReached}
        className="w-full sm:w-auto"
      >
        {isPending ? "Sending..." : "Request to Join"}
      </Button>
      <div className="mt-3 min-h-5" aria-live="polite" aria-atomic="true">
        {teamLimitReached ? (
          <p className="text-xs leading-5 text-foreground-muted">
            Maximum of 3 teams reached.
          </p>
        ) : null}
        {state.error ? (
          <p className="text-xs leading-5 text-[#ff8a65]" role="alert">
            {state.error}
          </p>
        ) : null}
      </div>
    </form>
  );
}
