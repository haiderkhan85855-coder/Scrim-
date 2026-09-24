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

// ---------------------------------------------------------------------------
// Pre-match lobby (captain / co-captain).
// ---------------------------------------------------------------------------

export type CaptainLobbyState = {
  match_id: string;
  status: string;
  match_number: number;
  map_code: string;
  opened_at: string | null;
  timer_seconds: number;
  expires_at: string | null;
  closed_at: string | null;
  is_admin: boolean;
  my_registration_id: string | null;
  teams: Array<{
    registration_id: string;
    team_id: string;
    team_name: string;
    is_set: boolean;
    marked_at: string | null;
  }>;
  messages: Array<{
    id: string;
    sender_label: string;
    sender_team_id: string | null;
    body: string;
    created_at: string;
  }>;
};

export type MyOpenLobby = {
  match_id: string;
  tournament_id: string;
  match_number: number;
  map_code: string;
  lobby_id: string;
  opened_at: string | null;
  expires_at: string | null;
  team_name: string;
};

async function lobbyClient() {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();
  if (authError || !user) return null;
  return supabase;
}

export async function getMyOpenLobbies(): Promise<{
  data?: MyOpenLobby[];
  error?: string;
}> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { data, error } = await supabase.rpc(
    "levelledup_get_my_pre_match_lobbies",
  );

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Teams: load open lobbies]", {
        code: error.code,
        message: error.message,
      });
    }
    return { error: "Your open lobbies could not be loaded." };
  }

  return { data: (data ?? []) as MyOpenLobby[] };
}

export async function getCaptainLobbyState(
  matchId: string,
): Promise<{ data?: CaptainLobbyState; error?: string }> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { data, error } = await supabase.rpc("levelledup_get_pre_match_lobby", {
    p_match_id: matchId,
  });

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Teams: load lobby]", {
        code: error.code,
        message: error.message,
      });
    }
    return { error: "The lobby could not be loaded." };
  }

  return { data: data as CaptainLobbyState };
}

export async function markTeamSet(
  matchId: string,
): Promise<{ error?: string }> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { error } = await supabase.rpc("levelledup_mark_team_set", {
    p_match_id: matchId,
  });

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Teams: mark team set]", {
        code: error.code,
        message: error.message,
      });
    }
    return { error: error.message || "Your team could not be marked set." };
  }

  return {};
}

export async function unmarkTeamSet(
  matchId: string,
): Promise<{ error?: string }> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { error } = await supabase.rpc("levelledup_unmark_team_set", {
    p_match_id: matchId,
  });

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Teams: unmark team set]", {
        code: error.code,
        message: error.message,
      });
    }
    return { error: error.message || "Your team could not be unmarked." };
  }

  return {};
}

export async function sendCaptainLobbyMessage(
  matchId: string,
  body: string,
): Promise<{ error?: string }> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { error } = await supabase.rpc("levelledup_send_lobby_message", {
    p_match_id: matchId,
    p_body: body,
  });

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Teams: send lobby message]", {
        code: error.code,
        message: error.message,
      });
    }
    return { error: "The message could not be sent." };
  }

  return {};
}

export type MyWhatsAppLink = {
  tournament_id: string;
  tournament_name: string;
  whatsapp_group_link: string;
};

export async function getMyWhatsAppLinks(): Promise<{
  data?: MyWhatsAppLink[];
  error?: string;
}> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { data, error } = await supabase.rpc(
    "levelledup_get_my_whatsapp_links",
  );

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Teams: WhatsApp links read]", {
        code: error.code,
        message: error.message,
      });
    }
    return { error: "WhatsApp links could not be loaded." };
  }

  return { data: (data ?? []) as MyWhatsAppLink[] };
}

export type MatchRoomDetails = {
  room_id: string;
  room_password: string;
  published_at: string;
};

export async function getMatchRoom(
  matchId: string,
): Promise<{ data?: MatchRoomDetails; error?: string }> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { data, error } = await supabase.rpc("levelledup_get_match_room", {
    p_match_id: matchId,
  });

  if (error) {
    return { error: "Room details are not available yet." };
  }

  const row = (Array.isArray(data) ? data[0] : null) as
    | MatchRoomDetails
    | null;
  if (!row?.room_id || !row?.room_password) {
    return { error: "Room details are not available yet." };
  }
  return { data: row };
}

export type TeamNotification = {
  id: string;
  team_id: string;
  team_name: string;
  kind: string;
  title: string;
  body: string | null;
  link: string | null;
  created_at: string;
  read_at: string | null;
};

export async function listMyNotifications(): Promise<{
  data?: TeamNotification[];
  error?: string;
}> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { data, error } = await supabase.rpc(
    "levelledup_list_my_team_notifications",
  );

  if (error) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Teams: notifications read]", {
        code: error.code,
        message: error.message,
      });
    }
    return { error: "Notifications could not be loaded." };
  }

  return { data: (data ?? []) as TeamNotification[] };
}

export async function markNotificationRead(
  notificationId: string,
): Promise<{ error?: string }> {
  const supabase = await lobbyClient();
  if (!supabase) return { error: "Your session has expired. Sign in again." };

  const { error } = await supabase.rpc("levelledup_mark_notification_read", {
    p_notification_id: notificationId,
  });

  if (error) {
    return { error: "The notification could not be marked as read." };
  }
  return {};
}
