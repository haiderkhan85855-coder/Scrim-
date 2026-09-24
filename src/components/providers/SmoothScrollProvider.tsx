"use client";

import { useEffect, type ReactNode } from "react";
import "lenis/dist/lenis.css";

import {
  createLenis,
  gsap,
  registerGsapPlugins,
  ScrollTrigger,
} from "@/lib/animations";

type SmoothScrollProviderProps = {
  children: ReactNode;
};

/**
 * Boots Lenis smooth scrolling and keeps it in sync with GSAP ScrollTrigger.
 * Wrap the app once; section animations can be added later independently.
 */
export function SmoothScrollProvider({ children }: SmoothScrollProviderProps) {
  useEffect(() => {
    registerGsapPlugins();

    const lenis = createLenis();

    const onScroll = () => {
      ScrollTrigger.update();
    };

    lenis.on("scroll", onScroll);

    const onTick = (time: number) => {
      lenis.raf(time * 1000);
    };

    gsap.ticker.add(onTick);
    gsap.ticker.lagSmoothing(0);

    return () => {
      lenis.off("scroll", onScroll);
      gsap.ticker.remove(onTick);
      lenis.destroy();
      ScrollTrigger.getAll().forEach((trigger) => trigger.kill());
    };
  }, []);

  return children;
}
