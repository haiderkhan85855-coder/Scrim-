"use client";

import { useCallback, useEffect, useState } from "react";

import {
  cancelMatch,
  getLobbyState,
  sendLobbyMessage,
  startMatch,
} from "@/app/admin/tournaments/[tournamentId]/actions";
import PreMatchLobby, {
  type LobbyState,
} from "@/components/lobby/PreMatchLobby";

type PreMatchLobbyHostProps = {
  matchId: string;
  tournamentPublicId: string;
};

export default function PreMatchLobbyHost({
  matchId,
  tournamentPublicId,
}: PreMatchLobbyHostProps) {
  const [initial, setInitial] = useState<LobbyState | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    getLobbyState(matchId).then((result) => {
      if (!active) return;
      if (result.data) {
        setInitial(result.data as LobbyState);
      } else {
        setError(result.error ?? "The lobby could not be loaded.");
      }
    });
    return () => {
      active = false;
    };
  }, [matchId]);

  const refresh = useCallback(async () => {
    const result = await getLobbyState(matchId);
    if (result.data) return { data: result.data as LobbyState };
    return { error: result.error ?? "The lobby could not be loaded." };
  }, [matchId]);

  const sendMessage = useCallback(
    (body: string) => sendLobbyMessage(matchId, body),
    [matchId],
  );

  const start = useCallback(
    async (force: boolean, reason: string) => {
      const formData = new FormData();
      formData.set("tournament_public_id", tournamentPublicId);
      formData.set("match_id", matchId);
      formData.set("force", force ? "yes" : "no");
      formData.set("reason", reason);
      return startMatch({}, formData);
    },
    [matchId, tournamentPublicId],
  );

  const cancel = useCallback(
    async (reason: string) => {
      const formData = new FormData();
      formData.set("tournament_public_id", tournamentPublicId);
      formData.set("match_id", matchId);
      formData.set("reason", reason);
      return cancelMatch({}, formData);
    },
    [matchId, tournamentPublicId],
  );

  if (error) {
    return (
      <p role="alert" className="p-5 text-sm text-red-400">
        {error}
      </p>
    );
  }

  if (!initial) {
    return (
      <p className="p-5 text-sm text-foreground-muted">Loading lobby…</p>
    );
  }

  return (
    <PreMatchLobby
      initialState={initial}
      refresh={refresh}
      sendMessage={sendMessage}
      markSet={null}
      unmarkSet={null}
      adminActions={{ start, cancel }}
    />
  );
}
