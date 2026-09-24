"use server";

import { revalidatePath } from "next/cache";

import {
  getCurrentAdminAccess,
  hasRequiredAdminRole,
} from "@/lib/auth/admin";
import { createClient } from "@/lib/supabase/server";
import { tournamentDateTimeInputToUtc } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

export type RegistrationActionState = {
  error?: string;
  success?: string;
};

export type TournamentSetupActionState = RegistrationActionState;

function readField(formData: FormData, name: string) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function registrationError(error: { code?: string; message: string }) {
  if (error.code === "42501") {
    return "You no longer have permission to manage registrations.";
  }

  if (error.code === "P4005") return "Tournament is full.";
  if (error.code === "P4409") {
    return "Finalize the tournament Squad before approval.";
  }

  if (
    error.code === "P4002" ||
    error.code === "P4003" ||
    error.code === "P4004" ||
    error.code === "P4006" ||
    error.code === "P4007" ||
    error.code === "P4401" ||
    error.code === "P4402" ||
    error.code === "P4403" ||
    error.code === "P4404" ||
    error.code === "P4405" ||
    error.code === "P4406" ||
    error.code === "P4407" ||
    error.code === "P4408" ||
    error.code === "P4409" ||
    error.code === "P4410" ||
    error.code === "P4411" ||
    error.code === "P4412" ||
    error.code === "P4413" ||
    error.code === "P4414" ||
    error.code === "P4415" ||
    error.code === "P4416" ||
    error.code === "P4417" ||
    error.code === "P4418" ||
    error.code === "P4502" ||
    error.code === "P4506" ||
    error.code === "P4507" ||
    error.code === "P4508" ||
    error.code === "P4517" ||
    error.code === "P4518" ||
    error.code === "P4519" ||
    error.code === "P4520" ||
    error.code === "P4521" ||
    error.code === "22023"
  ) {
    return error.message;
  }

  if (error.code === "23505") {
    return "That slot is already occupied.";
  }

  return "The registration could not be updated. Please try again.";
}

async function adminClient() {
  const access = await getCurrentAdminAccess();
  if (!hasRequiredAdminRole(access)) return null;
  return createClient();
}

function readReferences(formData: FormData) {
  const registrationId = readField(formData, "registration_id");
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();

  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      registrationId,
    )
  ) {
    return { error: "Registration reference is invalid." } as const;
  }

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." } as const;
  }

  return { registrationId, tournamentPublicId } as const;
}

