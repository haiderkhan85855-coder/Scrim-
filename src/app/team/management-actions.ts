"use server";

import { revalidatePath } from "next/cache";

import { createClient } from "@/lib/supabase/server";

export type TeamMutationActionState = {
  error?: string;
  success?: string;
};

type RpcFailure = {
  code: string;
  message: string;
};

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function readField(formData: FormData, name: string) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

async function callTeamRpc(
  functionName: string,
  parameters: Record<string, unknown>,
): Promise<RpcFailure | null> {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return {
      code: "AUTH_REQUIRED",
      message: "Your session has expired. Sign in again to continue.",
    };
  }

  const { data, error } = await supabase.rpc(functionName, parameters);

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error(`[Supabase Teams: ${functionName}]`, {
        code: error.code,
        message: error.message,
        userReference: user.id.slice(-6),
      });
    }

    return { code: error.code, message: error.message };
  }

  if (data !== true) {
    return {
      code: "RPC_FAILED",
      message: "The team operation did not complete.",
    };
  }

  return null;
}

async function callTeamRpcWithData<T>(
  functionName: string,
  parameters: Record<string, unknown>,
): Promise<{ data: T } | { error: RpcFailure }> {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return {
      error: {
        code: "AUTH_REQUIRED",
        message: "Your session has expired. Sign in again to continue.",
      },
    };
  }

  const { data, error } = await supabase.rpc(functionName, parameters);

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error(`[Supabase Teams: ${functionName}]`, {
        code: error.code,
        message: error.message,
        userReference: user.id.slice(-6),
      });
    }

    return { error: { code: error.code, message: error.message } };
  }

  return { data: data as T };
}

function mutationErrorMessage(error: RpcFailure, fallback: string) {
  switch (error.code) {
    case "AUTH_REQUIRED":
      return error.message;
    case "P3001":
      return "Maximum of 3 teams reached.";
    case "P3002":
      return "This player already belongs to the team.";
    case "P3005":
      return "This join request is no longer pending.";
    case "P3006":
      return "The player must complete their profile before joining.";
    case "P3010":
      return "Captains must transfer leadership or disband the team before leaving.";
    case "P3011":
      return "That active Squad membership could not be found.";
    case "P3012":
      return "Captain membership cannot be changed with this action.";
    case "P3020":
      return "This team is no longer active.";
    case "P3021":
      return "Captaincy can only be transferred to an active claimed Player or Co-Captain.";
    case "P3022":
      return "The Team ID confirmation does not match.";
    case "P3031":
      return "Create a recruitment post before changing its status.";
    case "P3032":
      return "Players in an active tournament Squad cannot leave the team. Ask the Captain to remove you.";
    case "P3033":
      return "A disband request is already pending for this team.";
    case "P3034":
      return "The disband request is no longer pending or has expired.";
    case "P3035":
      return "Only active Squad members other than the requesting captain can approve.";
    case "P3036":
      return "You have already approved this disband request.";
    case "42501":
      return "You do not have permission to perform this action.";
    case "P3004":
      return "That team could not be found.";
    case "22023":
      return error.message || fallback;
    default:
      return fallback;
  }
}

export async function saveRecruitmentPost(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const teamId = readField(formData, "team_id");
  const captainNote = readField(formData, "captain_note");
  const micRequired = formData.get("mic_required") === "on";
  const isExistingPost = readField(formData, "post_state") === "existing";

  if (!uuidPattern.test(teamId)) {
    return { error: "Invalid team." };
  }

  if (captainNote.length > 500) {
    return { error: "Captain note must be 500 characters or fewer." };
  }

  const error = await callTeamRpc("levelledup_save_team_recruitment", {
    p_team_id: teamId,
    p_mic_required: micRequired,
    p_captain_note: captainNote || null,
  });

  if (error) {
    return {
      error: mutationErrorMessage(
        error,
        "Recruitment settings could not be saved.",
      ),
    };
  }

  revalidatePath("/team");
  revalidatePath("/find-team");
  return {
    success: isExistingPost ? "Recruitment updated" : "Recruitment posted",
  };
}

