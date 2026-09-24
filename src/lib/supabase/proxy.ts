import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

import { getSupabaseConfig } from "@/lib/supabase/config";

export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });
  const { url, publishableKey } = getSupabaseConfig();
  const shouldLogAuthFlow =
    process.env.NODE_ENV !== "production" &&
    (request.nextUrl.pathname === "/auth/confirm" ||
      request.nextUrl.pathname === "/account" ||
      request.nextUrl.searchParams.has("code") ||
      request.nextUrl.searchParams.has("token_hash"));
  const incomingAuthCookieCount = request.cookies
    .getAll()
    .filter(({ name }) => name.startsWith("sb-")).length;

  const supabase = createServerClient(url, publishableKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        cookiesToSet.forEach(({ name, value }) => {
          request.cookies.set(name, value);
        });

        response = NextResponse.next({ request });

        cookiesToSet.forEach(({ name, value, options }) => {
          response.cookies.set(name, value, options);
        });

        Object.entries(headers).forEach(([name, value]) => {
          response.headers.set(name, value);
        });
      },
    },
  });

  const { data, error } = await supabase.auth.getClaims();

  if (shouldLogAuthFlow) {
    const subject = data?.claims?.sub;

    console.info(
      `[Supabase Auth: proxy] ${JSON.stringify({
        path: request.nextUrl.pathname,
        hasCode: request.nextUrl.searchParams.has("code"),
        hasTokenHash: request.nextUrl.searchParams.has("token_hash"),
        incomingAuthCookieCount,
        responseAuthCookieCount: response.cookies
          .getAll()
          .filter(({ name }) => name.startsWith("sb-")).length,
        hasVerifiedClaims: Boolean(subject),
        userReference:
          typeof subject === "string" ? subject.slice(-6) : null,
        errorCode: error?.code ?? null,
      })}`,
    );
  }

  return response;
}
