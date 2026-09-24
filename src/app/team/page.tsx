import type { Metadata } from "next";
import { redirect } from "next/navigation";

import {
  TeamDashboard,
  type CancelledTournamentHistory,
  type PendingJoinRequest,
  type TeamMembership,
  type TeamRole,
  type TeamRosterMember,
} from "@/components/team/TeamDashboard";
import type { PendingLeaveRequest } from "@/components/team/TeamSupportAndLeave";
import { TeamOnboarding } from "@/components/team/TeamOnboarding";
import type { PendingDisbandRequest } from "@/components/team/TeamManagementControls";
import type { TeamRecruitmentPost } from "@/components/team/TeamRecruitmentPanel";
import { Button } from "@/components/ui/Button";
import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import { createClient } from "@/lib/supabase/server";
import { currencyFractionDigits } from "@/lib/tournaments/money";

export const metadata: Metadata = {
  title: "My Team | LEVELLEDUP",
};

type ActiveMembership = {
  team_id: string;
  role: TeamRole;
};

type Team = {
  id: string;
  name: string;
  team_id: string;
  short_name: string | null;
  logo_url: string | null;
};

type ProfileIdentity = {
  display_name: string | null;
  pubg_ign: string | null;
  pubg_uid: string | null;
};

type RosterMemberRow = {
  id: string;
  team_id: string;
  profile_id: string | null;
  display_name: string;
  pubg_ign: string | null;
  pubg_uid: string;
  role: TeamRole;
};

type PendingJoinRequestRow = {
  request_id: string;
  team_id: string;
  display_name: string;
  pubg_ign: string | null;
  pubg_uid: string;
  requested_at: string;
};

type PendingLeaveRequestRow = {
  id: string;
  requester_name: string;
  is_own_request: boolean;
  created_at: string;
};

type RecruitmentPostRow = {
  team_id: string;
  mic_required: boolean;
  captain_note: string | null;
  status: "open" | "closed";
};

type TournamentRegistrationRow = {
  id: string; tournament_id: string; team_id: string;
  status: "pending" | "confirmed" | "rejected" | "withdrawn";
  slot_number: number | null;
};
type CancelledTournamentRow = { id: string; name: string; tournament_id: string };
type TournamentCreditRow = {
  registration_id: string; amount_minor: number; currency: string;
  status: "available" | "used" | "refunded";
};
type TournamentPaymentRow = { registration_id: string; reference_id: string | null; status: string };
type TournamentAssignmentRow = { registration_id: string; slot_number: number; assigned_at: string };

function formatMoney(value: number, currency: string) {
  const fractionDigits = currencyFractionDigits(currency);
  const amount = value / 10 ** fractionDigits;
  try {
    return new Intl.NumberFormat("en-PK", {
      style: "currency", currency, minimumFractionDigits: 0,
      maximumFractionDigits: fractionDigits,
    }).format(amount);
  } catch {
    return `${currency} ${amount}`;
  }
}

