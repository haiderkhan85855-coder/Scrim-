import type { Metadata } from "next";

import { AuthForm } from "@/components/auth/AuthForm";
import { AuthShell } from "@/components/auth/AuthShell";

export const metadata: Metadata = {
  title: "Sign In | LEVELLEDUP",
};

type LoginPageProps = {
  searchParams: Promise<{
    error?: string | string[];
    next?: string | string[];
  }>;
};

function safeNextPath(value: string | string[] | undefined) {
  if (
    typeof value !== "string" ||
    !value.startsWith("/") ||
    value.startsWith("//") ||
    value.includes("\\")
  ) {
    return undefined;
  }

  return value;
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const params = await searchParams;
  const initialError =
    params.error === "confirmation_failed"
      ? "That confirmation link is invalid or has expired."
      : undefined;
  const nextPath = safeNextPath(params.next);

  return (
    <AuthShell
      eyebrow="Player access"
      title="Enter the arena."
      description="Sign in to continue to your LevelledUp account."
    >
      <AuthForm
        mode="login"
        initialError={initialError}
        nextPath={nextPath}
      />
    </AuthShell>
  );
}
