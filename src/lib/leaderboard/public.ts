import "server-only";

export type PublicLeaderboardStanding = {
  registrationId: string;
  teamId: string;
  teamName: string;
  matches: number | null;
  wins: number | null;
  kills: number | null;
  placementPoints: number | null;
  totalPoints: number | null;
};

export type PublicLeaderboardSnapshot = {
  contextLabel: string | null;
  rows: PublicLeaderboardStanding[];
  sourceAvailable: boolean;
};

/**
 * No anonymous/public standings projection exists in the current migration chain.
 * `match_results` contains trustworthy finalized results, but RLS exposes each row
 * only to active members of its registered team. Returning a partial private view
 * as a public leaderboard would be both incomplete and misleading.
 */
export async function getPublicLeaderboard(): Promise<PublicLeaderboardSnapshot> {
  return {
    contextLabel: null,
    rows: [],
    sourceAvailable: false,
  };
}
