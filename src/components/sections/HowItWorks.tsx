"use client";

import { Container } from "@/components/layout/Container";
import { SectionIntro } from "@/components/sections/SectionIntro";
import { howItWorksSteps } from "@/data/howItWorks";
import { useSectionAnimation } from "@/hooks/useSectionAnimation";

export function HowItWorks() {
  const sectionRef = useSectionAnimation(({ gsap, trigger }) => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    const timeline = gsap.timeline({
      scrollTrigger: { trigger, start: "top 82%", once: true },
    });
    timeline.from(trigger.querySelectorAll("[data-process-reveal]"), {
      autoAlpha: 0,
      y: 18,
      duration: 0.65,
      ease: "power3.out",
    });
    timeline.from(
      trigger.querySelectorAll("[data-process-step]"),
      { autoAlpha: 0, y: 14, duration: 0.5, stagger: 0.09, ease: "power3.out" },
      "-=0.35",
    );
  });

  return (
    <section ref={sectionRef} id="how-it-works" className="homepage-section homepage-section-shade scroll-mt-16">
      <Container className="grid gap-5 xl:grid-cols-[0.42fr_1fr] xl:items-center xl:gap-12">
        <SectionIntro
          eyebrow="How It Works"
          title="From entry to leaderboard."
          description="Four clear moves take your Squad from registration to an official competitive record."
          revealAttribute="data-process-reveal"
        />

        <ol className="journey-list relative grid gap-2.5 xl:grid-cols-4 xl:gap-0">
          {howItWorksSteps.map((step, index) => (
            <li
              key={step.id}
              data-process-step
              className="journey-step relative grid grid-cols-[2.75rem_minmax(0,1fr)] gap-3 rounded-[3px] border border-white/[0.06] bg-[#0a0e11]/72 p-3 xl:block xl:min-h-44 xl:border-0 xl:bg-transparent xl:px-4 xl:py-3"
            >
              <div className="relative z-10 flex h-10 w-10 items-center justify-center rounded-full border border-accent/40 bg-[#0a0d0f] shadow-[0_0_0_4px_#090c0e] xl:h-11 xl:w-11 xl:shadow-[0_0_0_7px_#090c0e]">
                <span className="type-display text-sm text-accent">
                  {String(index + 1).padStart(2, "0")}
                </span>
              </div>

              <div className="xl:mt-5">
                <div className="flex items-center gap-2">
                  <span className="text-accent xl:hidden">
                    <StepIcon id={step.id} />
                  </span>
                  <h3 className="text-sm font-bold uppercase tracking-[0.03em] text-white">
                    {step.title}
                  </h3>
                  {step.help ? (
                    <TermHelp term={step.help.term} description={step.help.description} />
                  ) : null}
                </div>
                <p className="mt-1.5 text-sm leading-5 text-white/55 xl:mt-2 xl:leading-6">
                  {step.description}
                </p>
              </div>

              <span aria-hidden className="journey-connector absolute -bottom-3 left-[1.95rem] top-[3.25rem] w-px bg-gradient-to-b from-accent/45 to-white/5 xl:hidden" />
            </li>
          ))}
        </ol>
      </Container>
    </section>
  );
}

function StepIcon({ id }: { id: string }) {
  const paths: Record<string, string> = {
    register: "M8 7.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5ZM3.5 14c.3-2.7 1.8-4 4.5-4s4.2 1.3 4.5 4",
    enter: "M2.5 3h4v4h-4V3Zm7 0h4v4h-4V3Zm-7 6h4v4h-4V9Zm7 0h4v4h-4V9Z",
    drop: "M8 2 3 6.5 8 14l5-7.5L8 2Zm0 0v12M3 6.5h10",
    dominate: "M4 2.5h8v3a4 4 0 0 1-8 0v-3ZM8 9.5V13m-3 1h6M4 4H2.5v1.5C2.5 8 4 8.5 5 8.5M12 4h1.5v1.5c0 2.5-1.5 3-2.5 3",
  };

  return (
    <svg aria-hidden viewBox="0 0 16 16" className="h-4 w-4" fill="none">
      <path d={paths[id]} stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function TermHelp({ term, description }: { term: string; description: string }) {
  return (
    <span className="group/help relative inline-flex">
      <button
        type="button"
        aria-label={`What is a ${term}?`}
        className="inline-flex h-6 w-6 items-center justify-center rounded-full text-xs text-accent/75 transition-colors hover:bg-accent/10 hover:text-accent focus-visible:bg-accent/10 focus-visible:text-accent focus-visible:outline focus-visible:outline-1 focus-visible:outline-accent"
      >
        ⓘ
      </button>
      <span
        role="tooltip"
        className="pointer-events-none absolute bottom-full left-1/2 z-30 mb-2 w-56 -translate-x-1/2 rounded-[3px] border border-white/10 bg-[#0b0f12] p-3 text-[0.68rem] font-normal normal-case leading-5 tracking-normal text-white/70 opacity-0 shadow-2xl transition-opacity group-hover/help:opacity-100 group-focus-within/help:opacity-100"
      >
        <strong className="mb-1 block uppercase tracking-[0.1em] text-accent">{term}</strong>
        {description}
      </span>
    </span>
  );
}
