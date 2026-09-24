import type { Metadata } from "next";

import { AuthForm } from "@/components/auth/AuthForm";
import { AuthShell } from "@/components/auth/AuthShell";

export const metadata: Metadata = {
  title: "Create Account | LEVELLEDUP",
};

export default function RegisterPage() {
  return (
    <AuthShell
      eyebrow="New contender"
      title="Join the fight."
      description="Create your account now. Your PUBG identity and squad come later."
    >
      <AuthForm mode="register" />
    </AuthShell>
  );
}
