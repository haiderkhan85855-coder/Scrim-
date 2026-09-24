"use server";

import { revalidatePath } from "next/cache";

import {
  getCurrentAdminAccess,
  hasRequiredAdminRole,
} from "@/lib/auth/admin";
import { createClient } from "@/lib/supabase/server";
import { tournamentDateTimeInputToUtc } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

export type TournamentActionState = {
  error?: string;
  success?: string;
};

type RewardModel = "fixed_prize_pool" | "per_kill";

type TournamentRpcInput = {
  p_name: string;
  p_description: string | null;
  p_scheduled_start_at: string;
  p_scheduled_end_at: string | null;
  p_registration_opens_at: string;
  p_registration_closes_at: string;
  p_max_team_slots: number;
  p_matches_per_day: number;
  p_number_of_days: number;
  p_game_mode: "solo" | "duo" | "squad";
  p_perspective: "tpp" | "fpp";
  p_entry_fee_minor: number;
  p_currency: string;
  p_reward_model: RewardModel;
  p_prize_pool_minor: number | null;
  p_per_kill_reward_minor: number | null;
};

function readField(formData: FormData, name: string) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function parseTournamentDateTime(
  value: string,
  label: string,
): { value: string } | { error: string };
function parseTournamentDateTime(
  value: string,
  label: string,
  optional: true,
): { value: string | null } | { error: string };
function parseTournamentDateTime(
  value: string,
  label: string,
  optional = false,
): { value: string | null } | { error: string } {
  if (!value && optional) return { value: null } as const;

  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)) {
    return {
      error: `${label} must be a valid Pakistan date and time.`,
    } as const;
  }

  const parsed = tournamentDateTimeInputToUtc(value);

  if (!parsed) {
    return {
      error: `${label} must be a valid Pakistan date and time.`,
    } as const;
  }

  return { value: parsed } as const;
}

function parsePositiveInteger(
  value: string,
  label: string,
  maximum: number,
): { value: number } | { error: string } {
  if (!/^\d+$/.test(value)) {
    return { error: `${label} must be a whole number.` } as const;
  }

  const parsed = Number(value);

  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maximum) {
    return {
      error: `${label} must be between 1 and ${maximum.toLocaleString("en")}.`,
    } as const;
  }

  return { value: parsed } as const;
}

function parseMoney(
  value: string,
  currency: string,
  label: string,
): { value: number } | { error: string } {
  const fractionDigits = currencyFractionDigits(currency);

  if (!/^\d+(?:\.\d+)?$/.test(value)) {
    return { error: `${label} must be a nonnegative amount.` } as const;
  }

  const [wholePart, submittedFraction = ""] = value.split(".");

  if (submittedFraction.length > fractionDigits) {
    return {
      error: `${label} supports at most ${fractionDigits} decimal places for ${currency}.`,
    } as const;
  }

  const scale = 10 ** fractionDigits;
  const whole = Number(wholePart);
  const fraction = Number(submittedFraction.padEnd(fractionDigits, "0") || "0");
  const minor = whole * scale + fraction;

  if (!Number.isSafeInteger(whole) || !Number.isSafeInteger(minor)) {
    return { error: `${label} is too large.` } as const;
  }

  return { value: minor } as const;
}

