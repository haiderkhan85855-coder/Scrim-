import { AuthToast } from "@/components/auth/AuthToast";
import { Footer } from "@/components/layout/Footer";
import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import { PageLoad } from "@/components/providers/PageLoad";
import { FinalCTA } from "@/components/sections/FinalCTA";
import { HeroLiveTransition } from "@/components/sections/HeroLiveTransition";
import { HowItWorks } from "@/components/sections/HowItWorks";
import { Leaderboard } from "@/components/sections/Leaderboard";
import { UpcomingTournaments } from "@/components/sections/UpcomingTournaments";
import { getPublicLeaderboard } from "@/lib/leaderboard/public";
import { getHomepageTournaments } from "@/lib/tournaments/public";

export default async function Home({ searchParams }: PageProps<"/">) {
  const { auth, profile } = await searchParams;
  const [tournaments, leaderboardSnapshot] = await Promise.all([
    getHomepageTournaments(),
    getPublicLeaderboard(),
  ]);
  const { featuredTournament, upcomingTournaments } = tournaments;
  const registrationTournament =
    featuredTournament?.statusCode === "registration_open"
      ? featuredTournament
      : upcomingTournaments.find(
          (tournament) => tournament.statusCode === "registration_open",
        );
  const registrationHref = registrationTournament
    ? `/tournaments/${registrationTournament.id}/register`
    : null;

  return (
    <PageLoad>
      <AuthenticatedHeader />

      <main className="flex flex-1 flex-col">
        <HeroLiveTransition
          tournament={featuredTournament}
          registrationHref={registrationHref}
        />
        <UpcomingTournaments tournaments={upcomingTournaments} />
        <Leaderboard snapshot={leaderboardSnapshot} />
        <HowItWorks />
        <FinalCTA registrationHref={registrationHref} />
      </main>

      <Footer />

      {profile === "updated" ? (
        <AuthToast
          message="Profile updated successfully."
          queryParameter="profile"
          tone="success"
        />
      ) : auth === "welcome-back" ? (
        <AuthToast message="Welcome back." queryParameter="auth" />
      ) : null}
    </PageLoad>
  );
}
