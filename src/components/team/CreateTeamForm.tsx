"use client";

import Link from "next/link";
import { useActionState } from "react";

import {
  type CreateTeamActionState,
  createTeam,
} from "@/app/team/actions";
import { Button } from "@/components/ui/Button";

type CreateTeamFormProps = {
  canCreate: boolean;
};

const initialState: CreateTeamActionState = {};
const inputClasses =
  "mt-2 h-12 w-full rounded-[2px] border border-border-strong bg-background/70 px-4 text-sm text-foreground outline-none transition-colors placeholder:text-foreground-subtle focus:border-accent focus:ring-1 focus:ring-accent/40 disabled:opacity-50";

export function CreateTeamForm({ canCreate }: CreateTeamFormProps) {
  const [state, formAction, isPending] = useActionState(
    createTeam,
    initialState,
  );

  if (!canCreate) {
    return (
      <div className="mt-5">
        <p className="text-sm leading-7 text-foreground-muted">
          Complete your Display Name and PUBG UID before creating a team.{" "}
          <Link
            href="/account"
            className="font-medium text-foreground underline decoration-border-strong underline-offset-4 transition-colors hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent"
          >
            Complete your profile
          </Link>
          .
        </p>
        <div className="mt-6">
          <Button type="button" disabled className="w-full sm:w-auto">
            Create Team
          </Button>
        </div>
      </div>
    );
  }

  return (
    <form action={formAction} className="mt-5">
      <div className="grid gap-5 sm:grid-cols-2">
        <label className="block">
          <span className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
            Team Name
          </span>
          <input
            name="name"
            type="text"
            minLength={2}
            maxLength={80}
            required
            disabled={isPending}
            className={inputClasses}
            placeholder="Enter team name"
          />
        </label>

        <label className="block">
          <span className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
            Short Name / Tag
            <span className="ml-2 text-foreground-subtle">Optional</span>
          </span>
          <input
            name="short_name"
            type="text"
            minLength={2}
            maxLength={12}
            disabled={isPending}
            className={inputClasses}
            placeholder="e.g. LVL"
          />
        </label>
      </div>

      <div
        aria-live="polite"
        aria-atomic="true"
        className="mt-5 min-h-6"
      >
        {state.error ? (
          <p className="text-sm leading-6 text-[#ff8a65]" role="alert">
            {state.error}{" "}
            {state.profileRequired ? (
              <Link
                href="/account"
                className="font-medium text-foreground underline underline-offset-4"
              >
                Open account
              </Link>
            ) : null}
          </p>
        ) : null}
      </div>

      <div>
        <Button
          type="submit"
          disabled={isPending}
          className="w-full sm:w-auto"
        >
          {isPending ? "Creating..." : "Create Team"}
        </Button>
      </div>
    </form>
  );
}