function parseTournamentInput(
  formData: FormData,
): { value: TournamentRpcInput } | { error: string } {
  const name = readField(formData, "name");
  const description = readField(formData, "description");
  const currency = readField(formData, "currency").toUpperCase();
  const gameMode = readField(formData, "game_mode");
  const perspective = readField(formData, "perspective");
  const rewardModel = readField(formData, "reward_model");

  if (name.length < 2 || name.length > 120) {
    return { error: "Tournament name must be between 2 and 120 characters." } as const;
  }

  if (description.length > 5000) {
    return { error: "Description must be 5,000 characters or fewer." } as const;
  }

  if (!/^[A-Z]{3}$/.test(currency)) {
    return { error: "Currency must be a valid three-letter code such as PKR." } as const;
  }

  if (gameMode !== "solo" && gameMode !== "duo" && gameMode !== "squad") {
    return { error: "Select a valid game mode." } as const;
  }

  if (perspective !== "tpp" && perspective !== "fpp") {
    return { error: "Select a valid perspective." } as const;
  }

  if (rewardModel !== "fixed_prize_pool" && rewardModel !== "per_kill") {
    return { error: "Select a valid reward model." } as const;
  }

  const scheduledStart = parseTournamentDateTime(
    readField(formData, "scheduled_start_at"),
    "Tournament start",
  );
  const scheduledEnd = parseTournamentDateTime(
    readField(formData, "scheduled_end_at"),
    "Tournament end",
    true,
  );
  const registrationOpens = parseTournamentDateTime(
    readField(formData, "registration_opens_at"),
    "Registration opening",
  );
  const registrationCloses = parseTournamentDateTime(
    readField(formData, "registration_closes_at"),
    "Registration closing",
  );

  if ("error" in scheduledStart) return scheduledStart;
  if ("error" in scheduledEnd) return scheduledEnd;
  if ("error" in registrationOpens) return registrationOpens;
  if ("error" in registrationCloses) return registrationCloses;

  if (
    scheduledEnd.value &&
    scheduledEnd.value <= scheduledStart.value
  ) {
    return { error: "Tournament end must be after the start." } as const;
  }

  if (registrationOpens.value >= registrationCloses.value) {
    return { error: "Registration must open before it closes." } as const;
  }

  if (registrationCloses.value > scheduledStart.value) {
    return { error: "Registration must close no later than the tournament start." } as const;
  }

  const maxTeamSlots = parsePositiveInteger(
    readField(formData, "max_team_slots"),
    "Maximum team slots",
    1000,
  );
  const matchesPerDay = parsePositiveInteger(
    readField(formData, "matches_per_day"),
    "Matches per day",
    100,
  );
  const numberOfDays = parsePositiveInteger(
    readField(formData, "number_of_days"),
    "Number of days",
    365,
  );

  if ("error" in maxTeamSlots) return { error: maxTeamSlots.error };
  if ("error" in matchesPerDay) return { error: matchesPerDay.error };
  if ("error" in numberOfDays) return { error: numberOfDays.error };

  const entryFee = parseMoney(
    readField(formData, "entry_fee"),
    currency,
    "Entry fee",
  );

  if ("error" in entryFee) return { error: entryFee.error };

  let prizePoolMinor: number | null = null;
  let perKillRewardMinor: number | null = null;

  if (rewardModel === "fixed_prize_pool") {
    const prizePool = parseMoney(
      readField(formData, "prize_pool"),
      currency,
      "Prize pool",
    );

    if ("error" in prizePool) return { error: prizePool.error };
    prizePoolMinor = prizePool.value;
  } else {
    const perKillReward = parseMoney(
      readField(formData, "per_kill_reward"),
      currency,
      "Per-kill reward",
    );

    if ("error" in perKillReward) return { error: perKillReward.error };
    if (perKillReward.value <= 0) {
      return { error: "Per-kill reward must be greater than zero." } as const;
    }
    perKillRewardMinor = perKillReward.value;
  }

  return {
    value: {
      p_name: name,
      p_description: description || null,
      p_scheduled_start_at: scheduledStart.value,
      p_scheduled_end_at: scheduledEnd.value,
      p_registration_opens_at: registrationOpens.value,
      p_registration_closes_at: registrationCloses.value,
      p_max_team_slots: maxTeamSlots.value,
      p_matches_per_day: matchesPerDay.value,
      p_number_of_days: numberOfDays.value,
      p_game_mode: gameMode,
      p_perspective: perspective,
      p_entry_fee_minor: entryFee.value,
      p_currency: currency,
      p_reward_model: rewardModel,
      p_prize_pool_minor: prizePoolMinor,
      p_per_kill_reward_minor: perKillRewardMinor,
    } satisfies TournamentRpcInput,
  } as const;
}

async function authorizeAdminAction() {
  const access = await getCurrentAdminAccess();

  if (!hasRequiredAdminRole(access)) {
    return null;
  }

  return createClient();
}

function tournamentError(error: { code?: string; message: string }) {
  if (error.code === "42501") {
    return "You no longer have permission to manage tournaments.";
  }

  if (
    error.code === "P4301" ||
    error.code === "P4302" ||
    error.code === "P4303" ||
    error.code === "P4304" ||
    error.code === "P4310" ||
    error.code === "P4311" ||
    error.code === "P4312" ||
    error.code === "P4313" ||
    error.code === "P4103" ||
    error.code === "22023"
  ) {
    return error.message;
  }

  if (error.code === "23514") {
    return "The database rejected the tournament dates, limits, or reward configuration.";
  }

  if (error.code === "23505") {
    return "A permanent tournament ID could not be allocated. Please try again.";
  }

  return "The tournament could not be saved. Please try again.";
}

function revalidateTournamentViews(publicTournamentId?: string) {
  revalidatePath("/");
  revalidatePath("/admin");

  if (/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(publicTournamentId ?? "")) {
    revalidatePath(`/admin/tournaments/${publicTournamentId}`);
    revalidatePath(`/tournaments/${publicTournamentId}/register`);
  }
}

export async function createTournament(
  _previousState: TournamentActionState,
  formData: FormData,
): Promise<TournamentActionState> {
  const parsed = parseTournamentInput(formData);

  if ("error" in parsed) return { error: parsed.error };

  const supabase = await authorizeAdminAction();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_create_tournament",
    parsed.value,
  );

  if (error) {
    console.error("[Admin: create tournament]", {
      code: error.code,
      message: error.message,
    });
    return { error: tournamentError(error) };
  }

  revalidateTournamentViews();
  return { success: "Tournament draft created." };
}

