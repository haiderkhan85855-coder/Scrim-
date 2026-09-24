"use client";

import { useActionState } from "react";

import {
  setWhatsAppLink,
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

type TournamentWhatsAppCardProps = {
  tournamentId: string;
  tournamentPublicId: string;
  currentLink: string | null;
  canManage: boolean;
};

export default function TournamentWhatsAppCard({
  tournamentId,
  tournamentPublicId,
  currentLink,
  canManage,
}: TournamentWhatsAppCardProps) {
  const [state, action] = useActionState(setWhatsAppLink, initialActionState);

  return (
    <div className="mt-5 rounded-[2px] border border-border-strong bg-background-elevated/80 p-4 sm:p-5">
      <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h3 className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground">
            WhatsApp tournament group
          </h3>
          <p className="mt-1 text-xs text-foreground-muted">
            Only teams you confirm (payment/entry) can see this link.
          </p>
        </div>
        {currentLink ? (
          <a
            href={currentLink}
            target="_blank"
            rel="noreferrer"
            className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-sky-300 hover:underline"
          >
            Open group ↗
          </a>
        ) : null}
      </div>
      {canManage ? (
        <form action={action} className="mt-3">
          <input type="hidden" name="tournament_id" value={tournamentId} />
          <input
            type="hidden"
            name="tournament_public_id"
            value={tournamentPublicId}
          />
          <div className="flex flex-col gap-2 sm:flex-row">
            <input
              type="url"
              name="whatsapp_link"
              defaultValue={currentLink ?? ""}
              placeholder="https://chat.whatsapp.com/…"
              className="flex-1 rounded-[2px] border border-border-strong bg-background px-3 py-2 text-sm"
            />
            <button
              type="submit"
              className="rounded-[2px] border border-accent/40 px-4 py-2 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-accent transition-colors hover:bg-accent/10"
            >
              Save link
            </button>
          </div>
          <ActionMessage state={state} />
        </form>
      ) : currentLink ? (
        <p className="mt-2 text-xs text-foreground-muted">
          Link set. Confirmed teams can see it on their team page.
        </p>
      ) : (
        <p className="mt-2 text-xs text-foreground-muted">No link set yet.</p>
      )}
    </div>
  );
}
