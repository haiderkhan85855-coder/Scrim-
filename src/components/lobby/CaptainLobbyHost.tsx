"use client";

import { useCallback, useEffect, useState } from "react";

import {
  getCaptainLobbyState,
  markTeamSet,
  sendCaptainLobbyMessage,
  unmarkTeamSet,
} from "@/app/team/actions";
import PreMatchLobby, {
  type LobbyState,
} from "@/components/lobby/PreMatchLobby";

type CaptainLobbyHostProps = {
  initialState: LobbyState;
};

export default function CaptainLobbyHost({
  initialState,
}: CaptainLobbyHostProps) {
  const [state, setState] = useState<LobbyState>(initialState);
  const matchId = initialState.match_id;

  useEffect(() => {
    setState(initialState);
  }, [initialState]);

  const refresh = useCallback(async () => {
    const result = await getCaptainLobbyState(matchId);
    if (result.data) return { data: result.data as LobbyState };
    return { error: result.error ?? "The lobby could not be loaded." };
  }, [matchId]);

  const sendMessage = useCallback(
    (body: string) => sendCaptainLobbyMessage(matchId, body),
    [matchId],
  );

  const handleMarkSet = useCallback(
    () => markTeamSet(matchId),
    [matchId],
  );

  const handleUnmarkSet = useCallback(
    () => unmarkTeamSet(matchId),
    [matchId],
  );

  return (
    <PreMatchLobby
      initialState={state}
      refresh={refresh}
      sendMessage={sendMessage}
      markSet={handleMarkSet}
      unmarkSet={handleUnmarkSet}
      adminActions={null}
    />
  );
}
