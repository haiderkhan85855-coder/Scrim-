"use client";

import Lenis, { type LenisOptions } from "lenis";

/** Shared Lenis defaults for LEVELLEDUP smooth scrolling. */
export const defaultLenisOptions: LenisOptions = {
  duration: 1.2,
  smoothWheel: true,
  // Driven by the GSAP ticker in SmoothScrollProvider (not Lenis autoRaf).
  autoRaf: false,
};

/** Creates a Lenis instance with project defaults. */
export function createLenis(options: LenisOptions = {}): Lenis {
  return new Lenis({
    ...defaultLenisOptions,
    ...options,
  });
}

export type { LenisOptions };
export { Lenis };