export async function updateDraftTournament(
  _previousState: TournamentActionState,
  formData: FormData,
): Promise<TournamentActionState> {
  const tournamentId = readField(formData, "tournament_id");
  const publicTournamentId = readField(
    formData,
    "public_tournament_id",
  ).toUpperCase();
  if (!tournamentId) return { error: "Tournament reference is missing." };

  const parsed = parseTournamentInput(formData);
  if ("error" in parsed) return { error: parsed.error };

  const supabase = await authorizeAdminAction();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_update_draft_tournament",
    {
      p_tournament_id: tournamentId,
      ...parsed.value,
    },
  );

  if (error) {
    console.error("[Admin: update tournament]", {
      code: error.code,
      message: error.message,
    });
    return { error: tournamentError(error) };
  }

  revalidateTournamentViews(publicTournamentId);
  return { success: "Tournament updated." };
}

async function transitionTournament(
  formData: FormData,
  action: "open_registration" | "close_registration" | "cancel",
) {
  const tournamentId = readField(formData, "tournament_id");
  const publicTournamentId = readField(
    formData,
    "public_tournament_id",
  ).toUpperCase();
  if (!tournamentId) return { error: "Tournament reference is missing." };

  const supabase = await authorizeAdminAction();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = action === "cancel"
    ? await supabase.rpc("levelledup_admin_cancel_tournament_with_credits", {
        p_tournament_id: tournamentId,
      })
    : await supabase.rpc("levelledup_admin_transition_tournament", {
        p_tournament_id: tournamentId,
        p_action: action,
      });

  if (error) {
    console.error("[Admin: tournament lifecycle]", {
      action,
      code: error.code,
      message: error.message,
    });
    return { error: tournamentError(error) };
  }

  revalidateTournamentViews(publicTournamentId);
  return { success: true };
}

export async function openTournamentRegistration(
  _previousState: TournamentActionState,
  formData: FormData,
): Promise<TournamentActionState> {
  const result = await transitionTournament(formData, "open_registration");
  return result.error
    ? { error: result.error }
    : { success: "Registration opened." };
}

export async function closeTournamentRegistration(
  _previousState: TournamentActionState,
  formData: FormData,
): Promise<TournamentActionState> {
  const result = await transitionTournament(formData, "close_registration");
  return result.error
    ? { error: result.error }
    : { success: "Registration closed." };
}

export async function cancelTournament(
  _previousState: TournamentActionState,
  formData: FormData,
): Promise<TournamentActionState> {
  const publicTournamentId = readField(formData, "public_tournament_id");
  const confirmation = readField(formData, "confirmation").toUpperCase();

  if (!publicTournamentId || confirmation !== publicTournamentId.toUpperCase()) {
    return { error: "Enter the permanent Tournament ID to confirm cancellation." };
  }

  const result = await transitionTournament(formData, "cancel");
  return result.error
    ? { error: result.error }
    : { success: "Tournament cancelled. Eligible team credits are now available." };
}

export async function retireTournament(
  _previousState: TournamentActionState,
  formData: FormData,
): Promise<TournamentActionState> {
  const tournamentId = readField(formData, "tournament_id");
  const publicTournamentId = readField(formData, "public_tournament_id");
  const confirmation = readField(formData, "confirmation").toUpperCase();

  if (!tournamentId || !publicTournamentId) {
    return { error: "Tournament reference is missing." };
  }

  if (confirmation !== publicTournamentId.toUpperCase()) {
    return { error: "Enter the permanent Tournament ID to confirm this action." };
  }

  const supabase = await authorizeAdminAction();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_retire_tournament",
    {
      p_tournament_id: tournamentId,
      p_public_tournament_id: confirmation,
    },
  );

  if (error) {
    console.error("[Admin: retire tournament]", {
      code: error.code,
      message: error.message,
    });
    return { error: tournamentError(error) };
  }

  const outcome =
    data && typeof data === "object" && "outcome" in data
      ? data.outcome
      : null;

  revalidateTournamentViews(publicTournamentId);

  return outcome === "deleted"
    ? { success: "Untouched tournament draft deleted." }
    : { success: "Tournament archived. History was preserved and eligible cancellation credits were created." };
}

export async function markSupportMessageRead(
  _previousState: TournamentActionState,
  formData: FormData,
): Promise<TournamentActionState> {
  const messageId = readField(formData, "message_id");

  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      messageId,
    )
  ) {
    return { error: "Message reference is invalid." };
  }

  const supabase = await authorizeAdminAction();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc("levelledup_mark_support_message_read", {
    p_message_id: messageId,
  });

  if (error) {
    console.error("[Admin: mark support message read]", {
      code: error.code,
      message: error.message,
    });
    return { error: "The message could not be marked as read." };
  }

  revalidatePath("/admin");
  return { success: "Message marked as read." };
}
