"use server";

import { revalidatePath } from "next/cache";

import { createClient } from "@/lib/supabase/server";

export type ProfileActionState = {
  error?: string;
  message?: string;
  redirectTo?: "/?profile=updated";
};

type ProfileField = {
  label: string;
  maxLength: number;
  name: "display_name" | "pubg_ign" | "pubg_uid";
};

const profileFields: ProfileField[] = [
  { name: "display_name", label: "Display name", maxLength: 80 },
  { name: "pubg_ign", label: "PUBG IGN", maxLength: 32 },
  { name: "pubg_uid", label: "PUBG UID", maxLength: 32 },
];

function readProfileFields(formData: FormData) {
  const values: Record<ProfileField["name"], string | null> = {
    display_name: null,
    pubg_ign: null,
    pubg_uid: null,
  };

  for (const field of profileFields) {
    const submitted = formData.get(field.name);

    if (typeof submitted !== "string") {
      return { error: `${field.label} must be text.` } as const;
    }

    const value = submitted.trim();

    if (value.length > field.maxLength) {
      return {
        error: `${field.label} must be ${field.maxLength} characters or fewer.`,
      } as const;
    }

    values[field.name] = value || null;
  }

  if (!values.pubg_uid) {
    return { error: "PUBG UID is required." } as const;
  }

  return { values } as const;
}

export async function updateProfile(
  _previousState: ProfileActionState,
  formData: FormData,
): Promise<ProfileActionState> {
  const parsed = readProfileFields(formData);

  if ("error" in parsed) {
    return { error: parsed.error };
  }

  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return { error: "Your session has expired. Sign in again to continue." };
  }

  const { data, error } = await supabase
    .from("profiles")
    .update(parsed.values)
    .eq("id", user.id)
    .select("id")
    .maybeSingle();

  if (error || !data) {
    if (process.env.NODE_ENV !== "production") {
      console.error("[Supabase Profiles: account update]", {
        code: error?.code ?? "profile_not_found",
        message: error?.message ?? "No owned profile row was updated.",
        userReference: user.id.slice(-6),
      });
    }

    return { error: "We could not save your profile. Please try again." };
  }

  revalidatePath("/account");
  return {
    message: "Profile saved",
    redirectTo: "/?profile=updated",
  };
}
