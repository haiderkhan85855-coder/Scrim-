"use client";

import { useEffect, useState } from "react";

import { getMatchRoom, type MatchRoomDetails } from "@/app/team/actions";

export default function RoomDetailsCard({ matchId }: { matchId: string }) {
  const [room, setRoom] = useState<MatchRoomDetails | null>(null);

  useEffect(() => {
    let cancelled = false;
    getMatchRoom(matchId).then((result) => {
      if (!cancelled && result.data) setRoom(result.data);
    });
    return () => {
      cancelled = true;
    };
  }, [matchId]);

  if (!room) return null;

  return (
    <div className="mb-4 rounded-[2px] border border-amber-400/40 bg-amber-400/5 p-4 sm:p-5">
      <p className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-amber-300">
        Room details — live
      </p>
      <dl className="mt-3 grid gap-3 sm:grid-cols-2">
        <div>
          <dt className="text-[0.55rem] uppercase tracking-[0.12em] text-foreground-muted">
            Room ID
          </dt>
          <dd className="mt-1 select-all font-mono text-lg font-semibold">
            {room.room_id}
          </dd>
        </div>
        <div>
          <dt className="text-[0.55rem] uppercase tracking-[0.12em] text-foreground-muted">
            Password
          </dt>
          <dd className="mt-1 select-all font-mono text-lg font-semibold">
            {room.room_password}
          </dd>
        </div>
      </dl>
      <p className="mt-2 text-xs text-foreground-muted">
        Do not share these outside your team.
      </p>
    </div>
  );
}
