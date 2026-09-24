"use client";

import Image from "next/image";

import { Button } from "@/components/ui/Button";
import { useSectionAnimation } from "@/hooks/useSectionAnimation";

export function FinalCTA({ registrationHref }: { registrationHref: string | null }) {
  const sectionRef = useSectionAnimation(({ gsap, trigger }) => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timeline = gsap.timeline({
      scrollTrigger: { trigger, start: "top 84%", once: true },
    });

    timeline
      .from(
        trigger.querySelector("[data-final-artwork]"),
        {
          scale: 1.035,
          duration: 1.2,
          ease: "power2.out",
        },
        0,
      )
      .from(
        trigger.querySelectorAll("[data-final-reveal]"),
        {
          autoAlpha: 0,
          y: 20,
          duration: 0.7,
          stagger: 0.08,
          ease: "power3.out",
        },
        0.12,
      );
  });

  return (
    <section
      ref={sectionRef}
      id="join"
      className="final-cta-artwork relative isolate flex min-h-[34rem] scroll-mt-16 items-center overflow-hidden px-[var(--container-pad)] py-10 text-center sm:min-h-[36rem] md:min-h-[24rem] md:py-10 xl:min-h-[19rem] xl:py-12"
    >
      <div data-final-artwork aria-hidden className="absolute inset-0 -z-20 overflow-hidden will-change-transform">
        <Image
          src="/images/final-cta-mobile-bg.png"
          alt=""
          fill
          sizes="(max-width: 767px) 100vw, 1px"
          className="final-cta-mobile-artwork-media object-cover md:hidden"
        />
        <Image
          src="/images/final-cta-bg.png"
          alt=""
          fill
          sizes="(min-width: 768px) 100vw, 1px"
          className="final-cta-artwork-media hidden object-cover md:block"
        />
      </div>
      <div aria-hidden className="final-cta-artwork-overlay absolute inset-0 -z-10" />
      <div aria-hidden className="home-grid absolute inset-0 -z-10 opacity-20" />
      <div className="mx-auto w-full max-w-4xl">
        <p data-final-reveal className="text-[0.58rem] font-bold uppercase tracking-[0.28em] text-accent">Final Call</p>
        <h2 data-final-reveal className="type-display mt-2.5 text-[clamp(2.3rem,10vw,3.4rem)] uppercase leading-[0.9] tracking-[-0.05em] text-white lg:mt-3 lg:text-[3.35rem]">
          Ready to drop?
        </h2>
        <p data-final-reveal className="mx-auto mt-3 max-w-xl text-sm leading-6 text-white/65">
          Your squad is waiting. Claim your slot and meet them on the battleground.
        </p>
        <div data-final-reveal className="mx-auto mt-5 flex max-w-md flex-col justify-center gap-2.5 sm:flex-row lg:mt-6 lg:max-w-none lg:gap-3">
          <Button href={registrationHref ?? "#upcoming-tournaments"} className="min-h-11 w-full px-6 sm:w-auto">
            {registrationHref ? "Join the next scrim" : "View tournaments"} <ArrowIcon />
          </Button>
          <Button href={registrationHref ? "#upcoming-tournaments" : "/leaderboard"} variant="secondary" className="min-h-11 w-full border-white/25 bg-black/30 px-6 sm:w-auto">
            {registrationHref ? "View tournaments" : "View leaderboard"}
          </Button>
        </div>
      </div>
    </section>
  );
}

function ArrowIcon() {
  return <svg aria-hidden viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none"><path d="M3 8h9M9 5l3 3-3 3" stroke="currentColor" strokeWidth="1.4" /></svg>;
}
