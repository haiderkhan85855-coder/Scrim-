import "server-only";

import { createClient as createSupabaseClient } from "@supabase/supabase-js";

import type { PublicTournamentPresentation } from "@/data/tournament";
import { getSupabaseConfig } from "@/lib/supabase/config";
import { currencyFractionDigits } from "@/lib/tournaments/money";

type PublicTournamentStatus =
  | "live"
  | "registration_open"
  | "registration_closed";

type PublicTournamentRow = {
  tournament_id: string;
  name: string;
  status: PublicTournamentStatus;
  scheduled_start_at: string;
  max_team_slots: number;
  matches_per_day: number;
  number_of_days: number;
  game_mode: "solo" | "duo" | "squad";
  perspective: "tpp" | "fpp";
  entry_fee_minor: number;
  currency: string;
  reward_model: "fixed_prize_pool" | "per_kill";
  prize_pool_minor: number | null;
  per_kill_reward_minor: number | null;
  confirmed_team_count: number;
};

const statusLabels: Record<
  PublicTournamentStatus,
  PublicTournamentPresentation["status"]
> = {
  live: "LIVE",
  registration_open: "REGISTRATION OPEN",
  registration_closed: "REGISTRATION CLOSED",
};

function formatMoney(value: number | null, currency: string) {
  if (value === null) return "Not set";
  const fractionDigits = currencyFractionDigits(currency);
  const amount = value / 10 ** fractionDigits;

  try {
    return new Intl.NumberFormat("en-PK", {
      style: "currency",
      currency,
      minimumFractionDigits: 0,
      maximumFractionDigits: fractionDigits,
    }).format(amount);
  } catch {
    return `${currency} ${amount.toLocaleString("en-PK")}`;
  }
}

function toPresentation(
  tournament: PublicTournamentRow,
  priority = false,
): PublicTournamentPresentation {
  const rewardMinor =
    tournament.reward_model === "fixed_prize_pool"
      ? tournament.prize_pool_minor
      : tournament.per_kill_reward_minor;

  return {
    id: tournament.tournament_id,
    title: tournament.name,
    status: statusLabels[tournament.status],
    statusCode: tournament.status,
    game: "PUBG MOBILE",
    mode: `${tournament.game_mode.toUpperCase()} / ${tournament.perspective.toUpperCase()}`,
    rewardLabel:
      tournament.reward_model === "fixed_prize_pool" ? "Prize Pool" : "Per Kill",
    rewardValue: formatMoney(rewardMinor, tournament.currency),
    entryFee: tournament.entry_fee_minor === 0
      ? "FREE"
      : formatMoney(tournament.entry_fee_minor, tournament.currency),
    maxTeams: tournament.max_team_slots,
    registeredTeams: Number(tournament.confirmed_team_count),
    formatTags: [
      tournament.game_mode.toUpperCase(),
      tournament.perspective.toUpperCase(),
    ],
    startsAt: tournament.scheduled_start_at,
    ctaLabel:
      tournament.status === "registration_open" ? "JOIN SCRIM" : "VIEW DETAILS",
    priority,
  };
}

export async function getHomepageTournaments() {
  const { url, publishableKey } = getSupabaseConfig();
  const supabase = createSupabaseClient(url, publishableKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
  });
  const { data, error } = await supabase.rpc("levelledup_public_tournaments");

  if (error) {
    const serializedError = JSON.stringify({
      code: error.code ?? null,
      message: error.message,
      details: error.details ?? null,
      hint: error.hint ?? null,
    });
    const isTransportFailure =
      !error.code && error.message.toLowerCase().includes("fetch failed");

    if (error.code === "PGRST202") {
      if (process.env.NODE_ENV !== "production") {
        console.info(
          "[Public tournaments] The local public projection migration has not been applied to Supabase yet.",
        );
      }
    } else if (isTransportFailure) {
      console.warn("[Public tournaments]", serializedError);
    } else {
      console.error("[Public tournaments]", serializedError);
    }
    return {
      featuredTournament: null,
      upcomingTournaments: [] as PublicTournamentPresentation[],
    };
  }

  const rows = (data ?? []) as PublicTournamentRow[];
  const now = Date.now();
  const futureRows = rows.filter(
    (tournament) =>
      new Date(tournament.scheduled_start_at).getTime() >= now,
  );
  const liveRows = rows
    .filter((tournament) => tournament.status === "live")
    .sort(
      (left, right) =>
        new Date(right.scheduled_start_at).getTime() -
        new Date(left.scheduled_start_at).getTime(),
    );
  const registrationOpenRows = futureRows
    .filter((tournament) => tournament.status === "registration_open")
    .sort(
      (left, right) =>
        new Date(left.scheduled_start_at).getTime() -
        new Date(right.scheduled_start_at).getTime(),
    );
  const registrationClosedRows = futureRows
    .filter((tournament) => tournament.status === "registration_closed")
    .sort(
      (left, right) =>
        new Date(left.scheduled_start_at).getTime() -
        new Date(right.scheduled_start_at).getTime(),
    );
  const featured =
    liveRows[0] ?? registrationOpenRows[0] ?? registrationClosedRows[0];
  const upcoming = [...registrationOpenRows, ...registrationClosedRows]
    .sort(
      (left, right) =>
        new Date(left.scheduled_start_at).getTime() -
        new Date(right.scheduled_start_at).getTime(),
    )
    .slice(0, 3);

  return {
    featuredTournament: featured ? toPresentation(featured, true) : null,
    upcomingTournaments: upcoming.map((tournament, index) =>
      toPresentation(tournament, index === 0),
    ),
  };
}
