"use client";

import { useEffect, useRef } from "react";

import {
  runSectionAnimation,
  type SectionScrollSetup,
} from "@/lib/animations";

/**
 * Attaches a scroll-animation setup to a section element.
 * Returns a ref to place on the section root.
 *
 * Example (later, when building sections):
 * const sectionRef = useSectionAnimation(({ gsap, trigger }) => {
 *   gsap.from(trigger.querySelectorAll("[data-animate]"), {
 *     opacity: 0,
 *     y: 40,
 *     scrollTrigger: { trigger, start: "top 80%" },
 *   });
 * });
 */
export function useSectionAnimation(setup: SectionScrollSetup) {
  const sectionRef = useRef<HTMLElement | null>(null);
  const setupRef = useRef(setup);

  useEffect(() => {
    setupRef.current = setup;
  }, [setup]);

  useEffect(() => {
    const section = sectionRef.current;
    if (!section) return;

    return runSectionAnimation(section, (api) => setupRef.current(api));
  }, []);

  return sectionRef;
}
