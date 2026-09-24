import { NextResponse, type NextRequest } from "next/server";

import { updateSession } from "@/lib/supabase/proxy";

export async function proxy(request: NextRequest) {
  if (
    request.nextUrl.pathname === "/" &&
    request.nextUrl.searchParams.has("code")
  ) {
    const confirmationUrl = request.nextUrl.clone();
    confirmationUrl.pathname = "/auth/confirm";

    if (process.env.NODE_ENV !== "production") {
      console.info(
        `[Supabase Auth: callback routing] ${JSON.stringify({
          from: "/",
          to: "/auth/confirm",
          credentialType: "code",
        })}`,
      );
    }

    return NextResponse.redirect(confirmationUrl);
  }

  return updateSession(request);
}

export const config = {
  matcher: [
    "/((?!_next/|favicon.ico|robots.txt|sitemap.xml|.*\\.(?:svg|png|jpg|jpeg|gif|webp|avif|ico|css|js|map|woff|woff2|ttf|otf|txt|xml|webmanifest)$).*)",
  ],
};
