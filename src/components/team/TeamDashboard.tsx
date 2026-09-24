"use client";

import Link from "next/link";
import { useState } from "react";

import { CopyPubgUid } from "@/components/team/CopyPubgUid";
import {
  JoinRequestControls,
  RosterMemberControls,
  TeamDisbandControls,
} from "@/components/team/TeamManagementControls";
import { TeamOnboarding } from "@/components/team/TeamOnboarding";
import {
  TeamRecruitmentPanel,
  type TeamRecruitmentPost,
} from "@/components/team/TeamRecruitmentPanel";
import { Button } from "@/components/ui/Button";

export type TeamRole = "captain" | "member" | "substitute";

export type TeamMembership = {
  id: string;
  name: string;
  teamId: string;
  shortName: string | null;
  logoUrl: string | null;
  role: TeamRole;
};

export type TeamRosterMember = {
  id: string;
  teamId: string;
  displayName: string;
  pubgIgn: string;
  pubgUid: string;
  role: TeamRole;
  isClaimed: boolean;
  isCurrentUser: boolean;
};

export type PendingJoinRequest = {
  id: string;
  teamId: string;
  displayName: string;
  pubgIgn: string;
  pubgUid: string;
  requestedAt: string;
};

export type CancelledTournamentHistory = {
  id: string;
  teamId: string;
  tournamentName: string;
  tournamentId: string;
  registrationStatus: "pending" | "confirmed" | "rejected" | "withdrawn";
  previousSlot: number | null;
  creditAmount: string | null;
  creditStatus: "available" | "used" | "refunded" | null;
  paymentReference: string | null;
};

type TeamDashboardProps = {
  teams: TeamMembership[];
  roster: TeamRosterMember[];
  pendingRequests: PendingJoinRequest[];
  cancelledTournaments: CancelledTournamentHistory[];
  recruitmentPosts: TeamRecruitmentPost[];
  canCreate: boolean;
};

const roleLabels: Record<TeamRole, string> = {
  captain: "Captain",
  member: "Player",
  substitute: "Substitute",
};

function teamMark(team: TeamMembership) {
  if (team.shortName) return team.shortName.slice(0, 4).toUpperCase();

  return team.name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0])
    .join("")
    .toUpperCase();
}

