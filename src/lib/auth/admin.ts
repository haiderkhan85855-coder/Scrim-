import "server-only";

import { createClient } from "@/lib/supabase/server";

export type AdminRole = "admin" | "super_admin";

export type AdminAccess = {
  userId: string;
  role: AdminRole;
};

function isAdminRole(value: unknown): value is AdminRole {
  return value === "admin" || value === "super_admin";
}

export async function getCurrentAdminAccess(): Promise<AdminAccess | null> {
  const supabase = await createClient();
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return null;
  }

  const { data: role, error: roleError } = await supabase.rpc(
    "levelledup_current_admin_role",
  );

  if (roleError || !isAdminRole(role)) {
    return null;
  }

  return {
    userId: user.id,
    role,
  };
}

export function hasRequiredAdminRole(
  access: AdminAccess | null,
  requiredRole: AdminRole = "admin",
) {
  if (!access) {
    return false;
  }

  return (
    access.role === "super_admin" ||
    (requiredRole === "admin" && access.role === "admin")
  );
}
