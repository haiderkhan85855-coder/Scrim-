import { Hero } from "@/components/sections/Hero";
import { LiveScrims } from "@/components/sections/LiveScrims";
import type { PublicTournamentPresentation } from "@/data/tournament";

/** Keeps the two opening homepage sections grouped without changing document flow. */
export function HeroLiveTransition({
  tournament,
  registrationHref,
}: {
  tournament: PublicTournamentPresentation | null;
  registrationHref: string | null;
}) {
  return (
    <>
      <Hero registrationHref={registrationHref} />
      <LiveScrims tournament={tournament} />
    </>
  );
}
