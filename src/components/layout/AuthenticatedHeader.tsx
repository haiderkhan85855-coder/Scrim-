import { Header } from "@/components/layout/Header";
import {
  getCurrentAdminAccess,
  hasRequiredAdminRole,
} from "@/lib/auth/admin";
import { createClient } from "@/lib/supabase/server";

export async function AuthenticatedHeader() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const adminAccess = user ? await getCurrentAdminAccess() : null;

  if (process.env.NODE_ENV !== "production") {
    console.info(
      `[Supabase Auth: shared header] ${JSON.stringify({
        hasAdminAccess: hasRequiredAdminRole(adminAccess),
        hasUser: Boolean(user),
        userReference: user?.id.slice(-6) ?? null,
      })}`,
    );
  }

  return (
    <Header
      hasAdminAccess={hasRequiredAdminRole(adminAccess)}
      isAuthenticated={Boolean(user)}
    />
  );
}
