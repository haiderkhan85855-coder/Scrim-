import Link from "next/link";
import type { ReactNode } from "react";

type AuthShellProps = {
  eyebrow: string;
  title: string;
  description: string;
  children: ReactNode;
};

export function AuthShell({
  eyebrow,
  title,
  description,
  children,
}: AuthShellProps) {
  return (
    <main className="flex min-h-svh items-center justify-center px-5 py-12 sm:px-8">
      <div className="w-full max-w-md">
        <Link
          href="/"
          className="inline-flex items-center gap-3 font-[family-name:var(--font-display)] text-xs font-bold uppercase tracking-[0.16em] text-foreground transition-colors hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent"
          aria-label="LevelledUp home"
        >
          <span className="h-2 w-2 bg-accent" aria-hidden="true" />
          LevelledUp
        </Link>

        <section className="relative mt-7 overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated/90 p-6 shadow-2xl shadow-black/30 sm:p-9">
          <span
            className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-accent via-accent/35 to-transparent"
            aria-hidden="true"
          />
          <div className="flex items-center gap-3 text-[0.625rem] font-medium uppercase tracking-[0.22em] text-accent">
            <span className="h-px w-8 bg-accent" aria-hidden="true" />
            {eyebrow}
          </div>
          <h1 className="type-display mt-5 text-[clamp(2.35rem,11vw,3.6rem)] uppercase">
            {title}
          </h1>
          <p className="mt-4 max-w-sm text-sm leading-6 text-foreground-muted">
            {description}
          </p>

          {children}
        </section>
      </div>
    </main>
  );
}
