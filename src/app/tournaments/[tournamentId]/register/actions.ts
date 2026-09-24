"use server";

import { revalidatePath } from "next/cache";

import { createClient } from "@/lib/supabase/server";

export type RegistrationFlowActionState = {
  error?: string;
  success?: string;
};

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const tournamentIdPattern = /^LU-T-[A-HJ-NP-Z2-9]{8}$/;

function readField(formData: FormData, name: string) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function registrationError(error: { code?: string; message: string }) {
  if (error.code === "42501") return error.message;
  if (error.code === "P4503") {
    return "Finalize the pending tournament Squad before submitting payment.";
  }

  if (
    error.code &&
    [
      "P4001",
      "P4002",
      "P4004",
      "P4005",
      "P4010",
      "P4011",
      "P4012",
      "P4013",
      "P4014",
      "P4015",
      "P4016",
      "P4017",
      "P4501",
      "P4502",
      "P4503",
      "P4504",
      "P4505",
      "P4520",
      "P4521",
      "23505",
    ].includes(error.code)
  ) {
    return error.code === "23505"
      ? "This team already has an active tournament registration."
      : error.message;
  }

  return "The registration could not be updated. Please try again.";
}

function sessionSelectionError(error: { code?: string; message: string }) {
  if (
    error.code &&
    ["42501", "P4420", "P4421", "P4422", "23503", "22023"].includes(error.code)
  ) {
    return error.message;
  }

  return "The initial Session could not be selected. Please try again.";
}

async function authenticatedTournament(
  formData: FormData,
): Promise<
  | { supabase: Awaited<ReturnType<typeof createClient>>; tournamentId: string; publicId: string }
  | { error: string }
> {
  const publicId = readField(formData, "tournament_public_id").toUpperCase();

  if (!tournamentIdPattern.test(publicId)) {
    return { error: "Tournament reference is invalid." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { error: "Authentication is required." };

  const { data, error } = await supabase
    .from("tournaments")
    .select("id")
    .eq("tournament_id", publicId)
    .maybeSingle();

  if (error || !data) return { error: "Tournament not found." };

  return {
    supabase,
    tournamentId: (data as { id: string }).id,
    publicId,
  };
}

export async function beginTournamentRegistration(
  _previousState: RegistrationFlowActionState,
  formData: FormData,
): Promise<RegistrationFlowActionState> {
  const teamId = readField(formData, "team_id");
  if (!uuidPattern.test(teamId)) return { error: "Select an active team." };

  const context = await authenticatedTournament(formData);
  if ("error" in context) return { error: context.error };

  const { error } = await context.supabase.rpc(
    "levelledup_register_team_for_tournament",
    {
      p_tournament_id: context.tournamentId,
      p_team_id: teamId,
    },
  );

  if (error) {
    console.error("[Tournament registration: begin]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/tournaments/${context.publicId}/register`);
  revalidatePath("/");
  revalidatePath("/admin");
  revalidatePath(`/admin/tournaments/${context.publicId}`);

  return { success: "Registration created. Complete the tournament Squad before the lock deadline." };
}

export async function finalizeTournamentRoster(
  _previousState: RegistrationFlowActionState,
  formData: FormData,
): Promise<RegistrationFlowActionState> {
  const registrationId = readField(formData, "registration_id");
  const rosterMemberIds = formData
    .getAll("roster_member_ids")
    .filter((value): value is string => typeof value === "string")
    .map((value) => value.trim());

  if (!uuidPattern.test(registrationId)) {
    return { error: "Tournament registration reference is invalid." };
  }

  if (!rosterMemberIds.length || rosterMemberIds.some((id) => !uuidPattern.test(id))) {
    return { error: "Select between 1 and 6 eligible tournament players." };
  }

  if (rosterMemberIds.length > 6) {
    return { error: "A tournament Squad may contain a maximum of 6 players." };
  }

  if (new Set(rosterMemberIds).size !== rosterMemberIds.length) {
    return { error: "The tournament Squad contains duplicate selections." };
  }

  const context = await authenticatedTournament(formData);
  if ("error" in context) return { error: context.error };

  const { error } = await context.supabase.rpc(
    "levelledup_finalize_tournament_roster",
    {
      p_registration_id: registrationId,
      p_roster_member_ids: rosterMemberIds,
    },
  );

  if (error) {
    console.error("[Tournament registration: finalize roster]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/tournaments/${context.publicId}/register`);
  revalidatePath("/admin");
  revalidatePath(`/admin/tournaments/${context.publicId}`);

  return { success: "Tournament Squad finalized." };
}

export async function selectRegistrationInitialSession(
  _previousState: RegistrationFlowActionState,
  formData: FormData,
): Promise<RegistrationFlowActionState> {
  const registrationId = readField(formData, "registration_id");
  const sessionId = readField(formData, "session_id");

  if (!uuidPattern.test(registrationId)) {
    return { error: "Tournament registration reference is invalid." };
  }

  if (!uuidPattern.test(sessionId)) {
    return { error: "Select an available Stage 1 Session." };
  }

  const context = await authenticatedTournament(formData);
  if ("error" in context) return { error: context.error };

  const { error } = await context.supabase.rpc(
    "levelledup_select_registration_initial_session",
    {
      p_registration_id: registrationId,
      p_session_id: sessionId,
    },
  );

  if (error) {
    console.error("[Tournament registration: initial Session]", {
      code: error.code,
      message: error.message,
    });
    return { error: sessionSelectionError(error) };
  }

  revalidatePath(`/tournaments/${context.publicId}/register`);
  revalidatePath(`/admin/tournaments/${context.publicId}`);

  return { success: "Initial Session selected." };
}

export async function submitManualTournamentPayment(
  _previousState: RegistrationFlowActionState,
  formData: FormData,
): Promise<RegistrationFlowActionState> {
  const registrationId = readField(formData, "registration_id");
  const referenceId = readField(formData, "reference_id");

  if (!uuidPattern.test(registrationId)) {
    return { error: "Tournament registration reference is invalid." };
  }

  if (referenceId.length < 3 || referenceId.length > 120) {
    return { error: "Enter a valid transaction or reference ID." };
  }

  const context = await authenticatedTournament(formData);
  if ("error" in context) return { error: context.error };

  const { error } = await context.supabase.rpc(
    "levelledup_submit_manual_tournament_payment",
    {
      p_registration_id: registrationId,
      p_reference_id: referenceId,
    },
  );

  if (error) {
    console.error("[Tournament registration: manual payment]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/tournaments/${context.publicId}/register`);
  revalidatePath(`/admin/tournaments/${context.publicId}`);

  return { success: "Payment submitted for verification." };
}

export async function withdrawTournamentRegistration(
  _previousState: RegistrationFlowActionState,
  formData: FormData,
): Promise<RegistrationFlowActionState> {
  const registrationId = readField(formData, "registration_id");

  if (!uuidPattern.test(registrationId)) {
    return { error: "Tournament registration reference is invalid." };
  }

  const context = await authenticatedTournament(formData);
  if ("error" in context) return { error: context.error };

  const { error } = await context.supabase.rpc(
    "levelledup_withdraw_tournament_registration",
    { p_registration_id: registrationId },
  );

  if (error) {
    console.error("[Tournament registration: withdraw]", {
      code: error.code,
      message: error.message,
    });
    return { error: registrationError(error) };
  }

  revalidatePath(`/tournaments/${context.publicId}/register`);
  revalidatePath("/team");
  revalidatePath("/account");
  revalidatePath("/admin");
  revalidatePath(`/admin/tournaments/${context.publicId}`);

  return { success: "Tournament registration withdrawn." };
}
