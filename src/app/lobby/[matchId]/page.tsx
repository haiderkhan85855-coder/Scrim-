import Link from "next/link";
import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";
import { getCaptainLobbyState } from "@/app/team/actions";
import CaptainLobbyHost from "@/components/lobby/CaptainLobbyHost";
import type { LobbyState } from "@/components/lobby/PreMatchLobby";

type LobbyPageProps = {
  params: Promise<{ matchId: string }>;
};

export default async function LobbyPage({ params }: LobbyPageProps) {
  const { matchId } = await params;

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const result = await getCaptainLobbyState(matchId);

  return (
    <main className="mx-auto w-full max-w-5xl px-4 py-8 sm:px-6">
      <Link
        href="/team"
        className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted transition-colors hover:text-foreground"
      >
        ← Back to my team
      </Link>

      <div className="mt-4">
        {result.error || !result.data ? (
          <p role="alert" className="text-sm text-red-400">
            {result.error ?? "This lobby could not be loaded."}
          </p>
        ) : (
          <CaptainLobbyHost initialState={result.data as LobbyState} />
        )}
      </div>
    </main>
  );
}
