"use client";

import Link from "next/link";

import { Container } from "@/components/layout/Container";
import {
  LeaderboardEmptyState,
  PublicLeaderboard,
} from "@/components/leaderboard/PublicLeaderboard";
import { SectionIntro } from "@/components/sections/SectionIntro";
import { useSectionAnimation } from "@/hooks/useSectionAnimation";
import type { PublicLeaderboardSnapshot } from "@/lib/leaderboard/public";

export function Leaderboard({ snapshot }: { snapshot: PublicLeaderboardSnapshot }) {
  const sectionRef = useSectionAnimation(({ gsap, trigger }) => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    const timeline = gsap.timeline({
      scrollTrigger: { trigger, start: "top 82%", once: true },
    });
    timeline.from(trigger.querySelectorAll("[data-leaderboard-reveal]"), {
      autoAlpha: 0,
      y: 18,
      duration: 0.65,
      stagger: 0.08,
      ease: "power3.out",
    });

    const rows = trigger.querySelectorAll("[data-leaderboard-row]");
    if (rows.length) {
      timeline.from(
        rows,
        { autoAlpha: 0, y: 10, duration: 0.45, stagger: 0.045, ease: "power3.out" },
        "-=0.35",
      );
    }
  });

  const standings = snapshot.rows.slice(0, 15);

  return (
    <section ref={sectionRef} id="leaderboard" className="homepage-section homepage-section-glow scroll-mt-16">
      <Container className="grid gap-5 xl:grid-cols-[0.42fr_1fr] xl:items-center xl:gap-12">
        <div>
          <SectionIntro
            eyebrow="Top Squads"
            title="The ones to beat."
            description="Official Squad standings from finalized LevelledUp Match results."
            revealAttribute="data-leaderboard-reveal"
          />
          <Link
            data-leaderboard-reveal
            href="/leaderboard"
            className="compact-button compact-button-secondary mt-4 lg:mt-6"
          >
            View Full Leaderboard <ArrowIcon />
          </Link>
        </div>

        <div
          data-leaderboard-reveal
          className="min-w-0 overflow-hidden rounded-[3px] border border-white/10 bg-[#080c0f]/85"
        >
          {standings.length ? (
            <PublicLeaderboard rows={standings} compact animateRows />
          ) : (
            <LeaderboardEmptyState compact />
          )}
        </div>
      </Container>
    </section>
  );
}

function ArrowIcon() {
  return (
    <svg aria-hidden viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none">
      <path d="M3 8h9M9 5l3 3-3 3" stroke="currentColor" strokeWidth="1.4" />
    </svg>
  );
}
