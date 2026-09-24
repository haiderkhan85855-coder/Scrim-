"use client";

import { useActionState } from "react";

import {
  saveRecruitmentPost,
  setRecruitmentStatus,
  type TeamMutationActionState,
} from "@/app/team/management-actions";
import { Button } from "@/components/ui/Button";

export type TeamRecruitmentPost = {
  teamId: string;
  micRequired: boolean;
  captainNote: string | null;
  status: "open" | "closed";
};

type TeamRecruitmentPanelProps = {
  teamId: string;
  isCaptain: boolean;
  post: TeamRecruitmentPost | null;
};

const initialState: TeamMutationActionState = {};

function Feedback({ state }: { state: TeamMutationActionState }) {
  return (
    <div className="mt-3 min-h-5" aria-live="polite" aria-atomic="true">
      {state.error ? (
        <p className="text-xs leading-5 text-[#ff8a65]" role="alert">
          {state.error}
        </p>
      ) : null}
      {state.success ? (
        <p className="text-xs leading-5 text-[#79d49b]" role="status">
          <span aria-hidden="true">✓ </span>
          {state.success}
        </p>
      ) : null}
    </div>
  );
}

export function TeamRecruitmentPanel({
  teamId,
  isCaptain,
  post,
}: TeamRecruitmentPanelProps) {
  const [saveState, saveAction, isSaving] = useActionState(
    saveRecruitmentPost,
    initialState,
  );
  const [statusState, statusAction, isChangingStatus] = useActionState(
    setRecruitmentStatus,
    initialState,
  );

  return (
    <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
      <div className="flex flex-col gap-4 border-b border-border pb-5 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
            Recruitment
          </p>
          <h3 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
            Find new players
          </h3>
        </div>
        <span
          className={`w-fit rounded-full border px-3 py-1 text-[0.55rem] font-semibold uppercase tracking-[0.16em] ${
            post?.status === "open"
              ? "border-accent/45 text-accent"
              : "border-border-strong text-foreground-muted"
          }`}
        >
          {post?.status === "open" ? "Open" : "Closed"}
        </span>
      </div>

      {isCaptain ? (
        <div className="mt-5">
          <form action={saveAction}>
            <input type="hidden" name="team_id" value={teamId} />
            <input
              type="hidden"
              name="post_state"
              value={post ? "existing" : "new"}
            />

            <label className="flex w-fit cursor-pointer items-center gap-3 text-sm text-foreground">
              <input
                name="mic_required"
                type="checkbox"
                defaultChecked={post?.micRequired ?? false}
                className="size-4 accent-[var(--accent)]"
              />
              Microphone required
            </label>

            <label className="mt-5 block">
              <span className="text-[0.58rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
                Captain&apos;s Note{" "}
                <span className="normal-case tracking-normal">(optional)</span>
              </span>
              <textarea
                name="captain_note"
                maxLength={500}
                rows={4}
                defaultValue={post?.captainNote ?? ""}
                placeholder="Tell prospective players what they should know."
                className="mt-2 w-full resize-y rounded-[2px] border border-border-strong bg-background/70 px-4 py-3 text-sm leading-6 text-foreground outline-none transition-colors placeholder:text-foreground-subtle focus:border-accent focus:ring-1 focus:ring-accent/40"
              />
            </label>

            <Button
              type="submit"
              disabled={isSaving}
              className="mt-5 w-full sm:w-auto"
            >
              {isSaving
                ? "Saving..."
                : post
                  ? "Save Recruitment"
                  : "Create Recruitment Post"}
            </Button>
            <Feedback state={saveState} />
          </form>

          {post ? (
            <form
              action={statusAction}
              className="mt-4 border-t border-border pt-5"
            >
              <input type="hidden" name="team_id" value={teamId} />
              <input
                type="hidden"
                name="status"
                value={post.status === "open" ? "closed" : "open"}
              />
              <Button
                type="submit"
                variant="secondary"
                disabled={isChangingStatus}
                className="w-full sm:w-auto"
              >
                {isChangingStatus
                  ? "Updating..."
                  : post.status === "open"
                    ? "Close Recruitment"
                    : "Reopen Recruitment"}
              </Button>
              <Feedback state={statusState} />
            </form>
          ) : null}
        </div>
      ) : post ? (
        <dl className="mt-5 grid gap-5 sm:grid-cols-[12rem_minmax(0,1fr)]">
          <div>
            <dt className="text-[0.55rem] font-semibold uppercase tracking-[0.15em] text-foreground-muted">
              Microphone required
            </dt>
            <dd className="mt-2 text-sm font-semibold text-foreground">
              {post.micRequired ? "Yes" : "No"}
            </dd>
          </div>
          <div>
            <dt className="text-[0.55rem] font-semibold uppercase tracking-[0.15em] text-foreground-muted">
              Captain&apos;s Note
            </dt>
            <dd className="mt-2 whitespace-pre-wrap text-sm leading-6 text-foreground">
              {post.captainNote || "No note provided."}
            </dd>
          </div>
        </dl>
      ) : (
        <p className="mt-5 text-sm leading-6 text-foreground-muted">
          This team is not currently recruiting.
        </p>
      )}
    </section>
  );
}
