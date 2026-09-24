"use client";

import { Container } from "@/components/layout/Container";
import { SectionIntro } from "@/components/sections/SectionIntro";
import type { PublicTournamentPresentation } from "@/data/tournament";
import { useSectionAnimation } from "@/hooks/useSectionAnimation";

const scheduleFormatter = new Intl.DateTimeFormat("en-US", {
  weekday: "short",
  month: "short",
  day: "2-digit",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
  timeZone: "Asia/Karachi",
});

export function UpcomingTournaments({
  tournaments,
}: {
  tournaments: PublicTournamentPresentation[];
}) {
  const sectionRef = useSectionAnimation(({ gsap, trigger }) => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timeline = gsap.timeline({
      scrollTrigger: { trigger, start: "top 82%", once: true },
    });
    timeline.from(trigger.querySelectorAll("[data-upcoming-reveal]"), {
      autoAlpha: 0,
      y: 20,
      duration: 0.7,
      stagger: 0.08,
      ease: "power3.out",
    });
    const cards = trigger.querySelectorAll("[data-tournament-card]");
    if (cards.length) {
      timeline.from(
        cards,
        { autoAlpha: 0, y: 18, duration: 0.65, stagger: 0.09, ease: "power3.out" },
        "-=0.4",
      );
    }
  });

  return (
    <section
      ref={sectionRef}
      id="upcoming-tournaments"
      className="homepage-section homepage-section-shade scroll-mt-16"
    >
      <Container className="grid gap-5 xl:grid-cols-[0.48fr_1fr] xl:items-center xl:gap-12">
        <SectionIntro
          eyebrow="Upcoming Tournaments"
          title="Enter the next battle."
          description="Choose your lobby, ready your squad and claim a place in the next LevelledUp competition."
          revealAttribute="data-upcoming-reveal"
        />

        {tournaments.length ? (
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {tournaments.map((tournament) => (
              <TournamentCard key={tournament.id} tournament={tournament} />
            ))}
          </div>
        ) : (
          <div
            data-upcoming-reveal
            className="flex flex-col items-start gap-3 rounded-[3px] border border-white/10 bg-white/[0.018] p-4 sm:flex-row sm:gap-4 sm:p-5 lg:p-6"
          >
            <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-[3px] bg-accent/10 text-accent lg:h-12 lg:w-12">
              <CalendarIcon />
            </span>
            <div>
              <p className="text-[0.62rem] font-bold uppercase tracking-[0.16em] text-white/85">
                Tournament queue clear
              </p>
              <p className="mt-2 max-w-xl text-sm leading-5 text-white/55 lg:leading-6">
                No public tournaments are currently scheduled. The next LevelledUp competition will appear here when registration is announced.
              </p>
            </div>
          </div>
        )}
      </Container>
    </section>
  );
}

function TournamentCard({ tournament }: { tournament: PublicTournamentPresentation }) {
  const isOpen = tournament.statusCode === "registration_open";
  return (
    <article
      data-tournament-card
      className={`group flex flex-col rounded-[3px] border bg-white/[0.018] p-4 transition duration-300 hover:-translate-y-1 hover:bg-white/[0.03] sm:p-5 lg:min-h-[15rem] ${tournament.priority ? "border-accent/45" : "border-white/10"}`}
    >
      <div className="flex items-center justify-between gap-3">
        <span className="text-[0.52rem] font-bold uppercase tracking-[0.15em] text-accent">
          {tournament.status}
        </span>
        <span className="text-[0.5rem] uppercase tracking-[0.14em] text-white/35">
          {scheduleFormatter.format(new Date(tournament.startsAt))} PKT
        </span>
      </div>
      <h3 className="mt-4 text-lg font-semibold uppercase leading-tight tracking-[-0.025em] text-white">
        {tournament.title}
      </h3>
      <p className="mt-2 text-[0.55rem] uppercase tracking-[0.14em] text-white/45">
        {tournament.game} · {tournament.mode}
      </p>
      <div className="mt-5 grid grid-cols-2 gap-3 border-y border-white/10 py-3 text-xs">
        <span className="text-white/45">{tournament.rewardLabel}<strong className="mt-1 block text-white/80">{tournament.rewardValue}</strong></span>
        <span className="text-white/45">Initial Fee<strong className="mt-1 block text-white/80">{tournament.entryFee}</strong></span>
      </div>
      {isOpen ? (
        <a href={`/tournaments/${tournament.id}/register`} className="compact-button compact-button-primary mt-auto translate-y-2">
          {tournament.ctaLabel} <ArrowIcon />
        </a>
      ) : (
        <span className="compact-button compact-button-secondary mt-auto translate-y-2 cursor-default opacity-50">
          {tournament.ctaLabel}
        </span>
      )}
    </article>
  );
}

function CalendarIcon() {
  return (
    <svg aria-hidden viewBox="0 0 24 24" className="h-6 w-6" fill="none">
      <path d="M5 5h14v14H5V5Zm3-2v4m8-4v4M5 9h14m-10 4h2m2 0h2m-6 3h2" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  );
}

function ArrowIcon() {
  return (
    <svg aria-hidden viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none">
      <path d="M3 8h9M9 5l3 3-3 3" stroke="currentColor" strokeWidth="1.4" />
    </svg>
  );
}
