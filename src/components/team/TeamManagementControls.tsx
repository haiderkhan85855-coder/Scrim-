"use client";

import { useActionState, useState } from "react";

import {
  type TeamMutationActionState,
  approveJoinRequest,
  approveTeamDisband,
  cancelTeamDisband,
  changeRosterRole,
  disbandTeam,
  rejectJoinRequest,
  removeRosterMember,
  renameTeam,
  requestTeamLeave,
  transferCaptaincy,
} from "@/app/team/management-actions";
import type { TeamRole } from "@/components/team/TeamDashboard";

const initialState: TeamMutationActionState = {};
const controlButtonClasses =
  "inline-flex min-h-9 items-center justify-center rounded-[2px] border px-3 text-[0.56rem] font-semibold uppercase tracking-[0.15em] transition-colors disabled:pointer-events-none disabled:opacity-40";

function ActionFeedback({
  states,
}: {
  states: TeamMutationActionState[];
}) {
  const error = states.find((state) => state.error)?.error;
  const success = states.find((state) => state.success)?.success;

  if (!error && !success) {
    return null;
  }

  return (
    <p
      className={`mt-3 text-xs leading-5 ${
        error ? "text-[#ff8a65]" : "text-[#79d49b]"
      }`}
      role={error ? "alert" : "status"}
    >
      {error ?? success}
    </p>
  );
}

export function JoinRequestControls({ requestId }: { requestId: string }) {
  const [approveState, approveAction, approvePending] = useActionState(
    approveJoinRequest,
    initialState,
  );
  const [rejectState, rejectAction, rejectPending] = useActionState(
    rejectJoinRequest,
    initialState,
  );
  const isPending = approvePending || rejectPending;

  return (
    <div className="mt-4">
      <div className="flex flex-wrap gap-2">
        <form action={approveAction}>
          <input type="hidden" name="request_id" value={requestId} />
          <button
            type="submit"
            disabled={isPending}
            className={`${controlButtonClasses} border-accent bg-accent text-background hover:bg-accent-hover`}
          >
            {approvePending ? "Approving..." : "Approve"}
          </button>
        </form>

        <form action={rejectAction}>
          <input type="hidden" name="request_id" value={requestId} />
          <button
            type="submit"
            disabled={isPending}
            className={`${controlButtonClasses} border-border-strong text-foreground-muted hover:border-[#ff8a65]/60 hover:text-[#ff8a65]`}
          >
            {rejectPending ? "Rejecting..." : "Reject"}
          </button>
        </form>
      </div>

      <ActionFeedback states={[approveState, rejectState]} />
    </div>
  );
}

type RosterMemberControlsProps = {
  memberId: string;
  teamId: string;
  role: TeamRole;
  displayName: string;
  isClaimed: boolean;
  isCurrentUser: boolean;
  viewerIsCaptain: boolean;
  hasPendingLeaveRequest?: boolean;
};

