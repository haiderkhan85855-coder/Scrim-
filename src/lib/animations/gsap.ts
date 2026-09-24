"use client";

import { useGSAP } from "@gsap/react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";

// Keeps @gsap/react aligned with this app's GSAP instance (React version safety).
gsap.registerPlugin(useGSAP);

let pluginsRegistered = false;

/** Registers GSAP plugins once on the client. Safe to call repeatedly. */
export function registerGsapPlugins(): void {
  if (pluginsRegistered || typeof window === "undefined") return;
  gsap.registerPlugin(ScrollTrigger);
  pluginsRegistered = true;
}

export { gsap, ScrollTrigger, useGSAP };
