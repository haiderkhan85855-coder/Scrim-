"use client";

import type { RefObject } from "react";

import { gsap, registerGsapPlugins } from "@/lib/animations";

type HeroAnimationTargets = {
  artworkFrame: HTMLElement;
  artworkMedia: HTMLElement;
  eyebrow: HTMLElement | null;
  lines: NodeListOf<HTMLElement>;
  description: HTMLElement | null;
  actions: HTMLElement | null;
};

function prefersReducedMotion(): boolean {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/**
 * Initial hero entrance.
 */
export function playHeroIntro(
  targets: HeroAnimationTargets,
): gsap.core.Timeline | null {
  registerGsapPlugins();

  const {
    eyebrow,
    lines,
    description,
    actions,
    artworkFrame,
    artworkMedia,
  } = targets;

  if (prefersReducedMotion()) {
    gsap.set(
      [
        eyebrow,
        ...Array.from(lines),
        description,
        actions,
        artworkFrame,
        artworkMedia,
      ].filter(Boolean),
      {
        opacity: 1,
        x: 0,
        y: 0,
        scale: 1,
        filter: "none",
      },
    );

    return null;
  }

  gsap.set(artworkFrame, {
    opacity: 0,
  });

  gsap.set(artworkMedia, {
    scale: 1.03,
    x: 0,
    y: 0,
  });

  gsap.set([eyebrow, description, actions].filter(Boolean), {
    opacity: 0,
    y: 22,
    filter: "blur(5px)",
  });

  gsap.set(lines, {
    opacity: 0,
    y: 64,
    filter: "blur(7px)",
  });

  const timeline = gsap.timeline({
    defaults: {
      ease: "power3.out",
    },
    delay: 0.15,
  });

  if (eyebrow) {
    timeline.to(
      eyebrow,
      {
        opacity: 1,
        y: 0,
        filter: "blur(0px)",
        duration: 0.55,
      },
      0,
    );
  }

  timeline.to(
    lines,
    {
      opacity: 1,
      y: 0,
      filter: "blur(0px)",
      duration: 0.8,
      stagger: 0.13,
    },
    0.08,
  );

  if (description) {
    timeline.to(
      description,
      {
        opacity: 1,
        y: 0,
        filter: "blur(0px)",
        duration: 0.6,
      },
      0.52,
    );
  }

  if (actions) {
    timeline.to(
      actions,
      {
        opacity: 1,
        y: 0,
        filter: "blur(0px)",
        duration: 0.55,
      },
      0.65,
    );
  }

  timeline.to(
    artworkFrame,
    {
      opacity: 1,
      duration: 1,
      ease: "power2.out",
    },
    0.32,
  );

  timeline.to(
    artworkMedia,
    {
      scale: 1,
      duration: 1.2,
      ease: "power2.out",
    },
    0.32,
  );

  return timeline;
}

/**
 * Very subtle desktop mouse parallax.
 *
 * No automatic movement.
 */
type ContextSafe = <T extends (...args: never[]) => unknown>(
  func: T,
) => T;

export function bindHeroMouseParallax(
  rootRef: RefObject<HTMLElement | null>,
  mediaRef: RefObject<HTMLElement | null>,
  contextSafe: ContextSafe = (func) => func,
): () => void {
  registerGsapPlugins();

  const root = rootRef.current;
  const media = mediaRef.current;

  if (!root || !media || prefersReducedMotion()) {
    return () => undefined;
  }

  const pointer = window.matchMedia(
    "(pointer: fine) and (min-width: 768px)",
  );

  if (!pointer.matches) {
    return () => undefined;
  }

  const onMove = contextSafe((event: MouseEvent) => {
    const rect = root.getBoundingClientRect();

    const x =
      ((event.clientX - rect.left) / rect.width - 0.5) * 2;

    const y =
      ((event.clientY - rect.top) / rect.height - 0.5) * 2;

    gsap.to(media, {
      x: x * 5,
      y: y * 3,
      duration: 1.15,
      ease: "power3.out",
      overwrite: "auto",
    });
  });

  const onLeave = contextSafe(() => {
    gsap.to(media, {
      x: 0,
      y: 0,
      duration: 1.25,
      ease: "power3.out",
      overwrite: "auto",
    });
  });

  root.addEventListener("mousemove", onMove);
  root.addEventListener("mouseleave", onLeave);

  return () => {
    root.removeEventListener("mousemove", onMove);
    root.removeEventListener("mouseleave", onLeave);

    gsap.set(media, {
      x: 0,
      y: 0,
    });
  };
}