export function RosterMemberControls({
  memberId,
  teamId,
  role,
  displayName,
  isClaimed,
  isCurrentUser,
  viewerIsCaptain,
  hasPendingLeaveRequest = false,
}: RosterMemberControlsProps) {
  const [roleState, roleAction, rolePending] = useActionState(
    changeRosterRole,
    initialState,
  );
  const [leaveState, leaveAction, leavePending] = useActionState(
    requestTeamLeave,
    initialState,
  );
  const [removeState, removeAction, removePending] = useActionState(
    removeRosterMember,
    initialState,
  );
  const [transferState, transferAction, transferPending] = useActionState(
    transferCaptaincy,
    initialState,
  );
  const [confirmation, setConfirmation] = useState<
    "leave" | "remove" | "transfer" | null
  >(null);

  if (isCurrentUser && role === "captain") {
    return (
      <p className="mt-4 max-w-md text-xs leading-5 text-foreground-muted">
        Transfer captaincy or disband the team before leaving.
      </p>
    );
  }

  if (isCurrentUser) {
    if (hasPendingLeaveRequest) {
      return (
        <div className="mt-4">
          <p className="max-w-md text-xs leading-5 text-foreground-muted">
            Your leave request is with your captain. They must approve it
            before you are removed.
          </p>
          <ActionFeedback states={[leaveState]} />
        </div>
      );
    }
    return (
      <div className="mt-4">
        {confirmation === "leave" ? (
          <div className="rounded-[2px] border border-[#ff8a65]/35 bg-[#ff8a65]/[0.04] p-3">
            <p className="text-xs leading-5 text-foreground-muted">
              Request to leave this team? Your captain will be notified and
              must approve before you are removed. Your membership history
              will be preserved.
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              <form action={leaveAction}>
                <input type="hidden" name="team_id" value={teamId} />
                <button
                  type="submit"
                  disabled={leavePending}
                  className={`${controlButtonClasses} border-[#ff8a65]/60 text-[#ff8a65]`}
                >
                  {leavePending ? "Sending..." : "Send Request"}
                </button>
              </form>
              <button
                type="button"
                onClick={() => setConfirmation(null)}
                disabled={leavePending}
                className={`${controlButtonClasses} border-border-strong text-foreground-muted`}
              >
                Cancel
              </button>
            </div>
          </div>
        ) : (
          <button
            type="button"
            onClick={() => setConfirmation("leave")}
            className={`${controlButtonClasses} border-border-strong text-foreground-muted hover:border-[#ff8a65]/60 hover:text-[#ff8a65]`}
          >
            Request to Leave
          </button>
        )}
        <ActionFeedback states={[leaveState]} />
      </div>
    );
  }

  if (!viewerIsCaptain || role === "captain") {
    return null;
  }

  return (
    <div className="mt-4">
      <div className="flex flex-col gap-2 lg:flex-row lg:items-center">
        <form action={roleAction} className="flex flex-wrap gap-2">
          <input type="hidden" name="roster_member_id" value={memberId} />
          <select
            name="role"
            defaultValue={role}
            disabled={rolePending || removePending || transferPending}
            aria-label="Squad role"
            className="min-h-9 rounded-[2px] border border-border-strong bg-background px-3 text-xs text-foreground outline-none focus:border-accent"
          >
            <option value="player">Player</option>
            <option value="co_captain">Co-Captain</option>
          </select>
          <button
            type="submit"
            disabled={rolePending || removePending || transferPending}
            className={`${controlButtonClasses} border-border-strong text-foreground hover:border-accent hover:text-accent`}
          >
            {rolePending ? "Saving..." : "Update Role"}
          </button>
        </form>

        {isClaimed ? (
          <button
            type="button"
            onClick={() => setConfirmation("transfer")}
            disabled={rolePending || removePending || transferPending}
            className={`${controlButtonClasses} border-border-strong text-foreground hover:border-accent hover:text-accent`}
          >
            Transfer Captaincy
          </button>
        ) : null}

        <button
          type="button"
          onClick={() => setConfirmation("remove")}
          disabled={rolePending || removePending || transferPending}
          className={`${controlButtonClasses} border-border-strong text-foreground-muted hover:border-[#ff8a65]/60 hover:text-[#ff8a65]`}
        >
          Remove
        </button>
      </div>

      {confirmation === "transfer" ? (
        <div className="mt-3 rounded-[2px] border border-accent/30 bg-accent/[0.04] p-3">
          <p className="text-xs leading-5 text-foreground-muted">
            Transfer captaincy to {displayName}? You will become a Player.
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            <form action={transferAction}>
              <input type="hidden" name="team_id" value={teamId} />
              <input
                type="hidden"
                name="target_roster_member_id"
                value={memberId}
              />
              <button
                type="submit"
                disabled={transferPending}
                className={`${controlButtonClasses} border-accent bg-accent text-background`}
              >
                {transferPending ? "Transferring..." : "Confirm Transfer"}
              </button>
            </form>
            <button
              type="button"
              onClick={() => setConfirmation(null)}
              disabled={transferPending}
              className={`${controlButtonClasses} border-border-strong text-foreground-muted`}
            >
              Cancel
            </button>
          </div>
        </div>
      ) : null}

      {confirmation === "remove" ? (
        <div className="mt-3 rounded-[2px] border border-[#ff8a65]/35 bg-[#ff8a65]/[0.04] p-3">
          <p className="text-xs leading-5 text-foreground-muted">
            Remove {displayName}? Their membership history will be preserved.
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            <form action={removeAction}>
              <input
                type="hidden"
                name="roster_member_id"
                value={memberId}
              />
              <button
                type="submit"
                disabled={removePending}
                className={`${controlButtonClasses} border-[#ff8a65]/60 text-[#ff8a65]`}
              >
                {removePending ? "Removing..." : "Confirm Remove"}
              </button>
            </form>
            <button
              type="button"
              onClick={() => setConfirmation(null)}
              disabled={removePending}
              className={`${controlButtonClasses} border-border-strong text-foreground-muted`}
            >
              Cancel
            </button>
          </div>
        </div>
      ) : null}

      <ActionFeedback states={[roleState, removeState, transferState]} />
    </div>
  );
}

