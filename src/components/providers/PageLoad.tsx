"use client";

import { useLayoutEffect, useRef, type ReactNode } from "react";

import { gsap } from "@/lib/animations";

type PageLoadProps = {
  children: ReactNode;
};

/**
 * Short progressive-enhancement entrance so the hero intro stays visible.
 * The page remains visible before hydration and if animation setup fails.
 */
export function PageLoad({ children }: PageLoadProps) {
  const rootRef = useRef<HTMLDivElement>(null);
  const playedRef = useRef(false);

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return;

    const prefersReducedMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;

    if (prefersReducedMotion || playedRef.current) {
      gsap.set(root, { clearProps: "all", opacity: 1 });
      playedRef.current = true;
      return;
    }

    const tween = gsap.fromTo(
      root,
      { opacity: 0.85 },
      {
        opacity: 1,
        duration: 0.35,
        ease: "power2.out",
        onComplete: () => {
          playedRef.current = true;
        },
      },
    );

    return () => {
      tween.kill();
      gsap.set(root, { clearProps: "opacity" });
    };
  }, []);

  return (
    <div ref={rootRef} className="flex min-h-full flex-1 flex-col">
      {children}
    </div>
  );
}
