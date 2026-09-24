"use client";

import { useEffect, useState } from "react";

type AuthToastProps = {
  message: string;
  queryParameter: string;
  tone?: "accent" | "success";
};

export function AuthToast({
  message,
  queryParameter,
  tone = "accent",
}: AuthToastProps) {
  const [mounted, setMounted] = useState(true);
  const [visible, setVisible] = useState(true);

  useEffect(() => {
    const url = new URL(window.location.href);
    url.searchParams.delete(queryParameter);
    window.history.replaceState(
      null,
      "",
      `${url.pathname}${url.search}${url.hash}`,
    );

    const fadeTimeout = window.setTimeout(() => setVisible(false), 4000);
    const removeTimeout = window.setTimeout(() => setMounted(false), 4300);

    return () => {
      window.clearTimeout(fadeTimeout);
      window.clearTimeout(removeTimeout);
    };
  }, [queryParameter]);

  if (!mounted) {
    return null;
  }

  return (
    <div
      role="status"
      aria-live="polite"
      className={`pointer-events-none fixed inset-x-4 bottom-5 z-[70] flex justify-center transition-[opacity,transform] duration-300 motion-reduce:transition-none sm:bottom-7 ${
        visible ? "translate-y-0 opacity-100" : "translate-y-2 opacity-0"
      }`}
    >
      <div className="flex items-center gap-3 rounded-[2px] border border-border-strong bg-background-elevated/95 px-4 py-3 text-sm text-foreground shadow-2xl backdrop-blur-md">
        {tone === "success" ? (
          <span
            className="flex size-5 items-center justify-center rounded-full border border-emerald-400/60 text-[0.7rem] text-emerald-400"
            aria-hidden="true"
          >
            ✓
          </span>
        ) : (
          <span className="size-1.5 bg-accent" aria-hidden="true" />
        )}
        {message}
      </div>
    </div>
  );
}
