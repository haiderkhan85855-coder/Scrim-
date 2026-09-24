import type { EmailOtpType } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { type NextRequest, NextResponse } from "next/server";

import { createClient } from "@/lib/supabase/server";

function isConfirmationType(type: string | null): type is EmailOtpType {
  return type === "email" || type === "signup";
}

export async function GET(request: NextRequest) {
  const tokenHash = request.nextUrl.searchParams.get("token_hash");
  const type = request.nextUrl.searchParams.get("type");
  const code = request.nextUrl.searchParams.get("code");
  const cookieStore = await cookies();
  const incomingAuthCookieCount = cookieStore
    .getAll()
    .filter(({ name }) => name.startsWith("sb-")).length;
  const supabase = await createClient();

  let confirmationError = null;
  let exchangeSucceeded = false;
  let hasSession = false;
  let confirmedUserReference: string | null = null;

  if (tokenHash && isConfirmationType(type)) {
    const { data, error } = await supabase.auth.verifyOtp({
      token_hash: tokenHash,
      type,
    });
    confirmationError = error;
    exchangeSucceeded = !error;
    hasSession = Boolean(data.session);
    confirmedUserReference = data.user?.id.slice(-6) ?? null;
  } else if (code) {
    const { data, error } = await supabase.auth.exchangeCodeForSession(code);
    confirmationError = error;
    exchangeSucceeded = !error;
    hasSession = Boolean(data.session);
    confirmedUserReference = data.user?.id.slice(-6) ?? null;
  } else {
    confirmationError = new Error("Missing confirmation credentials.");
  }

  let verifiedUserReference: string | null = null;

  if (!confirmationError) {
    const {
      data: { user },
      error,
    } = await supabase.auth.getUser();

    if (error) {
      confirmationError = error;
    } else {
      verifiedUserReference = user?.id.slice(-6) ?? null;
    }
  }

  if (process.env.NODE_ENV !== "production") {
    const outgoingAuthCookieCount = cookieStore
      .getAll()
      .filter(({ name }) => name.startsWith("sb-")).length;
    const errorCode =
      confirmationError && "code" in confirmationError
        ? String(confirmationError.code)
        : confirmationError
          ? "missing_confirmation_credentials"
          : null;

    console.info(
      `[Supabase Auth: confirmation callback] ${JSON.stringify({
        credentialType: tokenHash ? "token_hash" : code ? "code" : "missing",
        exchangeSucceeded,
        hasSession,
        confirmedUserReference,
        verifiedUserReference,
        userValidationSucceeded: Boolean(verifiedUserReference),
        incomingAuthCookieCount,
        outgoingAuthCookieCount,
        errorCode,
      })}`,
    );
  }

  const redirectTo = request.nextUrl.clone();
  redirectTo.search = "";

  if (!confirmationError) {
    redirectTo.pathname = "/welcome";
    return NextResponse.redirect(redirectTo);
  }

  redirectTo.pathname = "/login";
  redirectTo.searchParams.set("error", "confirmation_failed");
  return NextResponse.redirect(redirectTo);
}
