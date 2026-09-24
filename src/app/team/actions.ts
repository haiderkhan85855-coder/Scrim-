"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";

export type CreateTeamActionState = {
  error?: string;
  profileRequired?: boolean;
};

export type LookupTeamActionState = {
  error?: string;
  status?: "found" | "not_found";
  teamId?: string;
};

export type JoinTeamActionState = {
  error?: string;
  success?: boolean;
};

function readField(formData: FormData, name: string) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function lookupTeam(
  _previousState: LookupTeamActionState,
  formData: FormData,
): Promise<LookupTeamActionState> {
  const teamId = readField(formData, "team_id").toUpperCase();

  if (!teamId) {
    return {
      error: "Enter a LevelledUp Team ID.",
      status: "not_found",
    };
  }

  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return { error: "Your session has expired. Sign in again to continue." };
  }

  const { data: teamExists, error } = await supabase.rpc(
    "levelledup_lookup_team_id",
    { p_team_id: teamId },
  );

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Supabase Teams: Team ID lookup RPC]", {
        code: error.code,
        message: error.message,
        userReference: user.id.slice(-6),
      });
    }

    return { error: "We could not check that Team ID. Please try again." };
  }

  if (teamExists !== true) {
    return {
      error: "Team not found. Check the Team ID and try again.",
      status: "not_found",
    };
  }

  return { status: "found", teamId };
}

export async function requestTeamJoin(
  _previousState: JoinTeamActionState,
  formData: FormData,
): Promise<JoinTeamActionState> {
  const teamId = readField(formData, "team_id").toUpperCase();

  if (!teamId) {
    return { error: "Validate a LevelledUp Team ID before joining." };
  }

  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return { error: "Your session has expired. Sign in again to continue." };
  }

  const { data: requestCreated, error } = await supabase.rpc(
    "levelledup_request_team_join",
    { p_team_id: teamId },
  );

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Supabase Teams: join request RPC]", {
        code: error.code,
        message: error.message,
        userReference: user.id.slice(-6),
      });
    }

    if (error.code === "P3001") {
      return { error: "Maximum of 3 teams reached." };
    }

    if (error.code === "P3002") {
      return { error: "You already belong to this team." };
    }

    if (error.code === "P3003") {
      return { error: "A join request is already pending for this team." };
    }

    if (error.code === "P3004") {
      return { error: "Team not found. Check the Team ID and try again." };
    }

    if (error.code === "P3006") {
      return {
        error:
          "Complete your Display Name and PUBG UID before requesting to join a team.",
      };
    }

    if (error.code === "P3020") {
      return { error: "This team is no longer active." };
    }

    return { error: "We could not send the join request. Please try again." };
  }

  if (requestCreated !== true) {
    return { error: "We could not send the join request. Please try again." };
  }

  return { success: true };
}

export async function createTeam(
  _previousState: CreateTeamActionState,
  formData: FormData,
): Promise<CreateTeamActionState> {
  const name = readField(formData, "name");
  const shortName = readField(formData, "short_name");

  if (name.length < 2 || name.length > 80) {
    return { error: "Team name must be between 2 and 80 characters." };
  }

  if (shortName && (shortName.length < 2 || shortName.length > 12)) {
    return { error: "Short name must be between 2 and 12 characters." };
  }

  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return { error: "Your session has expired. Sign in again to continue." };
  }

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("display_name, pubg_ign, pubg_uid")
    .eq("id", user.id)
    .maybeSingle();

  if (profileError) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Supabase Teams: creator profile read]", {
        code: profileError.code,
        message: profileError.message,
        userReference: user.id.slice(-6),
      });
    }

    return { error: "We could not verify your player profile." };
  }

  const hasCompleteProfile = Boolean(
    profile?.display_name?.trim() &&
      profile.pubg_uid?.trim(),
  );

  if (!hasCompleteProfile) {
    return {
      error:
        "Complete your Display Name and PUBG UID before creating a team.",
      profileRequired: true,
    };
  }

  const { error } = await supabase.rpc("levelledup_create_team", {
    p_name: name,
    p_short_name: shortName || null,
    p_logo_url: null,
  });

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Supabase Teams: create RPC]", {
        code: error.code,
        message: error.message,
        userReference: user.id.slice(-6),
      });
    }

    if (
      error.code === "22023" &&
      error.message.toLowerCase().includes("complete")
    ) {
      return {
        error:
          "Complete your Display Name and PUBG UID before creating a team.",
        profileRequired: true,
      };
    }

    if (error.code === "55000") {
      return {
        error: "A Team ID could not be allocated. Please try again.",
      };
    }

    if (error.code === "P3001") {
      return { error: "Maximum of 3 teams reached." };
    }

    return { error: "We could not create your team. Please try again." };
  }

  revalidatePath("/team");
  redirect("/team");
}

export type TeamNameSearchResult = {
  teamId: string;
  teamCode: string;
  name: string;
  formerName: string | null;
  matchedName: string;
};

export type SearchTeamsActionState = {
  error?: string;
  results?: TeamNameSearchResult[];
  searched?: boolean;
};

export async function searchTeamsByName(
  _previousState: SearchTeamsActionState,
  formData: FormData,
): Promise<SearchTeamsActionState> {
  const query = readField(formData, "name_query");

  if (query.length < 2) {
    return { error: "Enter at least 2 characters to search." };
  }

  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return { error: "Sign in to search teams." };
  }

  const { data, error } = await supabase.rpc("levelledup_search_teams", {
    p_query: query,
  });

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Supabase Teams: levelledup_search_teams]", {
        code: error.code,
        message: error.message,
        userReference: user.id.slice(-6),
      });
    }
    return { error: "Team search is unavailable right now." };
  }

  const results = ((Array.isArray(data) ? data : []) as Array<{
    team_id: string;
    team_code: string;
    name: string;
    former_name: string | null;
    matched_name: string;
  }>).map((row) => ({
    teamId: row.team_id,
    teamCode: row.team_code,
    name: row.name,
    formerName: row.former_name,
    matchedName: row.matched_name,
  }));

  return { results, searched: true };
}
