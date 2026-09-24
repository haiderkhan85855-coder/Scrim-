"use client";

import { useActionState, useEffect, useState } from "react";

import {
  getAdminRoomState,
  publishRoom,
  setRoomCredentials,
  type AdminRoomState,
  type RegistrationActionState,
} from "@/app/admin/tournaments/[tournamentId]/actions";

const initialActionState: RegistrationActionState = {};

function ActionMessage({ state }: { state: RegistrationActionState }) {
  if (state.error) {
    return (
      <p role="alert" className="mt-2 text-xs text-red-400">
        {state.error}
      </p>
    );
  }
  if (state.success) {
    return (
      <p role="status" className="mt-2 text-xs text-emerald-400">
        {state.success}
      </p>
    );
  }
  return null;
}

type MatchRoomCardProps = {
  matchId: string;
  tournamentPublicId: string;
};

export default function MatchRoomCard({
  matchId,
  tournamentPublicId,
}: MatchRoomCardProps) {
  const [room, setRoom] = useState<AdminRoomState | null>(null);
  const [loading, setLoading] = useState(true);
  const [saveState, saveAction] = useActionState(
    setRoomCredentials,
    initialActionState,
  );
  const [publishState, publishAction] = useActionState(
    publishRoom,
    initialActionState,
  );

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    getAdminRoomState(matchId).then((result) => {
      if (cancelled) return;
      setRoom(result.data ?? null);
      setLoading(false);
    });
    return () => {
      cancelled = true;
    };
  }, [matchId, saveState, publishState]);

  const published = Boolean(room?.room_published_at);

  return (
    <div className="border-b border-border-strong p-4 sm:p-5">
      <h3 className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground">
        Room ID / password
      </h3>
      {loading ? (
        <p className="mt-2 text-xs text-foreground-muted">Loading…</p>
      ) : (
        <>
          <p className="mt-1 text-xs text-foreground-muted">
            {published
              ? `Published ${room?.room_published_at ? new Date(room.room_published_at).toLocaleString() : ""} — participating teams can see these.`
              : "Draft only — teams cannot see anything until you publish."}
          </p>
          <form action={saveAction} className="mt-3">
            <input
              type="hidden"
              name="tournament_public_id"
              value={tournamentPublicId}
            />
            <input type="hidden" name="match_id" value={matchId} />
            <div className="flex flex-col gap-2 sm:flex-row">
              <input
                type="text"
                name="room_id"
                key={`room-id-${room?.room_id ?? "empty"}`}
                defaultValue={room?.room_id ?? ""}
                placeholder="Room ID"
                autoComplete="off"
                className="flex-1 rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm"
              />
              <input
                type="text"
                name="room_password"
                key={`room-pw-${room?.room_password ?? "empty"}`}
                defaultValue={room?.room_password ?? ""}
                placeholder="Room password"
                autoComplete="off"
                className="flex-1 rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm"
              />
              <button
                type="submit"
                className="rounded-[2px] border border-border-strong px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted transition-colors hover:text-foreground"
              >
                Save draft
              </button>
            </div>
            <ActionMessage state={saveState} />
          </form>
          {!published && room?.room_id && room?.room_password ? (
            <form
              action={publishAction}
              className="mt-3"
              onSubmit={(event) => {
                if (
                  !window.confirm(
                    "Publish the room ID and password to all participating teams now?",
                  )
                ) {
                  event.preventDefault();
                }
              }}
            >
              <input
                type="hidden"
                name="tournament_public_id"
                value={tournamentPublicId}
              />
              <input type="hidden" name="match_id" value={matchId} />
              <button
                type="submit"
                className="rounded-[2px] border border-amber-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-amber-300 transition-colors hover:bg-amber-400/10"
              >
                Publish room to teams
              </button>
              <ActionMessage state={publishState} />
            </form>
          ) : null}
        </>
      )}
    </div>
  );
}
