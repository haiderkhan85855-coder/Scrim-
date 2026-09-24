"use client";

import { useRef } from "react";

import { Container } from "@/components/layout/Container";
import { HeroArtwork } from "@/components/sections/HeroArtwork";
import { Button } from "@/components/ui/Button";
import { bindHeroMouseParallax, playHeroIntro } from "@/lib/animations/hero";
import { gsap, useGSAP } from "@/lib/animations";

const headline = [
  { text: "COMPETE.", accent: false },
  { text: "SURVIVE.", accent: false },
  { text: "DOMINATE.", accent: true },
] as const;

export function Hero({ registrationHref }: { registrationHref: string | null }) {
  const rootRef = useRef<HTMLElement>(null);
  const artworkFrameRef = useRef<HTMLDivElement>(null);
  const artworkMediaRef = useRef<HTMLDivElement>(null);
  const eyebrowRef = useRef<HTMLParagraphElement>(null);
  const descriptionRef = useRef<HTMLParagraphElement>(null);
  const actionsRef = useRef<HTMLDivElement>(null);
  const introPlayedRef = useRef(false);

  useGSAP(
    (_context, contextSafe) => {
      const root = rootRef.current;
      const artworkFrame = artworkFrameRef.current;
      const artworkMedia = artworkMediaRef.current;
      if (!root || !artworkFrame || !artworkMedia) return;

      const lines = root.querySelectorAll<HTMLElement>("[data-hero-line]");
      const revealEls = [
        eyebrowRef.current,
        ...Array.from(lines),
        descriptionRef.current,
        actionsRef.current,
        artworkFrame,
        artworkMedia,
      ].filter(Boolean) as HTMLElement[];

      if (introPlayedRef.current) {
        gsap.set(revealEls, {
          clearProps: "filter",
          opacity: 1,
          y: 0,
          scale: 1,
        });
      } else {
        const intro = playHeroIntro({
          artworkFrame,
          artworkMedia,
          eyebrow: eyebrowRef.current,
          lines,
          description: descriptionRef.current,
          actions: actionsRef.current,
        });
        if (intro) {
          intro.eventCallback("onComplete", () => {
            introPlayedRef.current = true;
          });
        } else {
          introPlayedRef.current = true;
        }
      }

      return bindHeroMouseParallax(
        rootRef,
        artworkMediaRef,
        contextSafe ?? ((func) => func),
      );
    },
    { scope: rootRef },
  );

  return (
    <section
      id="top"
      ref={rootRef}
      className="homepage-hero relative isolate min-h-[39rem] overflow-hidden bg-background pt-[var(--header-height)] text-foreground lg:h-[30rem] lg:min-h-0"
    >
      <HeroArtwork frameRef={artworkFrameRef} mediaRef={artworkMediaRef} />

      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 z-[2] bg-[linear-gradient(180deg,rgba(7,9,11,0.12)_0%,rgba(7,9,11,0.24)_24%,rgba(7,9,11,0.74)_49%,#07090b_78%,#07090b_100%)] lg:bg-[linear-gradient(90deg,#07090b_0%,rgba(7,9,11,0.93)_26%,rgba(7,9,11,0.38)_53%,rgba(7,9,11,0.08)_75%)]"
      />
      <div aria-hidden className="home-grid pointer-events-none absolute inset-0 z-[3] hidden opacity-40 lg:block" />

      <Container className="homepage-hero-content relative z-10 flex min-h-[calc(39rem-var(--header-height))] items-end pb-7 pt-24 sm:pb-8 lg:h-full lg:min-h-0 lg:items-center lg:py-6">
        <div className="w-full max-w-[31rem] lg:max-w-[32rem]">
          <p
            ref={eyebrowRef}
            data-hero-reveal="copy"
            className="text-[0.62rem] font-bold uppercase tracking-[0.24em] text-accent"
          >
            Competitive PUBG Mobile Scrims
          </p>

          <h1 className="type-display mt-3 text-[clamp(2.3rem,10.5vw,3rem)] uppercase leading-[0.88] tracking-[-0.05em] lg:text-[3.7rem] lg:leading-[0.86] lg:tracking-[-0.055em]">
            {headline.map((line) => (
              <span key={line.text} className="block overflow-hidden py-[0.035em]">
                <span
                  data-hero-line
                  data-hero-reveal="line"
                  className={`block ${line.accent ? "text-accent" : "text-[#f4f1ea]"}`}
                >
                  {line.text}
                </span>
              </span>
            ))}
          </h1>

          <p
            ref={descriptionRef}
            data-hero-reveal="copy"
            className="mt-3 max-w-sm text-sm leading-5 text-white/70 sm:text-[0.95rem] lg:mt-4 lg:leading-6"
          >
            Competitive PUBG MOBILE scrims built for squads that take the
            grind seriously.
          </p>

          <div ref={actionsRef} data-hero-reveal="copy">
            <div className="mt-5 flex max-w-md flex-col gap-2.5 sm:max-w-sm lg:mt-6 lg:max-w-none lg:flex-row lg:flex-wrap lg:gap-3">
              <Button
                href={registrationHref ?? "#upcoming-tournaments"}
                className="min-h-11 w-full px-5 lg:w-auto"
              >
                {registrationHref ? "Join Next Scrim" : "View Tournaments"} <ArrowIcon />
              </Button>
              <Button
                href={registrationHref ? "#upcoming-tournaments" : "#how-it-works"}
                variant="secondary"
                className="min-h-11 w-full px-5 lg:w-auto"
              >
                {registrationHref ? "View Tournaments" : "How It Works"}
              </Button>
            </div>
          </div>
        </div>
      </Container>
    </section>
  );
}

function ArrowIcon() {
  return (
    <svg aria-hidden viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none">
      <path d="M3 8h9M9 5l3 3-3 3" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}
