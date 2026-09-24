"use client";

import Image from "next/image";
import { useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";

import { AuthForm } from "@/components/auth/AuthForm";

export type AuthModalMode = "login" | "register";

type AuthModalProps = {
  mode: AuthModalMode;
  open: boolean;
  onClose: () => void;
  onModeChange: (mode: AuthModalMode) => void;
};

const modalCopy = {
  login: {
    eyebrow: "Player access",
    title: "Enter the arena.",
    description: "Sign in to continue to your LevelledUp account.",
  },
  register: {
    eyebrow: "New contender",
    title: "Join the fight.",
    description:
      "Create your account now. Your PUBG identity and squad come later.",
  },
} as const;

export function AuthModal({
  mode,
  open,
  onClose,
  onModeChange,
}: AuthModalProps) {
  const [isPending, setIsPending] = useState(false);
  const [isClosing, setIsClosing] = useState(false);
  const dialogRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const panelId = useId();

  useEffect(() => {
    if (!open) return;

    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    const focusFrame = window.requestAnimationFrame(() => {
      dialogRef.current?.querySelector<HTMLInputElement>("input")?.focus();
    });

    return () => {
      window.cancelAnimationFrame(focusFrame);
      document.body.style.overflow = previousOverflow;
    };
  }, [open]);

  if (!open) return null;

  const copy = modalCopy[mode];

  const requestClose = () => {
    if (isPending || isClosing) return;

    const reduceMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
    if (reduceMotion) {
      onClose();
      return;
    }

    setIsClosing(true);
    window.setTimeout(() => {
      setIsClosing(false);
      onClose();
    }, 140);
  };

  const handleKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Escape") {
      if (!isPending) {
        event.preventDefault();
        event.stopPropagation();
        requestClose();
      }
      return;
    }

    if (event.key !== "Tab") return;

    const focusable = Array.from(
      dialogRef.current?.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), a[href]',
      ) ?? [],
    );
    if (!focusable.length) return;

    const first = focusable[0];
    const last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last?.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first?.focus();
    }
  };

  return createPortal(
    <div
      data-closing={isClosing}
      className="auth-modal-backdrop fixed inset-0 z-[100] flex items-start justify-center overflow-hidden bg-black/[0.86] px-4 py-4 backdrop-blur-md sm:items-center sm:px-6 sm:py-6"
      onPointerDown={(event) => {
        if (event.currentTarget === event.target) requestClose();
      }}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        onKeyDown={handleKeyDown}
        className="auth-modal-dialog relative my-auto flex max-h-[calc(100dvh-2rem)] w-full max-w-[29rem] flex-col overflow-hidden rounded-[4px] border border-white/[0.14] bg-[radial-gradient(circle_at_top_right,rgba(255,75,24,0.11),transparent_34%),linear-gradient(145deg,#0d1216_0%,#080b0e_100%)] p-4 shadow-[0_32px_90px_rgba(0,0,0,0.72),0_0_0_1px_rgba(255,75,24,0.04)] sm:max-h-[calc(100dvh-3rem)] sm:p-5"
      >
        <span
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-accent/75 to-transparent"
        />
        <span
          aria-hidden="true"
          className="pointer-events-none absolute left-0 top-14 h-16 w-px bg-gradient-to-b from-transparent via-accent/65 to-transparent"
        />

        <button
          type="button"
          aria-label="Close account dialog"
          disabled={isPending || isClosing}
          onClick={requestClose}
          className="absolute right-2 top-2 flex h-10 w-10 items-center justify-center text-xl leading-none text-white/50 transition-[color,transform] duration-200 hover:rotate-3 hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-4px] focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-35 sm:right-2.5 sm:top-2.5"
        >
          <span aria-hidden="true">×</span>
        </button>

        <div className="flex items-start gap-3.5 pr-11 sm:gap-4">
          <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-[3px] border border-accent/25 bg-accent/[0.06] shadow-[inset_0_0_18px_rgba(255,75,24,0.06)] sm:h-11 sm:w-11">
            <Image
              src="/images/brand/levelledup-crest.png"
              alt=""
              width={1254}
              height={1254}
              sizes="44px"
              className="h-8 w-8 object-contain sm:h-9 sm:w-9"
            />
          </span>
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2.5 text-[0.56rem] font-semibold uppercase tracking-[0.24em] text-accent">
              <span className="h-px w-5 bg-accent/80" aria-hidden="true" />
              {copy.eyebrow}
            </div>
            <h2
              id={titleId}
              className="type-display mt-2.5 text-[clamp(1.7rem,7vw,2.45rem)] uppercase leading-[0.94] tracking-[-0.035em]"
            >
              {copy.title}
            </h2>
          </div>
        </div>
        <p className="mt-3 text-[0.82rem] leading-5 text-foreground-muted sm:text-sm">
          {copy.description}
        </p>

        <div
          role="tablist"
          aria-label="Account access"
          className="mt-4 grid shrink-0 grid-cols-2 gap-1 rounded-[3px] border border-white/[0.09] bg-black/30 p-1"
        >
          {(["login", "register"] as const).map((tabMode) => {
            const selected = mode === tabMode;
            return (
              <button
                key={tabMode}
                type="button"
                role="tab"
                aria-selected={selected}
                aria-controls={panelId}
                disabled={isPending}
                onClick={() => onModeChange(tabMode)}
                className={`relative min-h-10 rounded-[2px] px-2 text-[0.6rem] font-semibold uppercase tracking-[0.17em] transition-[background-color,color,box-shadow] duration-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-accent disabled:opacity-50 ${selected ? "bg-accent/[0.13] text-accent shadow-[inset_0_0_0_1px_rgba(255,75,24,0.18)]" : "text-white/42 hover:bg-white/[0.035] hover:text-white/80"}`}
              >
                {tabMode === "login" ? "Login" : "Create account"}
                <span
                  aria-hidden="true"
                  className={`absolute inset-x-3 bottom-0 h-px bg-accent shadow-[0_0_8px_rgba(255,75,24,0.55)] transition-opacity ${selected ? "opacity-100" : "opacity-0"}`}
                />
              </button>
            );
          })}
        </div>

        <div
          id={panelId}
          role="tabpanel"
          className="auth-modal-panel min-h-0"
        >
          <AuthForm
            key={mode}
            mode={mode}
            compact
            onModeChange={onModeChange}
            onPendingChange={setIsPending}
          />
        </div>
      </div>
    </div>,
    document.body,
  );
}
