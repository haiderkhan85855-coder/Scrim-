"use client";

import { useEffect, useRef, useState } from "react";

export type LobbyTeamState = {
  registration_id: string;
  team_id: string;
  team_name: string;
  is_set: boolean;
  marked_at: string | null;
};

export type LobbyMessageState = {
  id: string;
  sender_label: string;
  sender_team_id: string | null;
  body: string;
  created_at: string;
};

export type LobbyState = {
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
  teams: LobbyTeamState[];
  messages: LobbyMessageState[];
};

type ActionResult = { error?: string; success?: string };

type PreMatchLobbyProps = {
  initialState: LobbyState;
  refresh: () => Promise<{ data?: LobbyState; error?: string }>;
  sendMessage: (body: string) => Promise<{ error?: string }>;
  markSet: (() => Promise<{ error?: string }>) | null;
  unmarkSet: (() => Promise<{ error?: string }>) | null;
  adminActions?: {
    start: (force: boolean, reason: string) => Promise<ActionResult>;
    cancel: (reason: string) => Promise<ActionResult>;
  } | null;
};

function formatCountdown(ms: number) {
  if (ms <= 0) return "00:00";
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

export default function PreMatchLobby({
  initialState,
  refresh,
  sendMessage,
  markSet,
  unmarkSet,
  adminActions = null,
}: PreMatchLobbyProps) {
  const [state, setState] = useState<LobbyState>(initialState);
  const [now, setNow] = useState(() => Date.now());
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [showForce, setShowForce] = useState(false);
  const [showCancel, setShowCancel] = useState(false);
  const [reason, setReason] = useState("");
  const messagesRef = useRef<HTMLDivElement>(null);
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;

  // Tick the countdown every second.
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);

  // Poll the lobby every 5 seconds while it is open.
  useEffect(() => {
    if (state.status !== "pre_match") return;
    const timer = setInterval(async () => {
      const result = await refreshRef.current();
      if (result.data) setState(result.data);
    }, 5000);
    return () => clearInterval(timer);
  }, [state.status, state.match_id]);

  // Keep the chat pinned to the latest message.
  useEffect(() => {
    const el = messagesRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [state.messages.length]);

  const expiresAtMs = state.expires_at
    ? new Date(state.expires_at).getTime()
    : null;
  const remainingMs = expiresAtMs === null ? null : expiresAtMs - now;
  const timerExpired = remainingMs !== null && remainingMs <= 0;

  const setCount = state.teams.filter((team) => team.is_set).length;
  const teamTotal = state.teams.length;
  const allSet = teamTotal > 0 && setCount === teamTotal;
  const canStart = allSet || timerExpired;

  const myTeam = state.teams.find(
    (team) => team.registration_id === state.my_registration_id,
  );

  async function reload() {
    const result = await refresh();
    if (result.data) {
      setState(result.data);
    } else if (result.error) {
      setNotice(result.error);
    }
  }

  async function handleSend() {
    const body = draft.trim();
    if (!body || busy) return;
    setBusy(true);
    setNotice(null);
    const result = await sendMessage(body);
    setBusy(false);
    if (result.error) {
      setNotice(result.error);
      return;
    }
    setDraft("");
    await reload();
  }

  async function handleMarkSet() {
    if (!markSet || busy) return;
    setBusy(true);
    setNotice(null);
    const result = await markSet();
    setBusy(false);
    if (result.error) {
      setNotice(result.error);
      return;
    }
    await reload();
  }

  async function handleUnmarkSet() {
    if (!unmarkSet || busy) return;
    setBusy(true);
    setNotice(null);
    const result = await unmarkSet();
    setBusy(false);
    if (result.error) {
      setNotice(result.error);
      return;
    }
    await reload();
  }

  async function handleStart(force: boolean) {
    if (!adminActions || busy) return;
    if (force && !reason.trim()) {
      setNotice("A reason is required to force-start a match.");
      return;
    }
    setBusy(true);
    setNotice(null);
    const result = await adminActions.start(force, reason.trim());
    setBusy(false);
    if (result.error) {
      setNotice(result.error);
      return;
    }
    setReason("");
    setShowForce(false);
    await reload();
  }

  async function handleCancel() {
    if (!adminActions || busy) return;
    if (!reason.trim()) {
      setNotice("A reason is required to cancel a match.");
      return;
    }
    setBusy(true);
    setNotice(null);
    const result = await adminActions.cancel(reason.trim());
    setBusy(false);
    if (result.error) {
      setNotice(result.error);
      return;
    }
    setReason("");
    setShowCancel(false);
    await reload();
  }

  return (
    <div className="rounded-[2px] border border-border-strong bg-background-elevated/40">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border-strong p-4 sm:p-5">
        <div>
          <h3 className="type-display text-xl uppercase">
            Pre-match lobby — Match {state.match_number}
          </h3>
          <p className="mt-1 text-xs text-foreground-muted">
            {setCount} of {teamTotal} teams set
            {remainingMs !== null && !timerExpired
              ? ` · starts in ${formatCountdown(remainingMs)} if not all set`
              : null}
            {timerExpired ? " · timer expired, the match can start" : null}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <span className="rounded-[2px] border border-amber-400/40 bg-amber-400/10 px-2 py-1 text-[0.55rem] font-semibold uppercase tracking-[0.12em] text-amber-300">
            {state.status === "pre_match"
              ? `Lobby open · ${formatCountdown(remainingMs ?? 0)}`
              : state.status}
          </span>
        </div>
      </div>

      {notice ? (
        <p role="alert" className="border-b border-border-strong p-4 text-xs text-red-400">
          {notice}
        </p>
      ) : null}

      {state.status !== "pre_match" ? (
        <p className="p-5 text-sm text-foreground-muted">
          This lobby is closed
          {state.status === "live" ? " — the match has started." : "."}
        </p>
      ) : (
        <div className="grid gap-0 lg:grid-cols-2">
          <div className="border-b border-border-strong p-4 sm:p-5 lg:border-b-0 lg:border-r">
            <h4 className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted">
              Teams
            </h4>
            <ul className="mt-3 space-y-2">
              {state.teams.map((team) => (
                <li
                  key={team.registration_id}
                  className="flex items-center justify-between gap-3 rounded-[2px] border border-border-strong px-3 py-2"
                >
                  <span className="text-sm">{team.team_name}</span>
                  {team.is_set ? (
                    <span className="rounded-[2px] border border-emerald-400/40 bg-emerald-400/10 px-2 py-0.5 text-[0.55rem] font-semibold uppercase tracking-[0.12em] text-emerald-300">
                      Set
                    </span>
                  ) : (
                    <span className="rounded-[2px] border border-border-strong px-2 py-0.5 text-[0.55rem] font-semibold uppercase tracking-[0.12em] text-foreground-muted">
                      Not set
                    </span>
                  )}
                </li>
              ))}
            </ul>

            {myTeam && !state.is_admin ? (
              <div className="mt-4">
                {myTeam.is_set ? (
                  <button
                    type="button"
                    onClick={handleUnmarkSet}
                    disabled={busy}
                    className="rounded-[2px] border border-border-strong px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted transition-colors hover:bg-background-elevated disabled:opacity-50"
                  >
                    {busy ? "Working…" : "My team is not set"}
                  </button>
                ) : (
                  <button
                    type="button"
                    onClick={handleMarkSet}
                    disabled={busy}
                    className="rounded-[2px] border border-emerald-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-emerald-300 transition-colors hover:bg-emerald-400/10 disabled:opacity-50"
                  >
                    {busy ? "Working…" : "Mark my team set"}
                  </button>
                )}
              </div>
            ) : null}

            {adminActions ? (
              <div className="mt-5 border-t border-border-strong pt-4">
                <div className="flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => handleStart(false)}
                    disabled={busy || !canStart}
                    title={
                      canStart
                        ? "Start the match"
                        : "Waiting for all teams to be set or the timer to expire"
                    }
                    className="rounded-[2px] border border-emerald-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-emerald-300 transition-colors hover:bg-emerald-400/10 disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    {busy ? "Working…" : "Start match"}
                  </button>
                  <button
                    type="button"
                    onClick={() => setShowForce((value) => !value)}
                    className="rounded-[2px] border border-border-strong px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted transition-colors hover:bg-background-elevated"
                  >
                    Force start
                  </button>
                  <button
                    type="button"
                    onClick={() => setShowCancel((value) => !value)}
                    className="rounded-[2px] border border-red-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-red-300 transition-colors hover:bg-red-400/10"
                  >
                    Cancel match
                  </button>
                </div>
                {!canStart ? (
                  <p className="mt-2 text-xs text-foreground-muted">
                    Start unlocks when every team is set or the timer runs out.
                  </p>
                ) : null}
                {showForce ? (
                  <div className="mt-3 rounded-[2px] border border-amber-400/40 bg-amber-400/5 p-3">
                    <p className="text-xs text-amber-200">
                      Force-starting skips the ready check and the timer. Give
                      a reason — it is logged.
                    </p>
                    <input
                      type="text"
                      value={reason}
                      onChange={(event) => setReason(event.target.value)}
                      placeholder="Reason for force-starting…"
                      className="mt-2 w-full rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm"
                    />
                    <button
                      type="button"
                      onClick={() => handleStart(true)}
                      disabled={busy}
                      className="mt-2 rounded-[2px] border border-amber-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-amber-300 transition-colors hover:bg-amber-400/10 disabled:opacity-50"
                    >
                      {busy ? "Working…" : "Confirm force start"}
                    </button>
                  </div>
                ) : null}
                {showCancel ? (
                  <div className="mt-3 rounded-[2px] border border-red-400/40 bg-red-400/5 p-3">
                    <p className="text-xs text-red-200">
                      Cancelling ends this match for every team. A reason is
                      required — it is logged.
                    </p>
                    <input
                      type="text"
                      value={reason}
                      onChange={(event) => setReason(event.target.value)}
                      placeholder="Reason for cancelling…"
                      className="mt-2 w-full rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm"
                    />
                    <button
                      type="button"
                      onClick={handleCancel}
                      disabled={busy}
                      className="mt-2 rounded-[2px] border border-red-400/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-red-300 transition-colors hover:bg-red-400/10 disabled:opacity-50"
                    >
                      {busy ? "Working…" : "Confirm cancellation"}
                    </button>
                  </div>
                ) : null}
              </div>
            ) : null}
          </div>

          <div className="flex flex-col p-4 sm:p-5">
            <h4 className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted">
              Lobby chat · temporary
            </h4>
            <div
              ref={messagesRef}
              className="mt-3 max-h-72 min-h-40 overflow-y-auto rounded-[2px] border border-border-strong bg-background/60 p-3"
            >
              {state.messages.length === 0 ? (
                <p className="text-xs text-foreground-muted">
                  No messages yet. Captains and admins can chat here until the
                  match starts.
                </p>
              ) : (
                <ul className="space-y-2">
                  {state.messages.map((message) => (
                    <li key={message.id} className="text-sm">
                      <span className="mr-2 text-[0.6rem] font-semibold uppercase tracking-[0.12em] text-foreground-muted">
                        {message.sender_label}
                      </span>
                      <span className="text-foreground">{message.body}</span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
            <div className="mt-3 flex gap-2">
              <input
                type="text"
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") handleSend();
                }}
                placeholder="Message the lobby…"
                maxLength={500}
                className="flex-1 rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm"
              />
              <button
                type="button"
                onClick={handleSend}
                disabled={busy || !draft.trim()}
                className="rounded-[2px] border border-border-strong px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] transition-colors hover:bg-background-elevated disabled:opacity-50"
              >
                Send
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
