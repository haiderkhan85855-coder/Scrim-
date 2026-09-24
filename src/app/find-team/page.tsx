import type { Metadata } from "next";
import { redirect } from "next/navigation";

import {
  FindTeamExperience,
  type RecruitmentListing,
} from "@/components/team/FindTeamExperience";
import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "Find a Team | LEVELLEDUP",
};

type RecruitmentListingRow = {
  team_name: string;
  team_public_id: string;
  mic_required: boolean;
  captain_note: string | null;
};

export default async function FindTeamPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const [recruitmentResult, membershipResult] = await Promise.all([
    supabase.rpc("levelledup_list_open_team_recruitment"),
    supabase
      .from("team_roster_members")
      .select("team_id", { count: "exact", head: true })
      .eq("profile_id", user.id)
      .eq("status", "active"),
  ]);

  if (recruitmentResult.error) {
    console.error("[Supabase Teams: open recruitment listing]", {
      code: recruitmentResult.error.code,
      message: recruitmentResult.error.message,
      userReference: user.id.slice(-6),
    });
    throw new Error("Unable to load open recruitment posts.");
  }

  if (membershipResult.error) {
    console.error("[Supabase Teams: membership count]", {
      code: membershipResult.error.code,
      message: membershipResult.error.message,
      userReference: user.id.slice(-6),
    });
    throw new Error("Unable to verify active team memberships.");
  }

  const listings = (
    (recruitmentResult.data ?? []) as RecruitmentListingRow[]
  ).map<RecruitmentListing>((listing) => ({
    teamName: listing.team_name,
    teamPublicId: listing.team_public_id,
    micRequired: listing.mic_required,
    captainNote: listing.captain_note,
  }));
  const teamLimitReached = (membershipResult.count ?? 0) >= 3;

  return (
    <>
      <AuthenticatedHeader />
      <main className="min-h-svh px-5 pb-12 pt-[calc(var(--header-height)+3rem)] sm:px-8 sm:pb-16 lg:px-10 lg:pb-20">
      <div className="mx-auto w-full max-w-7xl">
        <FindTeamExperience
          listings={listings}
          teamLimitReached={teamLimitReached}
        />
      </div>
      </main>
    </>
  );
}
