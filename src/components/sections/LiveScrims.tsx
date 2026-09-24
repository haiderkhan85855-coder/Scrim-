"use client";

import { Container } from "@/components/layout/Container";
import { SectionIntro } from "@/components/sections/SectionIntro";
import type { PublicTournamentPresentation } from "@/data/tournament";
import { useSectionAnimation } from "@/hooks/useSectionAnimation";
import { formatTournamentDateTime } from "@/lib/tournaments/dateTime";

export function LiveScrims({
  tournament,
}: {
  tournament: PublicTournamentPresentation | null;
}) {
  const sectionRef = useSectionAnimation(({ gsap, trigger }) => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    gsap.from(trigger.querySelectorAll("[data-live-reveal]"), {
      autoAlpha: 0,
      y: 22,
      duration: 0.75,
      stagger: 0.1,
      ease: "power3.out",
      scrollTrigger: { trigger, start: "top 82%", once: true },
    });
  });

  return (
    <section
      ref={sectionRef}
      id="tournaments"
      className="homepage-section scroll-mt-16"
    >
      <Container className="grid gap-5 xl:grid-cols-[0.48fr_1fr] xl:items-center xl:gap-12">
        <SectionIntro
          eyebrow="Live Scrims"
          title="The battleground stands by."
          description="Join live scrims, test your skills and prove your squad on the battleground."
          revealAttribute="data-live-reveal"
        />

        <article
          data-live-reveal
          className="group relative isolate overflow-hidden rounded-[3px] border border-white/10 bg-[#0b1013] p-4 sm:p-5 lg:min-h-48 lg:p-6 lg:py-5"
        >
          <div aria-hidden className="absolute inset-0 -z-10 overflow-hidden">
            <div className="featured-tournament-artwork absolute inset-0" />
            <div className="absolute inset-0 bg-gradient-to-r from-[#0a0d0f] via-[#0a0d0f]/95 to-[#080b0d]/20" />
          </div>

          <div className="max-w-[34rem]">
            <p className="inline-flex items-center gap-2 bg-accent/10 px-2.5 py-1.5 text-[0.55rem] font-bold uppercase tracking-[0.16em] text-accent">
              <span aria-hidden className="h-2.5 w-1 bg-accent" />
              Featured Tournament
            </p>

            <h3 className="mt-3 text-lg font-semibold tracking-[-0.025em] text-white sm:text-xl lg:mt-4 lg:text-2xl">
              {tournament?.title ?? "No Active Tournament"}
            </h3>
            <p className="mt-2 max-w-md text-sm leading-5 text-white/60 lg:leading-6">
              {tournament
                ? `${tournament.game} · ${tournament.mode} · ${formatTournamentDateTime(tournament.startsAt)}`
                : "There are no public tournaments running right now. Check back soon for the next drop."}
            </p>

            {tournament ? (
              <dl className="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-[0.58rem] uppercase tracking-[0.14em] text-white/45">
                <div><dt className="inline">{tournament.rewardLabel}: </dt><dd className="inline text-white/80">{tournament.rewardValue}</dd></div>
                <div><dt className="inline">Teams: </dt><dd className="inline text-white/80">{tournament.registeredTeams}/{tournament.maxTeams}</dd></div>
                <div><dt className="inline">Initial entry: </dt><dd className="inline text-white/80">{tournament.entryFee}</dd></div>
              </dl>
            ) : null}

            {tournament ? (
              <div className="mt-5 flex flex-wrap gap-3">
                <a href="#upcoming-tournaments" className="compact-button compact-button-secondary">
                  View Tournaments <ArrowIcon />
                </a>
                {tournament.statusCode === "registration_open" ? (
                  <a href={`/tournaments/${tournament.id}/register`} className="compact-button compact-button-primary">
                    Join Scrim <ArrowIcon />
                  </a>
                ) : (
                  <span className="inline-flex min-h-11 items-center rounded-[2px] border border-accent/25 bg-accent/10 px-4 text-[0.58rem] font-bold uppercase tracking-[0.17em] text-accent/70">
                    {tournament.status}
                  </span>
                )}
              </div>
            ) : (
              <p className="mt-4 text-[0.58rem] font-semibold uppercase tracking-[0.16em] text-white/35 lg:mt-5">
                Next Tournament announcement pending
              </p>
            )}
          </div>
        </article>
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