export type PendingDisbandRequest = {
  id: string;
  expiresAt: string;
  approvalCount: number;
  approvalsNeeded: number;
  callerApproved: boolean;
  isCallerRequester: boolean;
};

export function TeamRenameControls({
  teamId,
  currentName,
  formerName,
}: {
  teamId: string;
  currentName: string;
  formerName: string | null;
}) {
  const [state, action, pending] = useActionState(renameTeam, initialState);
  const [isOpen, setIsOpen] = useState(false);

  if (!isOpen) {
    return (
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className={`${controlButtonClasses} border-border-strong text-foreground-muted hover:border-accent hover:text-accent`}
      >
        Rename Team
      </button>
    );
  }

  return (
    <div className="rounded-[2px] border border-border-strong bg-background p-4">
      <p className="text-sm font-medium text-foreground">Rename team</p>
      <p className="mt-2 text-xs leading-5 text-foreground-muted">
        The old name is preserved in history and stays searchable. Past
        tournaments keep showing the name the team used then.
      </p>
      <form action={action} className="mt-4 space-y-3">
        <input type="hidden" name="team_id" value={teamId} />
        <label className="block">
          <span className="text-[0.6rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">
            New team name
          </span>
          <input
            name="new_name"
            type="text"
            required
            minLength={2}
            maxLength={80}
            defaultValue={currentName}
            placeholder="Enter the new team name"
            className="mt-2 w-full rounded-[2px] border border-border-strong bg-background-elevated px-3 py-2.5 text-sm text-foreground"
          />
        </label>
        <div className="flex gap-2">
          <button
            type="submit"
            disabled={pending}
            className={`${controlButtonClasses} border-accent/50 text-accent hover:bg-accent hover:text-background`}
          >
            {pending ? "Renaming..." : "Save New Name"}
          </button>
          <button
            type="button"
            onClick={() => setIsOpen(false)}
            className={`${controlButtonClasses} border-border-strong text-foreground-muted`}
          >
            Cancel
          </button>
        </div>
      </form>
      {formerName ? (
        <p className="mt-3 text-xs text-foreground-subtle">
          Formerly: {formerName}
        </p>
      ) : null}
      <ActionFeedback states={[state]} />
    </div>
  );
}

