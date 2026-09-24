"use client";

import { useEffect, useState } from "react";

export function CopyPubgUid({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;

    const timeout = window.setTimeout(() => setCopied(false), 1800);
    return () => window.clearTimeout(timeout);
  }, [copied]);

  async function copyUid() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }

  return (
    <span className="inline-flex max-w-full items-center gap-2">
      <span className="min-w-0 break-all font-mono text-xs text-foreground">
        {value}
      </span>
      <button
        type="button"
        onClick={copyUid}
        className="min-h-10 shrink-0 rounded-[2px] border border-border-strong px-3 py-1 text-[0.52rem] font-semibold uppercase tracking-[0.12em] text-foreground-muted transition-colors hover:border-accent hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        aria-label={`Copy PUBG UID ${value}`}
      >
        {copied ? "Copied" : "Copy"}
      </button>
      <span className="sr-only" aria-live="polite">
        {copied ? "PUBG UID copied" : ""}
      </span>
    </span>
  );
}