export async function setRecruitmentStatus(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const teamId = readField(formData, "team_id");
  const status = readField(formData, "status");

  if (!uuidPattern.test(teamId)) {
    return { error: "Invalid team." };
  }

  if (status !== "open" && status !== "closed") {
    return { error: "Invalid recruitment status." };
  }

  const error = await callTeamRpc(
    "levelledup_set_team_recruitment_status",
    { p_team_id: teamId, p_status: status },
  );

  if (error) {
    return {
      error: mutationErrorMessage(
        error,
        "Recruitment status could not be changed.",
      ),
    };
  }

  revalidatePath("/team");
  revalidatePath("/find-team");
  return {
    success: status === "open" ? "Recruitment reopened" : "Recruitment closed",
  };
}

export async function approveJoinRequest(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const requestId = readField(formData, "request_id");

  if (!uuidPattern.test(requestId)) {
    return { error: "Invalid join request." };
  }

  const error = await callTeamRpc(
    "levelledup_approve_team_join_request",
    { p_request_id: requestId, p_role: "player" },
  );

  if (error) {
    return {
      error: mutationErrorMessage(error, "The join request could not be approved."),
    };
  }

  revalidatePath("/team");
  return { success: "Player added to the Squad." };
}

export async function rejectJoinRequest(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const requestId = readField(formData, "request_id");

  if (!uuidPattern.test(requestId)) {
    return { error: "Invalid join request." };
  }

  const error = await callTeamRpc(
    "levelledup_reject_team_join_request",
    { p_request_id: requestId },
  );

  if (error) {
    return {
      error: mutationErrorMessage(error, "The join request could not be rejected."),
    };
  }

  revalidatePath("/team");
  return { success: "Join request rejected." };
}

export async function changeRosterRole(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const rosterMemberId = readField(formData, "roster_member_id");
  const role = readField(formData, "role");

  if (!uuidPattern.test(rosterMemberId)) {
    return { error: "Invalid Squad member." };
  }

  if (role !== "player" && role !== "co_captain") {
    return { error: "Role must be Player or Co-Captain." };
  }

  const error = await callTeamRpc("levelledup_set_team_member_role", {
    p_roster_member_id: rosterMemberId,
    p_role: role,
  });

  if (error) {
    return {
      error: mutationErrorMessage(error, "The Squad role could not be updated."),
    };
  }

  revalidatePath("/team");
  return { success: "Squad role updated." };
}

export async function requestTeamLeave(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const teamId = readField(formData, "team_id");

  if (!uuidPattern.test(teamId)) {
    return { error: "Invalid team." };
  }

  const result = await callTeamRpcWithData<string>("levelledup_request_team_leave", {
    p_team_id: teamId,
  });

  if ("error" in result) {
    if (result.error.code === "P3013") {
      return { error: "You already have a pending leave request for this team." };
    }
    return {
      error: mutationErrorMessage(result.error, "The leave request could not be sent."),
    };
  }

  revalidatePath("/team");
  return { success: "Leave request sent to your captain for approval." };
}

export async function decideLeaveRequest(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const requestId = readField(formData, "request_id");
  const decision = readField(formData, "decision");

  if (!uuidPattern.test(requestId) || (decision !== "approve" && decision !== "reject")) {
    return { error: "Invalid leave request decision." };
  }

  const error = await callTeamRpc("levelledup_decide_team_leave", {
    p_request_id: requestId,
    p_approve: decision === "approve",
  });

  if (error) {
    return {
      error: mutationErrorMessage(error, "The leave request could not be decided."),
    };
  }

  revalidatePath("/team");
  return {
    success:
      decision === "approve"
        ? "Leave request approved. The member has been removed."
        : "Leave request rejected.",
  };
}

export async function sendSupportMessage(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const teamId = readField(formData, "team_id");
  const message = readField(formData, "message");

  if (!uuidPattern.test(teamId)) {
    return { error: "Invalid team." };
  }

  if (message.length < 1 || message.length > 2000) {
    return { error: "The message must be between 1 and 2000 characters." };
  }

  const result = await callTeamRpcWithData<string>("levelledup_send_support_message", {
    p_team_id: teamId,
    p_message: message,
  });

  if ("error" in result) {
    return {
      error: mutationErrorMessage(result.error, "The message could not be sent."),
    };
  }

  revalidatePath("/team");
  return { success: "Message sent to the admin. They will review it shortly." };
}