export default async function TeamPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const [membershipResult, profileResult] = await Promise.all([
    supabase
      .from("team_roster_members")
      .select("team_id, role")
      .eq("profile_id", user.id)
      .eq("status", "active")
      .order("created_at", { ascending: false }),
    supabase
      .from("profiles")
      .select("display_name, pubg_ign, pubg_uid")
      .eq("id", user.id)
      .maybeSingle(),
  ]);

  const { data: membershipData, error: membershipError } = membershipResult;

  if (membershipError) {
    console.error("[Supabase Teams: active membership read]", {
      code: membershipError.code,
      message: membershipError.message,
      userReference: user.id.slice(-6),
    });
    throw new Error("Unable to load team membership.");
  }

  const memberships = (membershipData ?? []) as ActiveMembership[];
  const { data: profileData, error: profileError } = profileResult;

  if (profileError) {
    console.error("[Supabase Teams: creator profile read]", {
      code: profileError.code,
      message: profileError.message,
      userReference: user.id.slice(-6),
    });
    throw new Error("Unable to load player profile.");
  }

  const profile = profileData as ProfileIdentity | null;
  const canCreateTeam = Boolean(
    profile?.display_name?.trim() &&
      profile.pubg_uid?.trim(),
  );
  let teams: TeamMembership[] = [];
  let roster: TeamRosterMember[] = [];
  let pendingRequests: PendingJoinRequest[] = [];
  let leaveRequests: PendingLeaveRequest[] = [];
  let recruitmentPosts: TeamRecruitmentPost[] = [];
  let cancelledTournaments: CancelledTournamentHistory[] = [];
  let disbandRequests: {
    teamId: string;
    request: PendingDisbandRequest | null;
  }[] = [];

  if (memberships.length > 0) {
    const membershipTeamIds = memberships.map(
      (membership) => membership.team_id,
    );
    const { data: teamData, error: teamError } = await supabase
      .from("teams")
      .select("id, name, team_id, short_name, logo_url")
      .in("id", membershipTeamIds);

    if (teamError) {
      console.error("[Supabase Teams: team read]", {
        code: teamError.code,
        message: teamError.message,
        userReference: user.id.slice(-6),
      });
      throw new Error("Unable to load team details.");
    }

    const teamById = new Map(
      ((teamData ?? []) as Team[]).map((team) => [team.id, team]),
    );

    const nameDisplayResults = await Promise.all(
      membershipTeamIds.map(async (teamId) => {
        const { data, error } = await supabase.rpc(
          "levelledup_get_team_name_display",
          { p_team_id: teamId },
        );
        if (error) {
          console.error("[Supabase Teams: name display read]", {
            code: error.code,
            message: error.message,
            userReference: user.id.slice(-6),
          });
          throw new Error("Unable to load team name history.");
        }
        const row = (Array.isArray(data) ? data[0] : null) as {
          name: string;
          former_name: string | null;
        } | null;
        return { teamId, formerName: row?.former_name ?? null };
      }),
    );
    const formerNameByTeam = new Map(
      nameDisplayResults.map((entry) => [entry.teamId, entry.formerName]),
    );

    teams = memberships.map((membership) => {
      const team = teamById.get(membership.team_id);

      if (!team) {
        throw new Error("Unable to match an active team membership.");
      }

      return {
        id: team.id,
        name: team.name,
        formerName: formerNameByTeam.get(membership.team_id) ?? null,
        teamId: team.team_id,
        shortName: team.short_name,
        logoUrl: team.logo_url,
        role: membership.role,
      };
    });

    const disbandResults = await Promise.all(
      membershipTeamIds.map(async (teamId) => {
        const { data, error } = await supabase.rpc(
          "levelledup_get_team_disband_request",
          { p_team_id: teamId },
        );
        if (error) {
          console.error("[Supabase Teams: disband request read]", {
            code: error.code,
            message: error.message,
            userReference: user.id.slice(-6),
          });
          throw new Error("Unable to load disband request details.");
        }
        const payload = (data ?? {}) as {
          request: PendingDisbandRequest | null;
        };
        return { teamId, request: payload.request };
      }),
    );
    disbandRequests = disbandResults;

    const { data: rosterData, error: rosterError } = await supabase
      .from("team_roster_members")
      .select(
        "id, team_id, profile_id, display_name, pubg_ign, pubg_uid, role",
      )
      .in("team_id", membershipTeamIds)
      .eq("status", "active")
      .order("created_at", { ascending: true });

    if (rosterError) {
      console.error("[Supabase Teams: roster read]", {
        code: rosterError.code,
        message: rosterError.message,
        userReference: user.id.slice(-6),
      });
      throw new Error("Unable to load active team Squads.");
    }

    roster = ((rosterData ?? []) as RosterMemberRow[])
      .map((member) => ({
        id: member.id,
        teamId: member.team_id,
        displayName: member.display_name,
        pubgIgn: member.pubg_ign?.trim() || "Not provided",
        pubgUid: member.pubg_uid,
        role: member.role,
        isClaimed: member.profile_id !== null,
        isCurrentUser: member.profile_id === user.id,
      }))
      .sort((left, right) => {
        const roleOrder: Record<TeamRole, number> = {
          captain: 0,
          co_captain: 1,
          player: 2,
        };

        return roleOrder[left.role] - roleOrder[right.role];
      });

    const { data: recruitmentData, error: recruitmentError } = await supabase
      .from("team_recruitment_posts")
      .select("team_id, mic_required, captain_note, status")
      .in("team_id", membershipTeamIds);

    if (recruitmentError) {
      console.error("[Supabase Teams: recruitment read]", {
        code: recruitmentError.code,
        message: recruitmentError.message,
        userReference: user.id.slice(-6),
      });
      throw new Error("Unable to load team recruitment.");
    }

    recruitmentPosts = (
      (recruitmentData ?? []) as RecruitmentPostRow[]
    ).map((post) => ({
      teamId: post.team_id,
      micRequired: post.mic_required,
      captainNote: post.captain_note,
      status: post.status,
    }));

    const { data: registrationData, error: registrationError } = await supabase
      .from("tournament_registrations")
      .select("id, tournament_id, team_id, status, slot_number")
      .in("team_id", membershipTeamIds);

    if (registrationError) {
      console.error("[Supabase Teams: tournament history read]", {
        code: registrationError.code,
        message: registrationError.message,
        userReference: user.id.slice(-6),
      });
      throw new Error("Unable to load team tournament history.");
    }

    const registrationRows = (registrationData ?? []) as TournamentRegistrationRow[];
    const tournamentIds = [...new Set(registrationRows.map((registration) => registration.tournament_id))];
    const { data: cancelledTournamentData, error: cancelledTournamentError } = tournamentIds.length
      ? await supabase.from("tournaments")
          .select("id, name, tournament_id")
          .in("id", tournamentIds)
          .eq("status", "cancelled")
      : { data: [] as CancelledTournamentRow[], error: null };

    if (cancelledTournamentError) throw new Error("Unable to load cancelled tournament history.");

    const cancelledTournamentRows = (cancelledTournamentData ?? []) as CancelledTournamentRow[];
    const cancelledTournamentById = new Map(cancelledTournamentRows.map((tournament) => [tournament.id, tournament]));
    const cancelledRegistrations = registrationRows.filter((registration) => cancelledTournamentById.has(registration.tournament_id));
    const cancelledRegistrationIds = cancelledRegistrations.map((registration) => registration.id);

    if (cancelledRegistrationIds.length) {
      const [creditResult, paymentResult, assignmentResult] = await Promise.all([
        supabase.rpc("levelledup_get_my_tournament_credits"),
        supabase.from("tournament_registration_payments")
          .select("registration_id, reference_id, status")
          .in("registration_id", cancelledRegistrationIds)
          .order("submitted_at", { ascending: false }),
        supabase.from("tournament_stage_assignments")
          .select("registration_id, slot_number, assigned_at")
          .in("registration_id", cancelledRegistrationIds)
          .order("assigned_at", { ascending: false }),
      ]);

      if (creditResult.error || paymentResult.error || assignmentResult.error) {
        console.error("[Supabase Teams: cancelled tournament details]", {
          creditError: creditResult.error?.message ?? null,
          paymentError: paymentResult.error?.message ?? null,
          assignmentError: assignmentResult.error?.message ?? null,
        });
        throw new Error("Unable to load cancelled tournament details.");
      }

      const credits = (creditResult.data ?? []) as TournamentCreditRow[];
      const payments = (paymentResult.data ?? []) as TournamentPaymentRow[];
      const assignments = (assignmentResult.data ?? []) as TournamentAssignmentRow[];

      cancelledTournaments = cancelledRegistrations.map((registration) => {
        const tournament = cancelledTournamentById.get(registration.tournament_id)!;
        const credit = credits.find((item) => item.registration_id === registration.id);
        const verifiedPayment = payments.find((item) =>
          item.registration_id === registration.id && item.status === "verified"
        );
        const assignment = assignments.find((item) => item.registration_id === registration.id);

        return {
          id: registration.id,
          teamId: registration.team_id,
          tournamentName: tournament.name,
          tournamentId: tournament.tournament_id,
          registrationStatus: registration.status,
          previousSlot: assignment?.slot_number ?? registration.slot_number,
          creditAmount: credit ? formatMoney(credit.amount_minor, credit.currency) : null,
          creditStatus: credit?.status ?? null,
          paymentReference: verifiedPayment?.reference_id ?? null,
        };
      });
    }

    if (memberships.some((membership) => membership.role === "captain")) {
      const { data: requestData, error: requestError } = await supabase.rpc(
        "levelledup_get_pending_join_requests",
      );

      if (requestError) {
        console.error("[Supabase Teams: pending join requests read]", {
          code: requestError.code,
          message: requestError.message,
          userReference: user.id.slice(-6),
        });
        throw new Error("Unable to load pending team requests.");
      }

      pendingRequests = (
        (requestData ?? []) as PendingJoinRequestRow[]
      ).map((request) => ({
        id: request.request_id,
        teamId: request.team_id,
        displayName: request.display_name,
        pubgIgn: request.pubg_ign?.trim() || "Not provided",
        pubgUid: request.pubg_uid,
        requestedAt: request.requested_at,
      }));
    }

    // Pending leave requests for every team the viewer belongs to (captains
    // see all pending requests; members see only their own).
    const leaveRequestRows = await Promise.all(
      membershipTeamIds.map(async (teamId) => {
        const { data, error } = await supabase.rpc(
          "levelledup_list_team_leave_requests",
          { p_team_id: teamId },
        );
        if (error) {
          console.error("[Supabase Teams: leave requests read]", {
            code: error.code,
            message: error.message,
            userReference: user.id.slice(-6),
          });
          throw new Error("Unable to load pending leave requests.");
        }
        return ((data ?? []) as PendingLeaveRequestRow[]).map((request) => ({
          id: request.id,
          teamId,
          requesterName: request.requester_name,
          isOwnRequest: request.is_own_request,
          createdAt: request.created_at,
        }));
      }),
    );
    leaveRequests = leaveRequestRows.flat();
  }

  return (
    <>
      <AuthenticatedHeader />
      <main className="min-h-svh px-5 pb-12 pt-[calc(var(--header-height)+3rem)] sm:px-8 sm:pb-16 lg:px-10 lg:pb-20">
      <div className="mx-auto w-full max-w-7xl">
        {teams.length > 0 ? (
          <TeamDashboard
            cancelledTournaments={cancelledTournaments}
            teams={teams}
            roster={roster}
            pendingRequests={pendingRequests}
            leaveRequests={leaveRequests}
            recruitmentPosts={recruitmentPosts}
            disbandRequests={disbandRequests}
            canCreate={canCreateTeam}
          />
        ) : (
          <section className="relative mx-auto w-full max-w-2xl overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated/90 p-7 sm:p-10">
            <span
              className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-accent via-accent/35 to-transparent"
              aria-hidden="true"
            />
            <p className="type-eyebrow text-accent">My team</p>
            <h1 className="type-display mt-5 text-[clamp(2.6rem,9vw,5rem)] uppercase">
              Find your squad.
            </h1>
            <p className="mt-5 max-w-lg text-sm leading-7 text-foreground-muted">
              You are not part of an active team yet. Find an existing squad
              with its permanent Team ID, or create your own.
            </p>

            <Button href="/find-team" variant="secondary" className="mt-6">
              Browse Recruiting Teams
            </Button>

            <TeamOnboarding canCreate={canCreateTeam} />
          </section>
        )}
      </div>
      </main>
    </>
  );
}
