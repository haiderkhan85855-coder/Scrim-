import type { Metadata } from "next";
import Link from "next/link";

import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import { Container } from "@/components/layout/Container";
import { Footer } from "@/components/layout/Footer";
import {
  LeaderboardEmptyState,
  PublicLeaderboard,
} from "@/components/leaderboard/PublicLeaderboard";
import { PageLoad } from "@/components/providers/PageLoad";
import { getPublicLeaderboard } from "@/lib/leaderboard/public";

export const metadata: Metadata = {
  title: "Leaderboard | LEVELLEDUP",
  description: "Official LevelledUp PUBG MOBILE Squad standings.",
};

export default async function LeaderboardPage() {
  const snapshot = await getPublicLeaderboard();

  return (
    <PageLoad>
      <AuthenticatedHeader />

      <main className="relative flex-1 overflow-hidden pt-[var(--header-height)]">
        <div aria-hidden className="home-grid absolute inset-x-0 top-0 h-[30rem] opacity-30" />
        <div aria-hidden className="pointer-events-none absolute inset-x-0 top-0 h-[34rem] bg-[radial-gradient(ellipse_60%_75%_at_70%_5%,rgba(255,75,24,0.14),transparent_70%)]" />

        <Container className="relative py-16 sm:py-20 lg:py-24">
          <div className="max-w-3xl">
            <p className="section-eyebrow"><span aria-hidden className="h-3 w-1 bg-accent" />Official Standings</p>
            <h1 className="type-display mt-5 text-[clamp(2.3rem,9.4vw,6.5rem)] uppercase leading-[0.86] tracking-[-0.055em] text-white">
              Public<br /><span className="text-accent">Leaderboard.</span>
            </h1>
            <p className="mt-6 max-w-2xl text-base leading-7 text-white/60">
              Finalized Tournament Match results build each Squad&apos;s official competitive record.
            </p>
          </div>

          <section className="relative mt-12 overflow-hidden rounded-[3px] border border-white/10 bg-[#080c0f]/90 sm:mt-16">
            <div className="flex flex-col gap-3 border-b border-white/10 px-5 py-5 sm:flex-row sm:items-center sm:justify-between sm:px-6">
              <div>
                <p className="text-[0.58rem] font-bold uppercase tracking-[0.18em] text-accent">All Squads</p>
                <h2 className="mt-1 text-lg font-semibold text-white">{snapshot.contextLabel ?? "Official competition standings"}</h2>
              </div>
              <Link href="/#upcoming-tournaments" className="compact-button compact-button-secondary self-start sm:self-auto">
                View Tournaments <ArrowIcon />
              </Link>
            </div>

            {snapshot.rows.length ? (
              <div className="overflow-x-auto overscroll-x-contain">
                <PublicLeaderboard rows={snapshot.rows} />
              </div>
            ) : (
              <LeaderboardEmptyState />
            )}
          </section>
        </Container>
      </main>

      <Footer />
    </PageLoad>
  );
}

function ArrowIcon() {
  return (
    <svg aria-hidden viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none">
      <path d="M3 8h9M9 5l3 3-3 3" stroke="currentColor" strokeWidth="1.4" />
    </svg>
  );
}
