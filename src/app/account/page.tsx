import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ProfileForm } from "@/components/auth/ProfileForm";
import { AuthenticatedHeader } from "@/components/layout/AuthenticatedHeader";
import { createClient } from "@/lib/supabase/server";
import { currencyFractionDigits } from "@/lib/tournaments/money";

export const metadata: Metadata = {
  title: "Account | LEVELLEDUP",
};

type Profile = {
  display_name: string | null;
  pubg_ign: string | null;
  pubg_uid: string | null;
  avatar_url: string | null;
};

type CreditBalance = {
  currency: string;
  balance_minor: number;
};

function formatMoney(value: number, currency: string) {
  const fractionDigits = currencyFractionDigits(currency);
  const amount = value / 10 ** fractionDigits;
  try {
    return new Intl.NumberFormat("en-PK", {
      style: "currency",
      currency,
      minimumFractionDigits: 0,
      maximumFractionDigits: fractionDigits,
    }).format(amount);
  } catch {
    return `${currency} ${amount}`;
  }
}

function profileValue(value: string | null | undefined) {
  return value?.trim() || "Not set";
}

function validAvatarUrl(value: string | null | undefined) {
  if (!value) return null;

  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:"
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}

export default async function AccountPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (process.env.NODE_ENV !== "production") {
    console.info(
      `[Supabase Auth: account page] ${JSON.stringify({
        hasUser: Boolean(user),
        userReference: user?.id.slice(-6) ?? null,
      })}`,
    );
  }

  if (!user) {
    redirect("/login");
  }

  const { data, error: profileError } = await supabase
    .from("profiles")
    .select("display_name, pubg_ign, pubg_uid, avatar_url")
    .eq("id", user.id)
    .maybeSingle();

  if (profileError) {
    console.error("[Supabase Profiles: account read]", {
      code: profileError.code,
      message: profileError.message,
    });
    throw new Error("Unable to load the account profile.");
  }

  const profile = (data as Profile | null) ?? {
    display_name: null,
    pubg_ign: null,
    pubg_uid: null,
    avatar_url: null,
  };
  const avatarUrl = validAvatarUrl(profile?.avatar_url);
  const { data: balanceData, error: balanceError } = await supabase.rpc(
    "levelledup_get_my_credit_balances",
  );

  if (balanceError) {
    console.error("[LevelledUp credit: account balance]", {
      code: balanceError.code,
      message: balanceError.message,
    });
    throw new Error("Unable to load the account credit balance.");
  }

  const creditBalances = (balanceData ?? []) as CreditBalance[];

  return (
    <>
      <AuthenticatedHeader />
      <main className="flex min-h-svh items-center justify-center px-5 pb-12 pt-[calc(var(--header-height)+3rem)] sm:px-8">
      <section className="relative w-full max-w-2xl overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated/90 p-7 sm:p-10">
        <span
          className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-accent via-accent/35 to-transparent"
          aria-hidden="true"
        />
        <p className="type-eyebrow text-accent">Account</p>
        <h1 className="type-display mt-5 text-[clamp(2.6rem,9vw,5rem)] uppercase">
          Your account.
        </h1>
        <div className="mt-7 flex items-start gap-5 border-y border-border py-6">
          {avatarUrl ? (
            // Profile media can be hosted outside the app's configured image origins.
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={avatarUrl}
              alt={`${profileValue(profile?.display_name)} avatar`}
              className="size-16 shrink-0 rounded-[2px] border border-border-strong object-cover sm:size-20"
            />
          ) : null}

          <div className="min-w-0">
            <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
              Email
            </p>
            <p className="mt-2 break-all text-sm font-medium text-foreground">
              {user.email ?? "Authenticated user"}
            </p>
          </div>
        </div>

        <div className="border-b border-border py-6">
          <p className="text-[0.6rem] font-semibold uppercase tracking-[0.18em] text-foreground-muted">
            LevelledUp credit
          </p>
          {creditBalances.length ? (
            <div className="mt-3 flex flex-wrap gap-2">
              {creditBalances.map((balance) => (
                <span key={balance.currency} className="border border-[#79d49b]/35 px-3 py-2 text-sm font-semibold text-[#79d49b]">
                  {formatMoney(balance.balance_minor, balance.currency)} available
                </span>
              ))}
            </div>
          ) : (
            <p className="mt-2 text-sm text-foreground-muted">No available credit.</p>
          )}
          <p className="mt-3 text-xs leading-5 text-foreground-muted">
            Credit follows the verified payer profile and remains here if a team is disbanded.
          </p>
        </div>

        <ProfileForm profile={profile} />
      </section>
      </main>
    </>
  );
}
