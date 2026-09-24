import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { TournamentManagement } from "@/components/admin/TournamentManagement";
import type {
  AdminTournament,
  TournamentGameMode,
  TournamentPerspective,
  TournamentRewardModel,
  TournamentStatus,
} from "@/components/admin/types";
import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import {
  getCurrentAdminAccess,
  hasRequiredAdminRole,
} from "@/lib/auth/admin";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "Admin | LEVELLEDUP",
};

type TournamentRow = {
  id: string;
  tournament_id: string;
  name: string;
  description: string | null;
  status: TournamentStatus;
  scheduled_start_at: string;
  scheduled_end_at: string | null;
  registration_opens_at: string;
  registration_closes_at: string;
  max_team_slots: number;
  matches_per_day: number;
  number_of_days: number;
  game_mode: TournamentGameMode;
  perspective: TournamentPerspective;
  entry_fee_minor: number;
  currency: string;
  reward_model: TournamentRewardModel;
  prize_pool_minor: number | null;
  per_kill_reward_minor: number | null;
  archived_at: string | null;
  updated_at: string;
};

export default async function AdminPage() {
  const access = await getCurrentAdminAccess();

  if (!access || !hasRequiredAdminRole(access)) {
    const supabase = await createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    redirect(user ? "/" : "/login?next=/admin");
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("tournaments")
    .select(
      "id, tournament_id, name, description, status, scheduled_start_at, scheduled_end_at, registration_opens_at, registration_closes_at, max_team_slots, matches_per_day, number_of_days, game_mode, perspective, entry_fee_minor, currency, reward_model, prize_pool_minor, per_kill_reward_minor, archived_at, updated_at",
    )
    .order("scheduled_start_at", { ascending: false });

  if (error) {
    console.error("[Admin: tournament list]", {
      code: error.code,
      message: error.message,
      userReference: access.userId.slice(-6),
    });
    throw new Error("Unable to load tournament management.");
  }

  const tournaments = ((data ?? []) as TournamentRow[]).map(
    (tournament): AdminTournament => ({
      id: tournament.id,
      tournamentId: tournament.tournament_id,
      name: tournament.name,
      description: tournament.description,
      status: tournament.status,
      scheduledStartAt: tournament.scheduled_start_at,
      scheduledEndAt: tournament.scheduled_end_at,
      registrationOpensAt: tournament.registration_opens_at,
      registrationClosesAt: tournament.registration_closes_at,
      maxTeamSlots: tournament.max_team_slots,
      matchesPerDay: tournament.matches_per_day,
      numberOfDays: tournament.number_of_days,
      gameMode: tournament.game_mode,
      perspective: tournament.perspective,
      entryFeeMinor: tournament.entry_fee_minor,
      currency: tournament.currency,
      rewardModel: tournament.reward_model,
      prizePoolMinor: tournament.prize_pool_minor,
      perKillRewardMinor: tournament.per_kill_reward_minor,
      archivedAt: tournament.archived_at,
      updatedAt: tournament.updated_at,
    }),
  );

  return (
    <>
      <AuthenticatedHeader />
      <main className="min-h-svh px-5 pb-14 pt-[calc(var(--header-height)+3rem)] sm:px-8 sm:pb-20 lg:px-10">
        <div className="mx-auto w-full max-w-7xl">
          <header className="max-w-3xl">
            <p className="type-eyebrow text-accent">Admin command</p>
            <h1 className="type-display mt-5 text-[clamp(3rem,8vw,6.5rem)] uppercase leading-[0.9]">
              Tournament Management
            </h1>
            <p className="mt-5 max-w-2xl text-sm leading-7 text-foreground-muted">
              Configure private tournament drafts and control registration
              lifecycle without bypassing database rules.
            </p>
            <p className="mt-4 text-[0.58rem] font-semibold uppercase tracking-[0.16em] text-foreground-subtle">
              Signed in as {access.role.replace("_", " ")}
            </p>
          </header>

          <TournamentManagement tournaments={tournaments} />
        </div>
      </main>
    </>
  );
}