export function TeamDisbandControls({
  teamId,
  permanentTeamId,
  disbandRequest,
}: {
  teamId: string;
  permanentTeamId: string;
  disbandRequest: PendingDisbandRequest | null;
}) {
  const [state, action, pending] = useActionState(disbandTeam, initialState);
  const [cancelState, cancelAction, cancelPending] = useActionState(
    cancelTeamDisband,
    initialState,
  );
  const [isOpen, setIsOpen] = useState(false);
  const [confirmation, setConfirmation] = useState("");
  const matches = confirmation.trim().toUpperCase() === permanentTeamId;

  if (disbandRequest) {
    return (
      <div className="rounded-[2px] border border-[#ff8a65]/40 bg-[#ff8a65]/[0.04] p-4">
        <p className="text-sm font-medium text-foreground">
          Disband requested
        </p>
        <p className="mt-2 text-xs leading-5 text-foreground-muted">
          {disbandRequest.approvalCount} of {disbandRequest.approvalsNeeded}{" "}
          Squad approvals received. The request expires{" "}
          {new Date(disbandRequest.expiresAt).toLocaleString()}.
        </p>
        <p className="mt-2 text-xs leading-5 text-foreground-muted">
          The team archives only after two Squad members approve. You can
          cancel this request any time before then.
        </p>
        <form action={cancelAction} className="mt-4">
          <input type="hidden" name="request_id" value={disbandRequest.id} />
          <button
            type="submit"
            disabled={cancelPending}
            className={`${controlButtonClasses} border-border-strong text-foreground-muted`}
          >
            {cancelPending ? "Cancelling..." : "Cancel Disband Request"}
          </button>
        </form>
        <ActionFeedback states={[cancelState]} />
      </div>
    );
  }

  if (!isOpen) {
    return (
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className={`${controlButtonClasses} border-[#ff8a65]/45 text-[#ff8a65] hover:bg-[#ff8a65]/[0.05]`}
      >
        Disband Team
      </button>
    );
  }

  return (
    <div className="rounded-[2px] border border-[#ff8a65]/40 bg-[#ff8a65]/[0.04] p-4">
      <p className="text-sm font-medium text-foreground">
        Request to archive this team?
      </p>
      <p className="mt-2 text-xs leading-5 text-foreground-muted">
        Disbanding is a request: two other Squad members must approve within 48
        hours. Type
        <span className="mx-1 font-semibold text-[#ff8a65]">
          {permanentTeamId}
        </span>
        to confirm.
      </p>
      <p className="mt-2 text-xs leading-5 text-foreground-muted">
        Eligible unused tournament entries disbanded before registration closes
        become credit owned by each entry&apos;s verified payer. Registration,
        payment, Squad, and credit history remains permanent.
      </p>
      <form action={action} className="mt-4">
        <input type="hidden" name="team_id" value={teamId} />
        <input
          name="confirmation_team_id"
          value={confirmation}
          onChange={(event) => setConfirmation(event.target.value)}
          autoComplete="off"
          spellCheck={false}
          disabled={pending}
          className="h-10 w-full max-w-xs rounded-[2px] border border-border-strong bg-background px-3 text-sm uppercase tracking-[0.1em] text-foreground outline-none focus:border-[#ff8a65]"
          placeholder={permanentTeamId}
        />
        <div className="mt-3 flex flex-wrap gap-2">
          <button
            type="submit"
            disabled={!matches || pending}
            className={`${controlButtonClasses} border-[#ff8a65] bg-[#ff8a65] text-background`}
          >
            {pending ? "Requesting..." : "Request Disband"}
          </button>
          <button
            type="button"
            onClick={() => {
              setIsOpen(false);
              setConfirmation("");
            }}
            disabled={pending}
            className={`${controlButtonClasses} border-border-strong text-foreground-muted`}
          >
            Cancel
          </button>
        </div>
      </form>
      <ActionFeedback states={[state]} />
    </div>
  );
}

export function DisbandApprovalBanner({
  disbandRequest,
}: {
  disbandRequest: PendingDisbandRequest;
}) {
  const [state, action, pending] = useActionState(
    approveTeamDisband,
    initialState,
  );

  return (
    <div
      role="alert"
      className="rounded-[2px] border border-[#ff8a65]/45 bg-[#ff8a65]/[0.06] p-4 sm:p-5"
    >
      <p className="text-sm font-medium text-foreground">
        Disband requested by your captain
      </p>
      <p className="mt-2 text-xs leading-5 text-foreground-muted">
        Your captain asked to archive this team. It takes two Squad member
        approvals ({disbandRequest.approvalCount} of{" "}
        {disbandRequest.approvalsNeeded} received) before the team archives.
        The request expires{" "}
        {new Date(disbandRequest.expiresAt).toLocaleString()}.
      </p>
      {disbandRequest.callerApproved ? (
        <p className="mt-3 text-xs font-semibold text-[#79d49b]">
          You have approved this request.
        </p>
      ) : (
        <form action={action} className="mt-4">
          <input type="hidden" name="request_id" value={disbandRequest.id} />
          <button
            type="submit"
            disabled={pending}
            className={`${controlButtonClasses} border-[#ff8a65] bg-[#ff8a65] text-background`}
          >
            {pending ? "Approving..." : "Approve Disband"}
          </button>
        </form>
      )}
      <ActionFeedback states={[state]} />
    </div>
  );
}
