"use client";

import Image from "next/image";
import type { Ref } from "react";

type HeroArtworkProps = {
  frameRef?: Ref<HTMLDivElement>;
  mediaRef?: Ref<HTMLDivElement>;
};

export function HeroArtwork({ frameRef, mediaRef }: HeroArtworkProps) {
  return (
    <div
      ref={frameRef}
      className="pointer-events-none absolute inset-0 z-0 overflow-hidden lg:inset-x-0 lg:bottom-0 lg:top-[var(--header-height)]"
    >
      <div
        ref={mediaRef}
        className="absolute inset-0 will-change-transform lg:-inset-1"
        style={{ transformOrigin: "72% 42%" }}
      >
        <Image
          src="/images/levelledup-hero.png"
          alt="Tactical operator overlooking a cinematic PUBG MOBILE battleground"
          fill
          priority
          quality={90}
          sizes="100vw"
          className="object-cover object-[62%_30%] sm:object-[64%_28%] lg:object-[64%_18%]"
        />
      </div>

      <div
        aria-hidden
        className="absolute inset-0 bg-[linear-gradient(180deg,rgba(7,9,11,0.08)_0%,transparent_32%,rgba(7,9,11,0.45)_62%,#07090b_100%)] lg:hidden"
      />

      <div
        aria-hidden
        className="absolute inset-0 bg-[radial-gradient(ellipse_at_72%_42%,rgba(255,86,28,0.18),transparent_48%)] mix-blend-screen"
      />
      <div
        aria-hidden
        className="absolute inset-0 bg-[radial-gradient(ellipse_at_center,transparent_38%,rgba(3,4,5,0.8)_100%)]"
      />
    </div>
  );
}
