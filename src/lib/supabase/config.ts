const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabasePublishableKey =
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

export function getSupabaseConfig() {
  const missingVariables = [
    !supabaseUrl ? "NEXT_PUBLIC_SUPABASE_URL" : null,
    !supabasePublishableKey
      ? "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"
      : null,
  ].filter((variable): variable is string => Boolean(variable));

  if (!supabaseUrl || !supabasePublishableKey) {
    throw new Error(
      `Missing required Supabase environment variable${
        missingVariables.length === 1 ? "" : "s"
      }: ${missingVariables.join(", ")}`,
    );
  }

  return {
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  };
}
