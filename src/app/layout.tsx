import type { Metadata } from "next";
import { IBM_Plex_Sans, Syne } from "next/font/google";

import { SmoothScrollProvider } from "@/components/providers/SmoothScrollProvider";

import "./globals.css";

const syne = Syne({
  variable: "--font-display",
  subsets: ["latin"],
  weight: ["600", "700", "800"],
  display: "swap",
});

const ibmPlexSans = IBM_Plex_Sans({
  variable: "--font-body",
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  display: "swap",
});

export const metadata: Metadata = {
  title: "LEVELLEDUP",
  description:
    "Premium competitive PUBG MOBILE scrim platform — tournaments built for serious squads.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${syne.variable} ${ibmPlexSans.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col bg-background text-foreground">
        <SmoothScrollProvider>
          <div className="page-atmosphere flex min-h-full flex-1 flex-col">
            {children}
          </div>
        </SmoothScrollProvider>
      </body>
    </html>
  );
}
