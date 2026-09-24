"use client";

import Link from "next/link";
import { useActionState, useEffect } from "react";

import {
  type AuthActionState,
  login,
  register,
} from "@/app/auth/actions";
import { Button } from "@/components/ui/Button";

type AuthFormProps = {
  mode: "login" | "register";
  initialError?: string;
  nextPath?: string;
  compact?: boolean;
  onModeChange?: (mode: "login" | "register") => void;
  onPendingChange?: (pending: boolean) => void;
};

export function AuthForm({
  mode,
  initialError,
  nextPath,
  compact = false,
  onModeChange,
  onPendingChange,
}: AuthFormProps) {
  const isRegister = mode === "register";
  const action = isRegister ? register : login;
  const initialState: AuthActionState = { error: initialError };
  const [state, formAction, isPending] = useActionState(action, initialState);
  const inputClassName = compact
    ? "h-11 w-full rounded-[3px] border border-white/[0.11] bg-black/30 px-4 text-[0.9rem] text-foreground shadow-[inset_0_1px_0_rgba(255,255,255,0.025)] outline-none transition-[border-color,background-color,box-shadow] placeholder:text-white/25 focus:border-accent/70 focus:bg-black/45 focus:ring-2 focus:ring-accent/10 disabled:opacity-50"
    : "h-13 w-full rounded-[2px] border border-border-strong bg-background/70 px-4 text-sm text-foreground outline-none transition-colors placeholder:text-foreground-subtle focus:border-accent focus:ring-1 focus:ring-accent/40 disabled:opacity-50";

  useEffect(() => {
    onPendingChange?.(isPending);

    return () => onPendingChange?.(false);
  }, [isPending, onPendingChange]);

  return (
    <form
      action={formAction}
      className={compact ? "mt-3.5 space-y-3 pb-0.5" : "mt-9 space-y-5"}
    >
      {!isRegister && nextPath ? (
        <input type="hidden" name="next" value={nextPath} />
      ) : null}
      <label className="block">
        <span className={`${compact ? "mb-1.5 text-[0.58rem] tracking-[0.2em] text-white/48" : "mb-2 text-[0.65rem] tracking-[0.18em] text-foreground-muted"} block font-medium uppercase`}>
          Email
        </span>
        <input
          name="email"
          type="email"
          autoFocus={compact}
          autoComplete="email"
          required
          disabled={isPending}
          className={inputClassName}
          placeholder="Enter your email"
        />
      </label>

      <label className="block">
        <span className={`${compact ? "mb-1.5 text-[0.58rem] tracking-[0.2em] text-white/48" : "mb-2 text-[0.65rem] tracking-[0.18em] text-foreground-muted"} block font-medium uppercase`}>
          Password
        </span>
        <input
          name="password"
          type="password"
          autoComplete={isRegister ? "new-password" : "current-password"}
          minLength={isRegister ? 8 : undefined}
          required
          disabled={isPending}
          className={inputClassName}
          placeholder={isRegister ? "At least 8 characters" : "Enter your password"}
        />
      </label>

      {isRegister ? (
        <label className="block">
          <span className={`${compact ? "mb-1.5 text-[0.58rem] tracking-[0.2em] text-white/48" : "mb-2 text-[0.65rem] tracking-[0.18em] text-foreground-muted"} block font-medium uppercase`}>
            Confirm password
          </span>
          <input
            name="confirmPassword"
            type="password"
            autoComplete="new-password"
            minLength={8}
            required
            disabled={isPending}
            className={inputClassName}
            placeholder="Repeat your password"
          />
        </label>
      ) : null}

      <div
        aria-live="polite"
        aria-atomic="true"
        className={`${compact ? "min-h-5" : "min-h-6"} ${compact && state.error ? "rounded-[2px] border border-[#ff8a65]/20 bg-[#ff8a65]/[0.055] px-3 py-2" : ""} ${compact && state.message ? "rounded-[2px] border border-accent/15 bg-accent/[0.045] px-3 py-2" : ""}`}
      >
        {state.error ? (
          <p className="text-sm leading-6 text-[#ff8a65]" role="alert">
            {state.error}
          </p>
        ) : null}
        {state.message ? (
          <p className="text-sm leading-6 text-foreground-muted" role="status">
            {state.message}
          </p>
        ) : null}
      </div>

      <Button
        type="submit"
        className={compact ? "min-h-11 w-full shadow-[0_12px_28px_rgba(255,75,24,0.16)]" : "w-full"}
        disabled={isPending}
      >
        {isPending
          ? "Please wait..."
          : isRegister
            ? "Create account"
            : "Sign in"}
      </Button>

      <p className={`${compact ? "text-[0.78rem]" : "text-sm"} text-center text-foreground-muted`}>
        {isRegister ? "Already registered?" : "New to LevelledUp?"}{" "}
        {onModeChange ? (
          <button
            type="button"
            disabled={isPending}
            onClick={() => onModeChange(isRegister ? "login" : "register")}
            className="font-medium text-foreground underline decoration-border-strong underline-offset-4 transition-colors hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent disabled:opacity-50"
          >
            {isRegister ? "Sign in" : "Create an account"}
          </button>
        ) : (
          <Link
            href={isRegister ? "/login" : "/register"}
            className="font-medium text-foreground underline decoration-border-strong underline-offset-4 transition-colors hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent"
          >
            {isRegister ? "Sign in" : "Create an account"}
          </Link>
        )}
      </p>
    </form>
  );
}
