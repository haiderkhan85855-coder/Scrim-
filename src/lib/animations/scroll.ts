"use client";

import type { ScrollTrigger as ScrollTriggerInstance } from "gsap/ScrollTrigger";

import { gsap, registerGsapPlugins, ScrollTrigger } from "./gsap";

export type SectionScrollSetup = (api: {
  gsap: typeof gsap;
  ScrollTrigger: typeof ScrollTrigger;
  trigger: HTMLElement;
}) => void;

type CreateSectionScrollTriggerOptions = {
  /** Section root used as the ScrollTrigger trigger. */
  trigger: HTMLElement | string;
  /** Extra ScrollTrigger config merged on top of defaults. */
  scrollTrigger?: ScrollTrigger.Vars;
  /** Animation built against the section trigger. */
  animation: (timeline: gsap.core.Timeline) => void;
};

/**
 * Creates a scrubbed timeline pinned to a section.
 * Use this when building landing-page scroll animations section by section.
 */
export function createSectionScrollTrigger({
  trigger,
  scrollTrigger,
  animation,
}: CreateSectionScrollTriggerOptions): gsap.core.Timeline {
  registerGsapPlugins();

  const timeline = gsap.timeline({
    scrollTrigger: {
      trigger,
      start: "top top",
      end: "+=100%",
      scrub: true,
      ...scrollTrigger,
    },
  });

  animation(timeline);
  return timeline;
}

/**
 * Runs a scoped GSAP setup for one section and cleans up on unmount via gsap.context.
 * Prefer this from React section components / hooks.
 */
export function runSectionAnimation(
  scope: HTMLElement,
  setup: SectionScrollSetup,
): () => void {
  registerGsapPlugins();

  const ctx = gsap.context(() => {
    setup({ gsap, ScrollTrigger, trigger: scope });
  }, scope);

  return () => {
    ctx.revert();
  };
}

/** Refresh ScrollTrigger after layout changes (images, fonts, route transitions). */
export function refreshScrollTrigger(): void {
  registerGsapPlugins();
  ScrollTrigger.refresh();
}

export type { ScrollTriggerInstance };