async function reviewRegistration(
  formData: FormData,
  decision: "approve" | "reject",
): Promise<RegistrationActionState> {
  const references = readReferences(formData);
  if ("error" in references) return { error: references.error };

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_review_tournament_registration",
    {
      p_registration_id: references.registrationId,
      p_decision: decision,
    },
  );

  if (error) {
    console.error("[Admin: review tournament registration]", {
      code: error.code,
      decision,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(
    `/admin/tournaments/${references.tournamentPublicId}`,
  );
  revalidatePath("/admin");
  revalidatePath("/");

  return {
    success:
      decision === "approve"
        ? "Registration approved. Assign its lobby and slot when ready."
        : "Registration rejected. Historical submission preserved.",
  };
}

export async function approveRegistration(
  _previousState: RegistrationActionState,
  formData: FormData,
) {
  return reviewRegistration(formData, "approve");
}

export async function rejectRegistration(
  _previousState: RegistrationActionState,
  formData: FormData,
) {
  return reviewRegistration(formData, "reject");
}

export async function reassignRegistrationSlot(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const references = readReferences(formData);
  if ("error" in references) return { error: references.error };

  const submittedSlot = readField(formData, "slot_number");
  const lobbyId = readField(formData, "lobby_id");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(lobbyId)) {
    return { error: "Select a valid tournament lobby." };
  }
  if (!/^\d+$/.test(submittedSlot)) {
    return { error: "Enter a valid whole-number slot." };
  }

  const slotNumber = Number(submittedSlot);
  if (!Number.isSafeInteger(slotNumber) || slotNumber < 1) {
    return { error: "Slot must be a positive whole number." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_reassign_tournament_slot",
    {
      p_registration_id: references.registrationId,
      p_lobby_id: lobbyId,
      p_slot_number: slotNumber,
    },
  );

  if (error) {
    console.error("[Admin: reassign tournament slot]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(
    `/admin/tournaments/${references.tournamentPublicId}`,
  );
  revalidatePath("/admin");
  revalidatePath("/");
  return { success: `Slot ${String(slotNumber).padStart(2, "0")} assigned.` };
}

export async function createTournamentLobby(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const submittedCapacity = readField(formData, "capacity");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }

  if (!/^\d+$/.test(submittedCapacity)) {
    return { error: "Enter a valid whole-number lobby capacity." };
  }

  const capacity = Number(submittedCapacity);
  if (!Number.isSafeInteger(capacity) || capacity < 1 || capacity > 100) {
    return { error: "Lobby capacity must be between 1 and 100." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_create_tournament_lobby_for_tournament",
    {
      p_tournament_code: tournamentPublicId,
      p_capacity: capacity,
    },
  );

  if (error) {
    console.error("[Admin: create tournament lobby]", {
      code: error.code,
      message: error.message,
      tournamentPublicId,
    });
    return { error: registrationError(error) };
  }

  const lobby = data as { display_label?: string } | null;
  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);

  return { success: `${lobby?.display_label ?? "Lobby"} created.` };
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function readSessionLobbyFields(formData: FormData) {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const sessionId = readField(formData, "session_id");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." } as const;
  }
  if (!uuidPattern.test(sessionId)) {
    return { error: "Select the session this lobby belongs to." } as const;
  }
  return { tournamentPublicId, sessionId } as const;
}

function readWholeNumber(formData: FormData, name: string) {
  const submitted = readField(formData, name);
  if (!/^\d+$/.test(submitted)) return null;
  const value = Number(submitted);
  return Number.isSafeInteger(value) ? value : null;
}

export async function createSessionLobby(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const references = readSessionLobbyFields(formData);
  if ("error" in references) return { error: references.error };

  const capacity = readWholeNumber(formData, "capacity");
  if (capacity === null || capacity < 1 || capacity > 100) {
    return { error: "Lobby capacity must be between 1 and 100." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_create_session_lobby",
    { p_session_id: references.sessionId, p_capacity: capacity },
  );

  if (error) {
    console.error("[Admin: create session lobby]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  const lobby = data as { display_label?: string } | null;
  revalidatePath(`/admin/tournaments/${references.tournamentPublicId}`);
  return { success: `${lobby?.display_label ?? "Lobby"} created.` };
}

export async function generateSessionLobbies(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const references = readSessionLobbyFields(formData);
  if ("error" in references) return { error: references.error };

  const teamsPerLobby = readWholeNumber(formData, "teams_per_lobby");
  const lobbyCount = readWholeNumber(formData, "lobby_count");
  if (
    teamsPerLobby === null ||
    teamsPerLobby < 1 ||
    teamsPerLobby > 100 ||
    lobbyCount === null ||
    lobbyCount < 1 ||
    lobbyCount > 26
  ) {
    return { error: "Enter teams per lobby (1-100) and lobby count (1-26)." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_generate_session_lobbies",
    {
      p_session_id: references.sessionId,
      p_teams_per_lobby: teamsPerLobby,
      p_lobby_count: lobbyCount,
    },
  );

  if (error) {
    console.error("[Admin: generate session lobbies]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  const created = Array.isArray(data) ? data.length : 0;
  revalidatePath(`/admin/tournaments/${references.tournamentPublicId}`);
  return {
    success: `${created} ${created === 1 ? "lobby" : "lobbies"} created (${teamsPerLobby} teams each).`,
  };
}

export async function renameTournamentLobby(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const lobbyId = readField(formData, "lobby_id");
  const label = readField(formData, "label");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }
  if (!uuidPattern.test(lobbyId)) {
    return { error: "Select a valid tournament lobby." };
  }
  if (label.length < 1 || label.length > 80) {
    return { error: "Lobby name must be between 1 and 80 characters." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_rename_tournament_lobby",
    { p_lobby_id: lobbyId, p_label: label },
  );

  if (error) {
    console.error("[Admin: rename tournament lobby]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  return { success: `Lobby renamed to "${label}".` };
}

export async function resizeTournamentLobby(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const lobbyId = readField(formData, "lobby_id");
  const capacity = readWholeNumber(formData, "capacity");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }
  if (!uuidPattern.test(lobbyId)) {
    return { error: "Select a valid tournament lobby." };
  }
  if (capacity === null || capacity < 1 || capacity > 100) {
    return { error: "Lobby capacity must be between 1 and 100." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_resize_tournament_lobby",
    { p_lobby_id: lobbyId, p_capacity: capacity },
  );

  if (error) {
    console.error("[Admin: resize tournament lobby]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  return { success: `Lobby capacity set to ${capacity}.` };
}

export async function deleteTournamentLobby(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const lobbyId = readField(formData, "lobby_id");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }
  if (!uuidPattern.test(lobbyId)) {
    return { error: "Select a valid tournament lobby." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_delete_tournament_lobby",
    { p_lobby_id: lobbyId },
  );

  if (error) {
    console.error("[Admin: delete tournament lobby]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  return { success: "Lobby deleted." };
}

async function reviewPayment(
  formData: FormData,
  decision: "verify" | "reject",
): Promise<RegistrationActionState> {
  const paymentId = readField(formData, "payment_id");
  const tournamentPublicId = readField(formData, "tournament_public_id").toUpperCase();

  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(paymentId)) {
    return { error: "Payment reference is invalid." };
  }
  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_review_tournament_payment",
    { p_payment_id: paymentId, p_decision: decision },
  );

  if (error) {
    console.error("[Admin: review tournament payment]", {
      code: error.code,
      decision,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  revalidatePath(`/tournaments/${tournamentPublicId}/register`);

  return {
    success: decision === "verify" ? "Payment verified." : "Payment rejected. Historical submission preserved.",
  };
}

export async function verifyTournamentPayment(
  _previousState: RegistrationActionState,
  formData: FormData,
) {
  return reviewPayment(formData, "verify");
}

export async function rejectTournamentPayment(
  _previousState: RegistrationActionState,
  formData: FormData,
) {
  return reviewPayment(formData, "reject");
}

async function reconcileCancelledPayment(
  formData: FormData,
  decision: "confirm" | "reject",
): Promise<RegistrationActionState> {
  const paymentId = readField(formData, "payment_id");
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();

  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(paymentId)) {
    return { error: "Payment reference is invalid." };
  }
  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_reconcile_cancelled_tournament_payment",
    {
      p_payment_id: paymentId,
      p_decision: decision,
    },
  );

  if (error) {
    console.error("[Admin: reconcile cancelled tournament payment]", {
      code: error.code,
      decision,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  revalidatePath(`/tournaments/${tournamentPublicId}/register`);
  revalidatePath("/team");

  return {
    success:
      decision === "confirm"
        ? "Payment confirmed and cancellation credit created."
        : "Payment rejected. Historical submission preserved.",
  };
}

export async function confirmCancelledTournamentPayment(
  _previousState: RegistrationActionState,
  formData: FormData,
) {
  return reconcileCancelledPayment(formData, "confirm");
}

export async function rejectCancelledTournamentPayment(
  _previousState: RegistrationActionState,
  formData: FormData,
) {
  return reconcileCancelledPayment(formData, "reject");
}

function isUuid(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function readTournamentSetupReferences(formData: FormData) {
  const tournamentId = readField(formData, "tournament_id");
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();

  if (!isUuid(tournamentId)) {
    return { error: "Tournament reference is invalid." } as const;
  }
  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament public reference is invalid." } as const;
  }

  return { tournamentId, tournamentPublicId } as const;
}

function parseSetupInteger(
  value: string,
  label: string,
  options: { allowEmpty?: boolean; min?: number; max?: number } = {},
) {
  if (!value && options.allowEmpty) return { value: null } as const;
  if (!/^\d+$/.test(value)) {
    return { error: `${label} must be a whole number.` } as const;
  }

  const number = Number(value);
  const minimum = options.min ?? 0;
  const maximum = options.max ?? 1_000_000;
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    return {
      error: `${label} must be between ${minimum} and ${maximum}.`,
    } as const;
  }

  return { value: number } as const;
}

function parseSetupMoney(value: string, currency: string, label: string) {
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
  const minor =
    Number(wholePart) * scale +
    Number(submittedFraction.padEnd(fractionDigits, "0") || "0");
  if (!Number.isSafeInteger(minor)) {
    return { error: `${label} is too large.` } as const;
  }

  return { value: minor } as const;
}

function setupError(error: { code?: string; message: string }) {
  if (error.code === "42501") {
    return "You no longer have permission to manage tournament setup.";
  }
  if (
    error.code === "22023" ||
    error.code === "22003" ||
    error.code === "23503" ||
    error.code === "23505" ||
    error.code?.startsWith("P4")
  ) {
    return error.message;
  }
  return "Tournament setup could not be updated. Please try again.";
}

function revalidateTournamentSetup(tournamentPublicId: string) {
  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  revalidatePath("/admin");
}

export async function createTournamentStage(
  _previousState: TournamentSetupActionState,
  formData: FormData,
): Promise<TournamentSetupActionState> {
  const references = readTournamentSetupReferences(formData);
  if ("error" in references) return { error: references.error };

  const stageNumber = parseSetupInteger(
    readField(formData, "stage_number"),
    "Stage number",
    { min: 1, max: 1000 },
  );
  if ("error" in stageNumber) return { error: stageNumber.error };

  const namePreset = readField(formData, "name_preset");
  const supportedPresets = new Set([
    "open_qualifier",
    "qualifier",
    "quarterfinal",
    "semifinal",
    "grand_final",
  ]);
  if (!supportedPresets.has(namePreset)) {
    return { error: "Choose a supported Stage name." };
  }

  const customName = readField(formData, "custom_name");
  if (customName.length > 100) {
    return { error: "Custom Stage name must be 100 characters or fewer." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_create_tournament_stage",
    {
      p_tournament_id: references.tournamentId,
      p_stage_number: stageNumber.value,
      p_name_preset: namePreset,
      p_custom_name: customName || null,
      p_configuration: {},
    },
  );

  if (error) {
    console.error("[Admin: create tournament Stage]", {
      code: error.code,
      message: error.message,
      tournamentPublicId: references.tournamentPublicId,
    });
    return { error: setupError(error) };
  }

  revalidateTournamentSetup(references.tournamentPublicId);
  const stage = data as { display_name?: string } | null;
  return {
    success: `${stage?.display_name ?? `Stage ${stageNumber.value}`} created. Configure it before creating Sessions.`,
  };
}

export async function configureTournamentStage(
  _previousState: TournamentSetupActionState,
  formData: FormData,
): Promise<TournamentSetupActionState> {
  const references = readTournamentSetupReferences(formData);
  if ("error" in references) return { error: references.error };

  const stageId = readField(formData, "stage_id");
  if (!isUuid(stageId)) return { error: "Stage reference is invalid." };

  const stageNumber = parseSetupInteger(
    readField(formData, "stage_number"),
    "Stage number",
    { min: 1, max: 1000 },
  );
  const matchesPerLobby = parseSetupInteger(
    readField(formData, "matches_per_lobby"),
    "Matches per lobby",
    { min: 1, max: 100 },
  );
  const advancementCount = parseSetupInteger(
    readField(formData, "advancement_count"),
    "Advancement count",
    { min: 0, max: 100 },
  );
  const plannedLobbyCount = parseSetupInteger(
    readField(formData, "planned_lobby_count"),
    "Planned lobby count",
    { allowEmpty: true, min: 1, max: 26 },
  );
  const concurrentLobbyCapacity = parseSetupInteger(
    readField(formData, "concurrent_lobby_capacity"),
    "Concurrent lobby template",
    { allowEmpty: true, min: 1, max: 26 },
  );

  if ("error" in stageNumber) return { error: stageNumber.error };
  if ("error" in matchesPerLobby) return { error: matchesPerLobby.error };
  if ("error" in advancementCount) return { error: advancementCount.error };
  if ("error" in plannedLobbyCount) return { error: plannedLobbyCount.error };
  if ("error" in concurrentLobbyCapacity) {
    return { error: concurrentLobbyCapacity.error };
  }

  if (
    plannedLobbyCount.value !== null &&
    concurrentLobbyCapacity.value !== null &&
    concurrentLobbyCapacity.value > plannedLobbyCount.value
  ) {
    return {
      error: "Concurrent lobbies cannot exceed the planned lobby count.",
    };
  }

  const currency = readField(formData, "fee_currency").toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) {
    return { error: "Stage currency must be a three-letter code such as PKR." };
  }
  const stageFee = parseSetupMoney(
    readField(formData, "stage_fee"),
    currency,
    "Stage fee template",
  );
  if ("error" in stageFee) return { error: stageFee.error };

  const namePreset = readField(formData, "name_preset");
  if (
    ![
      "open_qualifier",
      "qualifier",
      "quarterfinal",
      "semifinal",
      "grand_final",
    ].includes(namePreset)
  ) {
    return { error: "Choose a supported Stage name." };
  }
  const customName = readField(formData, "custom_name");
  if (customName.length > 100) {
    return { error: "Custom Stage name must be 100 characters or fewer." };
  }

  const retryAllowed = formData.get("retry_allowed") === "on";
  const knockoutEnabled = formData.get("knockout_enabled") === "on";
  if (retryAllowed && knockoutEnabled) {
    return { error: "Knockout Stages cannot allow paid retries." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc("levelledup_admin_configure_stage", {
    p_stage_id: stageId,
    p_patch: {
      name_preset: namePreset,
      custom_name: customName || null,
      stage_number: stageNumber.value,
      matches_per_lobby: matchesPerLobby.value,
      stage_fee_minor: stageFee.value,
      fee_currency: currency,
      retry_allowed: retryAllowed,
      knockout_enabled: knockoutEnabled,
      advancement_count: advancementCount.value,
      planned_lobby_count: plannedLobbyCount.value,
      concurrent_lobby_capacity: concurrentLobbyCapacity.value,
    },
    p_override_reason: readField(formData, "override_reason") || null,
  });

  if (error) {
    console.error("[Admin: configure tournament Stage]", {
      code: error.code,
      message: error.message,
      stageId,
    });
    return { error: setupError(error) };
  }

  revalidateTournamentSetup(references.tournamentPublicId);
  return { success: "Stage configuration saved and readiness recalculated." };
}

function parseSessionSchedule(formData: FormData) {
  const startInput = readField(formData, "scheduled_start_at");
  const endInput = readField(formData, "scheduled_end_at");
  const start = startInput ? tournamentDateTimeInputToUtc(startInput) : null;
  const end = endInput ? tournamentDateTimeInputToUtc(endInput) : null;

  if ((startInput && !start) || (endInput && !end)) {
    return { error: "Enter valid Session dates and times in PKT." } as const;
  }
  if (end && !start) {
    return { error: "Set a Session start before setting its end." } as const;
  }
  if (start && end && end < start) {
    return { error: "Session end cannot be before its start." } as const;
  }

  return { start, end } as const;
}

export async function createTournamentSession(
  _previousState: TournamentSetupActionState,
  formData: FormData,
): Promise<TournamentSetupActionState> {
  const references = readTournamentSetupReferences(formData);
  if ("error" in references) return { error: references.error };

  const stageId = readField(formData, "stage_id");
  if (!isUuid(stageId)) return { error: "Stage reference is invalid." };
  const displayName = readField(formData, "display_name");
  if (displayName.length < 2 || displayName.length > 120) {
    return { error: "Session name must be between 2 and 120 characters." };
  }
  const schedule = parseSessionSchedule(formData);
  if ("error" in schedule) return { error: schedule.error };

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_create_tournament_session",
    {
      p_stage_id: stageId,
      p_display_name: displayName,
      p_scheduled_start_at: schedule.start,
      p_scheduled_end_at: schedule.end,
    },
  );

  if (error) {
    console.error("[Admin: create tournament Session]", {
      code: error.code,
      message: error.message,
      stageId,
    });
    return { error: setupError(error) };
  }

  revalidateTournamentSetup(references.tournamentPublicId);
  const session = data as { display_name?: string } | null;
  return {
    success: `${session?.display_name ?? "Session"} created from the Stage templates.`,
  };
}

export async function configureTournamentSession(
  _previousState: TournamentSetupActionState,
  formData: FormData,
): Promise<TournamentSetupActionState> {
  const references = readTournamentSetupReferences(formData);
  if ("error" in references) return { error: references.error };
  const sessionId = readField(formData, "session_id");
  if (!isUuid(sessionId)) return { error: "Session reference is invalid." };

  const maxConcurrentLobbies = parseSetupInteger(
    readField(formData, "max_concurrent_lobbies"),
    "Maximum concurrent lobbies",
    { min: 1, max: 26 },
  );
  const defaultMatchesPerLobby = parseSetupInteger(
    readField(formData, "default_matches_per_lobby"),
    "Default matches per lobby",
    { min: 1, max: 100 },
  );
  if ("error" in maxConcurrentLobbies) {
    return { error: maxConcurrentLobbies.error };
  }
  if ("error" in defaultMatchesPerLobby) {
    return { error: defaultMatchesPerLobby.error };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc(
    "levelledup_admin_configure_tournament_session",
    {
      p_session_id: sessionId,
      p_max_concurrent_lobbies: maxConcurrentLobbies.value,
      p_default_matches_per_lobby: defaultMatchesPerLobby.value,
    },
  );

  if (error) {
    console.error("[Admin: configure tournament Session]", {
      code: error.code,
      message: error.message,
      sessionId,
    });
    return { error: setupError(error) };
  }

  revalidateTournamentSetup(references.tournamentPublicId);
  return { success: "Session runtime defaults saved and readiness recalculated." };
}

export async function setTournamentSessionPrice(
  _previousState: TournamentSetupActionState,
  formData: FormData,
): Promise<TournamentSetupActionState> {
  const references = readTournamentSetupReferences(formData);
  if ("error" in references) return { error: references.error };
  const sessionId = readField(formData, "session_id");
  if (!isUuid(sessionId)) return { error: "Session reference is invalid." };

  const currency = readField(formData, "fee_currency").toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) {
    return { error: "Session currency must be a three-letter code such as PKR." };
  }
  const entryFee = parseSetupMoney(
    readField(formData, "entry_fee"),
    currency,
    "Session entry fee",
  );
  if ("error" in entryFee) return { error: entryFee.error };

  const reason = readField(formData, "reason");
  if (reason.length < 10 || reason.length > 1000) {
    return { error: "Price change reason must be between 10 and 1,000 characters." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc("levelledup_admin_set_session_price", {
    p_session_id: sessionId,
    p_entry_fee_minor: entryFee.value,
    p_fee_currency: currency,
    p_reason: reason,
    p_request_id: crypto.randomUUID(),
  });

  if (error) {
    console.error("[Admin: set authoritative Session price]", {
      code: error.code,
      message: error.message,
      sessionId,
    });
    return { error: setupError(error) };
  }

  revalidateTournamentSetup(references.tournamentPublicId);
  return { success: "Authoritative Session price updated and audited." };
}

// ---------------------------------------------------------------------------
// Match results: generate matches, enter team results, player data, finalize
// ---------------------------------------------------------------------------

export type MatchPlayerInput = {
  profileId?: string | null;
  playerName: string;
  pubgUid?: string | null;
  kills: number;
  damageDealt?: number;
};

export type MatchResultDetail = {
  resultId: string;
  registrationId: string;
  teamName: string;
  teamCode: string;
  placement: number | null;
  kills: number | null;
  placementPoints: number | null;
  killPoints: number | null;
  totalPoints: number | null;
  didNotPlay: boolean;
  status: "draft" | "final";
  players: Array<{
    id: string;
    profileId: string | null;
    playerName: string;
    pubgUid: string | null;
    kills: number;
    damageDealt: number;
  }>;
};

function readMatchFields(formData: FormData) {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const matchId = readField(formData, "match_id");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." } as const;
  }
  if (!uuidPattern.test(matchId)) {
    return { error: "Select a match first." } as const;
  }
  return { tournamentPublicId, matchId } as const;
}

export async function generateLobbyMatches(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const lobbyId = readField(formData, "lobby_id");
  const mapRotationRaw = readField(formData, "map_rotation");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }
  if (!uuidPattern.test(lobbyId)) {
    return { error: "Select a lobby first." };
  }

  const mapRotation = mapRotationRaw
    .split(",")
    .map((code) => code.trim().toLowerCase())
    .filter(Boolean);
  if (mapRotationRaw && mapRotation.length === 0) {
    return { error: "Map rotation must list at least one map code." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_generate_lobby_matches",
    {
      p_lobby_id: lobbyId,
      p_map_rotation: mapRotation.length ? mapRotation : null,
    },
  );

  if (error) {
    console.error("[Admin: generate lobby matches]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  const created = typeof data === "number" ? data : 0;
  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  return {
    success:
      created === 0
        ? "Matches already exist for this lobby."
        : `${created} ${created === 1 ? "match" : "matches"} created for this lobby.`,
  };
}

type ResultEntry = {
  registrationId: string;
  placement: number | null;
  kills: number | null;
  didNotPlay: boolean;
};

function readResultEntries(formData: FormData): ResultEntry[] | { error: string } {
  const raw = readField(formData, "results_json");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { error: "Results could not be read. Please try again." };
  }
  if (!Array.isArray(parsed) || parsed.length === 0) {
    return { error: "Enter at least one team result." };
  }
  const entries: ResultEntry[] = [];
  for (const item of parsed) {
    const row = item as Record<string, unknown>;
    const registrationId =
      typeof row.registrationId === "string" ? row.registrationId : "";
    const didNotPlay = row.did_not_play === true;
    if (!uuidPattern.test(registrationId)) {
      return { error: "One of the teams is invalid. Please re-check the list." };
    }
    if (didNotPlay) {
      entries.push({ registrationId, placement: null, kills: null, didNotPlay: true });
      continue;
    }
    const placement = Number(row.placement);
    const kills = Number(row.kills);
    if (!Number.isInteger(placement) || placement < 1) {
      return { error: "Placement must be a whole number of at least 1." };
    }
    if (!Number.isInteger(kills) || kills < 0) {
      return { error: "Kills must be a whole number of 0 or more." };
    }
    entries.push({ registrationId, placement, kills, didNotPlay: false });
  }
  const placements = entries
    .filter((entry) => !entry.didNotPlay)
    .map((entry) => entry.placement);
  if (new Set(placements).size !== placements.length) {
    return { error: "Two teams share the same placement. Fix the duplicates." };
  }
  return entries;
}

export async function saveMatchResults(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const references = readMatchFields(formData);
  if ("error" in references) return { error: references.error };

  const entries = readResultEntries(formData);
  if ("error" in entries) return { error: entries.error };

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_upsert_match_results",
    {
      p_match_id: references.matchId,
      p_results: entries.map((entry) => ({
        registration_id: entry.registrationId,
        placement: entry.placement,
        kills: entry.kills,
        did_not_play: entry.didNotPlay,
      })),
    },
  );

  if (error) {
    console.error("[Admin: save match results]", {
      code: error.code,
      message: error.message,
    });
    if (error.code === "22023" && error.message.includes("not assigned")) {
      return {
        error:
          "One of those teams is not assigned to this match's lobby, so the result was rejected.",
      };
    }
    return { error: registrationError(error) };
  }

  const saved = typeof data === "number" ? data : entries.length;
  revalidatePath(`/admin/tournaments/${references.tournamentPublicId}`);
  return {
    success: `${saved} team ${saved === 1 ? "result" : "results"} saved as draft. Finalize each one when checked.`,
  };
}

export async function finalizeMatchResult(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const resultId = readField(formData, "result_id");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }
  if (!uuidPattern.test(resultId)) {
    return { error: "Select a result to finalize." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc("levelledup_admin_finalize_match_result", {
    p_match_result_id: resultId,
  });

  if (error) {
    console.error("[Admin: finalize match result]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  return { success: "Result finalized." };
}

export async function completeMatch(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const references = readMatchFields(formData);
  if ("error" in references) return { error: references.error };

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { error } = await supabase.rpc("levelledup_admin_complete_match", {
    p_match_id: references.matchId,
  });

  if (error) {
    console.error("[Admin: complete match]", {
      code: error.code,
      message: error.message,
    });
    if (error.code === "P4210") {
      return {
        error:
          "Finalize every draft result before completing the match.",
      };
    }
    return { error: registrationError(error) };
  }

  revalidatePath(`/admin/tournaments/${references.tournamentPublicId}`);
  return { success: "Match completed." };
}

export async function saveMatchPlayerResults(
  _previousState: RegistrationActionState,
  formData: FormData,
): Promise<RegistrationActionState> {
  const tournamentPublicId = readField(
    formData,
    "tournament_public_id",
  ).toUpperCase();
  const resultId = readField(formData, "result_id");

  if (!/^LU-T-[A-HJ-NP-Z2-9]{8}$/.test(tournamentPublicId)) {
    return { error: "Tournament reference is invalid." };
  }
  if (!uuidPattern.test(resultId)) {
    return { error: "Select a team result first." };
  }

  const raw = readField(formData, "players_json");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { error: "Player data could not be read. Please try again." };
  }
  if (!Array.isArray(parsed)) {
    return { error: "Player data could not be read. Please try again." };
  }

  const players: MatchPlayerInput[] = [];
  for (const item of parsed) {
    const row = item as Record<string, unknown>;
    const playerName =
      typeof row.playerName === "string" ? row.playerName.trim() : "";
    if (!playerName) {
      return { error: "Every player row needs a name." };
    }
    const kills = Number(row.kills);
    const damageDealt = Number(row.damageDealt ?? 0);
    if (!Number.isInteger(kills) || kills < 0) {
      return { error: `Kills for ${playerName} must be 0 or more.` };
    }
    if (!Number.isInteger(damageDealt) || damageDealt < 0) {
      return { error: `Damage for ${playerName} must be 0 or more.` };
    }
    const profileId =
      typeof row.profileId === "string" && row.profileId ? row.profileId : null;
    if (profileId && !uuidPattern.test(profileId)) {
      return { error: `Player link for ${playerName} is invalid.` };
    }
    players.push({
      profileId,
      playerName,
      pubgUid:
        typeof row.pubgUid === "string" && row.pubgUid.trim()
          ? row.pubgUid.trim()
          : null,
      kills,
      damageDealt,
    });
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_upsert_match_player_results",
    {
      p_match_result_id: resultId,
      p_players: players.map((player) => ({
        profile_id: player.profileId,
        player_name: player.playerName,
        pubg_uid: player.pubgUid,
        kills: player.kills,
        damage_dealt: player.damageDealt ?? 0,
      })),
    },
  );

  if (error) {
    console.error("[Admin: save match player results]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  const saved = typeof data === "number" ? data : players.length;
  revalidatePath(`/admin/tournaments/${tournamentPublicId}`);
  return {
    success:
      saved === 0
        ? "Player data cleared for this result."
        : `Player data saved (${saved} ${saved === 1 ? "player" : "players"}).`,
  };
}

export async function getMatchResultDetails(
  matchId: string,
): Promise<{ results?: MatchResultDetail[]; error?: string }> {
  if (!uuidPattern.test(matchId)) {
    return { error: "Select a match first." };
  }

  const supabase = await adminClient();
  if (!supabase) return { error: "Admin authorization is required." };

  const { data, error } = await supabase.rpc(
    "levelledup_admin_get_match_results",
    { p_match_id: matchId },
  );

  if (error) {
    console.error("[Admin: load match results]", {
      code: error.code,
      message: error.message,
    });
    return { error: "Match results could not be loaded." };
  }

  const rows = (Array.isArray(data) ? data : []) as Array<{
    result_id: string;
    registration_id: string;
    team_name: string;
    team_code: string;
    placement: number | null;
    kills: number | null;
    placement_points: number | null;
    kill_points: number | null;
    total_points: number | null;
    did_not_play: boolean;
    status: string;
    players: Array<{
      id: string;
      profile_id: string | null;
      player_name: string;
      pubg_uid: string | null;
      kills: number;
      damage_dealt: number;
    }>;
  }>;

  return {
    results: rows.map((row) => ({
      resultId: row.result_id,
      registrationId: row.registration_id,
      teamName: row.team_name,
      teamCode: row.team_code,
      placement: row.placement,
      kills: row.kills,
      placementPoints: row.placement_points,
      killPoints: row.kill_points,
      totalPoints: row.total_points,
      didNotPlay: row.did_not_play === true,
      status: row.status === "final" ? "final" : "draft",
      players: (row.players ?? []).map((player) => ({
        id: player.id,
        profileId: player.profile_id,
        playerName: player.player_name,
        pubgUid: player.pubg_uid,
        kills: player.kills,
        damageDealt: player.damage_dealt,
      })),
    })),
  };
}