export async function removeRosterMember(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const rosterMemberId = readField(formData, "roster_member_id");

  if (!uuidPattern.test(rosterMemberId)) {
    return { error: "Invalid Squad member." };
  }

  const error = await callTeamRpc("levelledup_remove_team_member", {
    p_roster_member_id: rosterMemberId,
  });

  if (error) {
    return {
      error: mutationErrorMessage(error, "The Squad member could not be removed."),
    };
  }

  revalidatePath("/team");
  return { success: "Squad member removed." };
}

export async function transferCaptaincy(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const teamId = readField(formData, "team_id");
  const targetRosterMemberId = readField(
    formData,
    "target_roster_member_id",
  );

  if (!uuidPattern.test(teamId) || !uuidPattern.test(targetRosterMemberId)) {
    return { error: "Invalid captaincy transfer." };
  }

  const error = await callTeamRpc("levelledup_transfer_team_captaincy", {
    p_team_id: teamId,
    p_target_roster_member_id: targetRosterMemberId,
  });

  if (error) {
    return {
      error: mutationErrorMessage(error, "Captaincy could not be transferred."),
    };
  }

  revalidatePath("/team");
  return { success: "Captaincy transferred." };
}

export async function renameTeam(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const teamId = readField(formData, "team_id");
  const newName = readField(formData, "new_name");

  if (!uuidPattern.test(teamId)) {
    return { error: "Select a team to rename." };
  }

  if (newName.length < 2 || newName.length > 80) {
    return { error: "Team name must be between 2 and 80 characters." };
  }

  const result = await callTeamRpcWithData<string>("levelledup_rename_team", {
    p_team_id: teamId,
    p_new_name: newName,
  });

  if ("error" in result) {
    return {
      error: mutationErrorMessage(
        result.error,
        "The team could not be renamed.",
      ),
    };
  }

  revalidatePath("/team");
  return {
    success: `Team renamed to "${result.data}". The old name is preserved in history.`,
  };
}

export async function disbandTeam(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const teamId = readField(formData, "team_id");
  const confirmationTeamId = readField(
    formData,
    "confirmation_team_id",
  ).toUpperCase();

  if (!uuidPattern.test(teamId) || !confirmationTeamId) {
    return { error: "Enter the permanent Team ID to request disbanding." };
  }

  const result = await callTeamRpcWithData<string>("levelledup_request_team_disband", {
    p_team_id: teamId,
    p_confirmation_team_id: confirmationTeamId,
  });

  if ("error" in result) {
    return { error: mutationErrorMessage(result.error, "The disband request could not be created.") };
  }

  revalidatePath("/team");
  return { success: "Disband requested. Two Squad members must approve within 48 hours." };
}

export async function approveTeamDisband(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const requestId = readField(formData, "request_id");

  if (!uuidPattern.test(requestId)) {
    return { error: "Invalid disband request." };
  }

  const result = await callTeamRpcWithData<boolean>("levelledup_approve_team_disband", {
    p_request_id: requestId,
  });

  if ("error" in result) {
    return { error: mutationErrorMessage(result.error, "The disband request could not be approved.") };
  }

  revalidatePath("/team");
  return result.data
    ? { success: "Approved. The team has been disbanded and archived." }
    : { success: "Approval recorded. Waiting for one more Squad member." };
}

export async function cancelTeamDisband(
  _previousState: TeamMutationActionState,
  formData: FormData,
): Promise<TeamMutationActionState> {
  const requestId = readField(formData, "request_id");

  if (!uuidPattern.test(requestId)) {
    return { error: "Invalid disband request." };
  }

  const error = await callTeamRpc("levelledup_cancel_team_disband", {
    p_request_id: requestId,
  });

  if (error) {
    return { error: mutationErrorMessage(error, "The disband request could not be cancelled.") };
  }

  revalidatePath("/team");
  return { success: "Disband request cancelled." };
}
