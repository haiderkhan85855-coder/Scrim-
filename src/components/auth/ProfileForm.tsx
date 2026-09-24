"use client";

import { useRouter } from "next/navigation";
import { useActionState, useEffect } from "react";

import {
  type ProfileActionState,
  updateProfile,
} from "@/app/account/actions";
import { Button } from "@/components/ui/Button";

type ProfileFormProps = {
  profile: {
    display_name: string | null;
    pubg_ign: string | null;
    pubg_uid: string | null;
  };
};

const initialState: ProfileActionState = {};
const inputClasses =
  "mt-2 h-12 w-full rounded-[2px] border border-border-strong bg-background/70 px-4 text-sm text-foreground outline-none transition-colors placeholder:text-foreground-subtle focus:border-accent focus:ring-1 focus:ring-accent/40 disabled:opacity-50";

export function ProfileForm({ profile }: ProfileFormProps) {
  const router = useRouter();
  const [state, formAction, isPending] = useActionState(
    updateProfile,
    initialState,
  );
  const isSaved = Boolean(state.redirectTo);

  useEffect(() => {
    const redirectTo = state.redirectTo;
    if (!redirectTo) return;

    const redirectTimeout = window.setTimeout(() => {
      router.replace(redirectTo);
    }, 900);

    return () => window.clearTimeout(redirectTimeout);
  }, [router, state.redirectTo]);

  return (
    <form action={formAction} className="mt-7">
      <div className="grid gap-5 sm:grid-cols-2">
        <label className="block">
          <span className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
            Display name
          </span>
          <input
            name="display_name"
            type="text"
            autoComplete="name"
            maxLength={80}
            defaultValue={profile.display_name ?? ""}
            disabled={isPending}
            className={inputClasses}
            placeholder="Not set"
          />
        </label>

        <label className="block">
          <span className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
            PUBG IGN
            <span className="ml-2 text-foreground-subtle">Optional</span>
          </span>
          <input
            name="pubg_ign"
            type="text"
            maxLength={32}
            defaultValue={profile.pubg_ign ?? ""}
            disabled={isPending}
            className={inputClasses}
            placeholder="Not set"
          />
        </label>

        <label className="block">
          <span className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
            PUBG UID
          </span>
          <input
            name="pubg_uid"
            type="text"
            inputMode="numeric"
            maxLength={32}
            required
            defaultValue={profile.pubg_uid ?? ""}
            disabled={isPending}
            className={inputClasses}
            placeholder="Not set"
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
            {state.error}
          </p>
        ) : null}
        {state.message ? (
          <p
            className="flex items-center gap-2 text-sm leading-6 text-emerald-400"
            role="status"
          >
            <span
              className="flex size-5 items-center justify-center rounded-full border border-emerald-400/60 text-[0.7rem]"
              aria-hidden="true"
            >
              ✓
            </span>
            {state.message}
          </p>
        ) : null}
      </div>

      <div className="flex flex-col gap-3 sm:flex-row">
        <Button
          type="submit"
          disabled={isPending || isSaved}
          className="w-full sm:w-auto"
        >
          {isPending ? "Saving..." : isSaved ? "Profile saved" : "Save profile"}
        </Button>
        <Button
          href="/"
          variant="secondary"
          className="w-full sm:w-auto"
        >
          Return home
        </Button>
      </div>
    </form>
  );
}