export function TeamDashboard({
  teams,
  roster,
  pendingRequests,
  cancelledTournaments,
  recruitmentPosts,
  canCreate,
}: TeamDashboardProps) {
  const [selectedTeamId, setSelectedTeamId] = useState(teams[0].id);
  const selectedTeam =
    teams.find((team) => team.id === selectedTeamId) ?? teams[0];
  const selectedRoster = roster.filter(
    (member) => member.teamId === selectedTeam.id,
  );
  const selectedRequests = pendingRequests.filter(
    (request) => request.teamId === selectedTeam.id,
  );
  const selectedCancelledTournaments = cancelledTournaments.filter(
    (tournament) => tournament.teamId === selectedTeam.id,
  );
  const selectedRecruitment =
    recruitmentPosts.find((post) => post.teamId === selectedTeam.id) ?? null;
  const viewerIsCaptain = selectedTeam.role === "captain";
  const teamLimitReached = teams.length >= 3;

  return (
    <>
      <header className="max-w-3xl">
        <p className="type-eyebrow text-accent">Team command</p>
        <h1 className="type-display mt-5 text-[clamp(3.2rem,8vw,6.5rem)] uppercase leading-[0.88]">
          Your squads.
        </h1>
        <p className="mt-5 max-w-xl text-sm leading-7 text-foreground-muted">
          Manage every active LevelledUp Squad from one command page.
        </p>
        <Button href="/find-team" variant="secondary" className="mt-6">
          Find a Team
        </Button>
      </header>

      <nav
        className="mt-10 grid gap-3 sm:grid-cols-2 lg:grid-cols-3"
        aria-label="Your active teams"
      >
        {teams.map((team, index) => {
          const isSelected = team.id === selectedTeam.id;

          return (
            <button
              key={team.id}
              type="button"
              aria-pressed={isSelected}
              onClick={() => setSelectedTeamId(team.id)}
              className={`group relative min-w-0 overflow-hidden rounded-[2px] border p-5 text-left transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent ${
                isSelected
                  ? "border-accent bg-accent/[0.07]"
                  : "border-border-strong bg-background-elevated/65 hover:border-foreground/35"
              }`}
            >
              <span className="absolute right-4 top-4 text-[0.55rem] font-semibold tracking-[0.16em] text-foreground-subtle">
                {String(index + 1).padStart(2, "0")}
              </span>
              <span className="block truncate pr-8 font-[family-name:var(--font-display)] text-xl uppercase text-foreground">
                {team.name}
              </span>
              <span
                className={`mt-3 block text-[0.58rem] font-semibold uppercase tracking-[0.18em] ${
                  isSelected ? "text-accent" : "text-foreground-muted"
                }`}
              >
                {roleLabels[team.role]} · {team.teamId}
              </span>
            </button>
          );
        })}
      </nav>

      <section
        className="relative mt-6 min-h-72 overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated"
        aria-label={`${selectedTeam.name} identity`}
      >
        <div
          className="absolute inset-0 bg-[linear-gradient(110deg,var(--background-elevated)_8%,transparent_70%),radial-gradient(circle_at_82%_28%,color-mix(in_srgb,var(--accent)_15%,transparent),transparent_42%)]"
          aria-hidden="true"
        />
        <div
          className="absolute inset-0 opacity-[0.08] [background-image:linear-gradient(var(--foreground)_1px,transparent_1px),linear-gradient(90deg,var(--foreground)_1px,transparent_1px)] [background-size:48px_48px]"
          aria-hidden="true"
        />

        <div className="relative flex min-h-72 flex-col justify-end gap-7 p-6 sm:p-9 lg:flex-row lg:items-end lg:justify-between">
          <div className="flex min-w-0 flex-col gap-6 sm:flex-row sm:items-end">
            <div className="flex size-24 shrink-0 items-center justify-center overflow-hidden rounded-[2px] border border-accent/40 bg-background text-center font-[family-name:var(--font-display)] text-3xl uppercase tracking-[0.08em] text-accent sm:size-32">
              {selectedTeam.logoUrl ? (
                // Team logos may be hosted outside configured Next Image origins.
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  src={selectedTeam.logoUrl}
                  alt={`${selectedTeam.name} logo`}
                  className="size-full object-cover"
                />
              ) : (
                teamMark(selectedTeam)
              )}
            </div>

            <div className="min-w-0 pb-1">
              <p className="text-[0.6rem] font-semibold uppercase tracking-[0.2em] text-accent">
                Active team
              </p>
              <h2 className="type-display mt-3 break-words text-[clamp(2.6rem,7vw,5.4rem)] uppercase leading-[0.9] lg:whitespace-nowrap lg:text-[clamp(2.8rem,4.8vw,4.8rem)]">
                {selectedTeam.name}
              </h2>
              {selectedTeam.shortName ? (
                <p className="mt-3 text-xs font-semibold uppercase tracking-[0.2em] text-foreground-muted">
                  {selectedTeam.shortName}
                </p>
              ) : null}
            </div>
          </div>

          <dl className="grid shrink-0 grid-cols-2 gap-x-8 gap-y-4 border-t border-border pt-5 lg:border-l lg:border-t-0 lg:pl-8 lg:pt-0">
            <div>
              <dt className="text-[0.55rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
                Team ID
              </dt>
              <dd className="mt-2 font-[family-name:var(--font-display)] text-lg tracking-[0.08em] text-accent">
                {selectedTeam.teamId}
              </dd>
            </div>
            <div>
              <dt className="text-[0.55rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
                Your role
              </dt>
              <dd className="mt-2 text-sm font-semibold text-foreground">
                {roleLabels[selectedTeam.role]}
              </dd>
            </div>
          </dl>
        </div>
      </section>

      <div className="mt-8 grid items-start gap-8 xl:grid-cols-[minmax(0,1fr)_20rem]">
        <div className="space-y-8">
          <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
            <div className="flex items-end justify-between gap-4 border-b border-border pb-5">
              <div>
                <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
                  Active Squad
                </p>
                <h3 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
                  Squad personnel
                </h3>
              </div>
              <p className="shrink-0 text-[0.6rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
                {selectedRoster.length} active
              </p>
            </div>

            <div className="mt-5 grid gap-3">
              {selectedRoster.map((member, index) => (
                <article
                  key={member.id}
                  className="rounded-[2px] border border-border bg-background/50 p-4 transition-colors hover:border-border-strong sm:p-5"
                >
                  <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,0.9fr)] lg:items-start">
                    <div className="flex min-w-0 items-start gap-3">
                      <span className="pt-0.5 text-[0.55rem] font-semibold tracking-[0.16em] text-foreground-subtle">
                        {String(index + 1).padStart(2, "0")}
                      </span>
                      <div className="min-w-0">
                        <h4 className="truncate text-base font-semibold text-foreground">
                          {member.displayName}
                          {member.isCurrentUser ? (
                            <span className="ml-2 text-[0.54rem] uppercase tracking-[0.15em] text-accent">
                              You
                            </span>
                          ) : null}
                        </h4>
                        <p className="mt-2 text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-foreground-muted">
                          {roleLabels[member.role]}
                          {!member.isClaimed ? " · Unclaimed" : ""}
                        </p>
                      </div>
                    </div>

                    <dl className="grid min-w-0 gap-4 sm:grid-cols-2">
                      <div>
                        <dt className="text-[0.54rem] uppercase tracking-[0.14em] text-foreground-subtle">
                          PUBG IGN
                        </dt>
                        <dd className="mt-2 break-all text-xs text-foreground">
                          {member.pubgIgn}
                        </dd>
                      </div>
                      <div>
                        <dt className="text-[0.54rem] uppercase tracking-[0.14em] text-foreground-subtle">
                          PUBG UID
                        </dt>
                        <dd className="mt-2">
                          <CopyPubgUid value={member.pubgUid} />
                        </dd>
                      </div>
                    </dl>
                  </div>

                  <RosterMemberControls
                    memberId={member.id}
                    teamId={selectedTeam.id}
                    role={member.role}
                    displayName={member.displayName}
                    isClaimed={member.isClaimed}
                    isCurrentUser={member.isCurrentUser}
                    viewerIsCaptain={viewerIsCaptain}
                  />
                </article>
              ))}
            </div>
          </section>

          <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
            <div className="flex flex-col gap-3 border-b border-border pb-5 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-[#ff8a65]">
                  Tournament history
                </p>
                <h3 className="type-display mt-3 text-3xl uppercase sm:text-4xl">
                  Cancelled tournaments
                </h3>
              </div>
              <p className="text-[0.56rem] font-semibold uppercase tracking-[0.15em] text-foreground-muted">
                {selectedCancelledTournaments.length} preserved
              </p>
            </div>

            {selectedCancelledTournaments.length ? (
              <div className="mt-5 grid gap-3">
                {selectedCancelledTournaments.map((tournament) => (
                  <article key={tournament.id} className="rounded-[2px] border border-[#ff8a65]/30 bg-[#ff8a65]/[0.035] p-4 sm:p-5">
                    <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                      <div className="min-w-0">
                        <span className="inline-flex border border-[#ff8a65]/40 px-2 py-1 text-[0.5rem] font-semibold uppercase tracking-[0.13em] text-[#ff8a65]">Tournament Cancelled</span>
                        <h4 className="type-display mt-3 break-words text-2xl uppercase sm:text-3xl">{tournament.tournamentName}</h4>
                        <p className="mt-2 font-mono text-[0.58rem] uppercase tracking-[0.12em] text-foreground-muted">{tournament.tournamentId}</p>
                      </div>
                      <Link href={`/tournaments/${tournament.tournamentId}/register`} className="inline-flex min-h-9 shrink-0 items-center justify-center rounded-[2px] border border-border-strong px-3 text-[0.54rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted hover:border-accent hover:text-accent">
                        View History
                      </Link>
                    </div>
                    <dl className="mt-5 grid gap-4 border-t border-border pt-4 sm:grid-cols-2 lg:grid-cols-4">
                      <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Registration</dt><dd className="mt-1 text-sm font-semibold capitalize">{tournament.registrationStatus}</dd></div>
                      <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Previous slot</dt><dd className="mt-1 text-sm font-semibold">{tournament.previousSlot ? `Slot ${String(tournament.previousSlot).padStart(2, "0")}` : "Not assigned"}</dd></div>
                      <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Cancellation credit</dt><dd className={`mt-1 text-sm font-semibold ${tournament.creditStatus === "available" ? "text-[#79d49b]" : "text-foreground"}`}>{tournament.creditAmount ? `${tournament.creditStatus === "available" ? "Credit available: " : "Credit: "}${tournament.creditAmount}` : "Not applicable"}</dd></div>
                      <div><dt className="text-[0.5rem] uppercase tracking-[0.13em] text-foreground-subtle">Original payment / reference</dt><dd className="mt-1 break-all font-mono text-sm">{tournament.paymentReference ?? "Not applicable"}</dd></div>
                    </dl>
                  </article>
                ))}
              </div>
            ) : (
              <p className="mt-5 rounded-[2px] border border-border bg-background/40 p-5 text-sm text-foreground-muted">No cancelled tournament registrations for this team.</p>
            )}
          </section>

          <TeamRecruitmentPanel
            key={selectedTeam.id}
            teamId={selectedTeam.id}
            isCaptain={viewerIsCaptain}
            post={selectedRecruitment}
          />

          {viewerIsCaptain ? (
            <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5 sm:p-7">
              <div className="flex flex-col gap-4 border-b border-border pb-5 sm:flex-row sm:items-end sm:justify-between">
                <div>
                  <h3 className="type-display text-3xl uppercase sm:text-4xl">
                    Join requests
                  </h3>
                  <p className="mt-3 text-sm leading-6 text-foreground-muted">
                    Review players who want to join your squad.
                  </p>
                </div>
                <p className="shrink-0 text-[0.6rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted">
                  {selectedRequests.length} pending
                </p>
              </div>

              {selectedRequests.length > 0 ? (
                <div className="mt-5 grid gap-3">
                  {selectedRequests.map((request) => (
                    <article
                      key={request.id}
                      className="rounded-[2px] border border-border bg-background/50 p-4 transition-colors hover:border-border-strong sm:p-5"
                    >
                      <dl className="grid gap-5 sm:grid-cols-3">
                        <div>
                          <dt className="text-[0.54rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">
                            Display Name
                          </dt>
                          <dd className="mt-2 text-sm font-semibold text-foreground">
                            {request.displayName}
                          </dd>
                        </div>
                        <div>
                          <dt className="text-[0.54rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">
                            PUBG IGN
                          </dt>
                          <dd className="mt-2 text-xs text-foreground">
                            {request.pubgIgn}
                          </dd>
                        </div>
                        <div>
                          <dt className="text-[0.54rem] font-semibold uppercase tracking-[0.14em] text-foreground-muted">
                            PUBG UID
                          </dt>
                          <dd className="mt-2">
                            <CopyPubgUid value={request.pubgUid} />
                          </dd>
                        </div>
                      </dl>
                      <JoinRequestControls requestId={request.id} />
                    </article>
                  ))}
                </div>
              ) : (
                <p className="mt-5 rounded-[2px] border border-border bg-background/40 p-5 text-sm text-foreground-muted">
                  No pending requests for this team.
                </p>
              )}
            </section>
          ) : null}
        </div>

        <aside className="space-y-6 xl:sticky xl:top-28">
          <section className="rounded-[2px] border border-border-strong bg-background-elevated/65 p-5">
            <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-accent">
              Team management
            </p>
            <p className="mt-4 text-sm leading-6 text-foreground-muted">
              Membership changes preserve Squad history. Captaincy and archive
              actions require explicit confirmation.
            </p>
          </section>

          {viewerIsCaptain ? (
            <section className="rounded-[2px] border border-[#ff8a65]/30 bg-background-elevated/65 p-5">
              <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-[#ff8a65]">
                Danger zone
              </p>
              <p className="mt-4 text-xs leading-5 text-foreground-muted">
                Disbanding archives the team and deactivates its entire active
                Squad without deleting history.
              </p>
              <div className="mt-5">
                <TeamDisbandControls
                  teamId={selectedTeam.id}
                  permanentTeamId={selectedTeam.teamId}
                />
              </div>
            </section>
          ) : null}
        </aside>
      </div>

      <section className="mt-8 rounded-[2px] border border-border-strong bg-background-elevated/45 p-4 sm:p-5">
        <TeamOnboarding
          canCreate={canCreate}
          additional
          teamLimitReached={teamLimitReached}
        />
      </section>
    </>
  );
}
