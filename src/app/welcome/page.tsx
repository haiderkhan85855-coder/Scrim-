import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { Button } from "@/components/ui/Button";
import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "Welcome | LEVELLEDUP",
};

export default async function WelcomePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  return (
    <>
      <AuthenticatedHeader />
      <main className="flex min-h-svh items-center justify-center px-5 pb-12 pt-[calc(var(--header-height)+3rem)] sm:px-8">
      <section className="relative w-full max-w-2xl overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated/90 p-7 sm:p-10">
        <span
          className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-accent via-accent/35 to-transparent"
          aria-hidden="true"
        />
        <p className="type-eyebrow text-accent">Account confirmed</p>
        <h1 className="type-display mt-5 text-[clamp(2.6rem,9vw,5rem)] uppercase">
          Welcome to LevelledUp.
        </h1>
        <p className="mt-5 max-w-lg text-sm leading-7 text-foreground-muted">
          Your account is ready. You can now return to the arena and explore
          what&apos;s happening next.
        </p>

        <div className="mt-9 flex flex-col gap-3 sm:flex-row">
          <Button href="/" className="w-full sm:w-auto">
            Enter LevelledUp
          </Button>
          <Button
            href="/account"
            variant="secondary"
            className="w-full sm:w-auto"
          >
            View account
          </Button>
        </div>
      </section>
      </main>
    </>
  );
}
