"use client";

import Image from "next/image";
import Link from "next/link";
import { useId, useState } from "react";

const competitionLinks = [
  { label: "Tournaments", href: "/#upcoming-tournaments" },
  { label: "Leaderboard", href: "/leaderboard" },
  { label: "How It Works", href: "/#how-it-works" },
] as const;

const supportLinks = [
  { label: "Contact" },
  { label: "Privacy" },
  { label: "Terms" },
] as const;

const socialLinks = [
  { label: "Discord" },
  { label: "Instagram" },
  { label: "YouTube" },
] as const;

export function Footer() {
  const [openGroup, setOpenGroup] = useState<string | null>(null);

  return (
    <footer className="relative bg-[linear-gradient(180deg,#080b0d,#050607)] px-4 pb-6 pt-8 text-foreground sm:px-8 xl:px-16 xl:pb-8 xl:pt-11">
      <div className="mx-auto max-w-7xl">
        <div className="grid gap-7 pb-7 xl:grid-cols-[1.25fr_1.75fr] xl:gap-20 xl:pb-9">
          <div>
            <Link
              href="/"
              className="group inline-flex items-center"
              aria-label="LevelledUp home"
            >
              <Image
                src="/images/brand/levelledup-logo-horizontal.png"
                alt=""
                width={2172}
                height={724}
                sizes="(min-width: 1280px) 192px, (min-width: 640px) 184px, 172px"
                className="h-auto w-[10.75rem] object-contain sm:w-[11.5rem] xl:w-48"
              />
            </Link>

            <p className="mt-4 max-w-sm text-sm leading-5 text-white/55 xl:mt-5 xl:leading-6">
              Competitive PUBG MOBILE scrims built for squads ready to test
              themselves.
            </p>
          </div>

          <nav className="grid divide-y divide-white/10 xl:grid-cols-3 xl:gap-8 xl:divide-y-0" aria-label="Footer navigation">
            <FooterLinkGroup
              title="Competition"
              links={competitionLinks}
              open={openGroup === "competition"}
              onToggle={() => setOpenGroup((group) => group === "competition" ? null : "competition")}
            />
            <FooterLinkGroup
              title="Support"
              links={supportLinks}
              open={openGroup === "support"}
              onToggle={() => setOpenGroup((group) => group === "support" ? null : "support")}
            />
            <FooterLinkGroup
              title="Follow"
              links={socialLinks}
              open={openGroup === "follow"}
              onToggle={() => setOpenGroup((group) => group === "follow" ? null : "follow")}
            />
          </nav>
        </div>

        <div className="flex flex-col items-center gap-3 border-t border-white/10 pt-6 text-center text-[0.52rem] font-medium uppercase tracking-[0.18em] text-white/45 xl:flex-row xl:justify-between xl:text-left">
          <p>© {new Date().getFullYear()} LevelledUp. All rights reserved.</p>
          <p>
            PUBG Mobile <span className="mx-2 text-accent/50">/</span> Pakistan
          </p>
        </div>
      </div>
    </footer>
  );
}

function FooterLinkGroup({
  title,
  links,
  open,
  onToggle,
}: {
  title: string;
  links: ReadonlyArray<{ label: string; href?: string }>;
  open: boolean;
  onToggle: () => void;
}) {
  const reactId = useId();
  const panelId = `footer-${title.toLowerCase()}-${reactId.replace(/:/g, "")}`;

  return (
    <div className="xl:py-0">
      <button
        type="button"
        aria-expanded={open}
        aria-controls={panelId}
        onClick={onToggle}
        className={`flex min-h-14 w-full items-center justify-between border-l-2 px-3 text-left text-[0.64rem] font-bold uppercase tracking-[0.21em] transition-[border-color,color,background-color] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-accent xl:hidden ${open ? "border-accent bg-accent/[0.045] text-white" : "border-transparent text-white/62 hover:bg-white/[0.025] hover:text-white"}`}
      >
        {title}
        <ChevronIcon open={open} />
      </button>

      <div
        id={panelId}
        aria-hidden={!open}
        inert={!open}
        className={`grid transition-[grid-template-rows,visibility] duration-200 motion-reduce:transition-none xl:hidden ${open ? "visible grid-rows-[1fr]" : "invisible grid-rows-[0fr]"}`}
      >
        <div className="overflow-hidden">
          <FooterLinks links={links} mobile />
        </div>
      </div>

      <div className="hidden xl:block">
        <p className="text-[0.52rem] font-semibold uppercase tracking-[0.2em] text-white/40">
          {title}
        </p>
        <FooterLinks links={links} />
      </div>
    </div>
  );
}

function FooterLinks({
  links,
  mobile = false,
}: {
  links: ReadonlyArray<{ label: string; href?: string }>;
  mobile?: boolean;
}) {
  return (
    <ul className={mobile ? "mb-3 ml-3 space-y-0.5 border-l border-accent/25 pb-1 pl-4 pt-1" : "mt-4 space-y-3"}>
      {links.map((link) => (
        <li key={link.label}>
          {link.href ? (
            <Link
              href={link.href}
              className={mobile
                ? "group flex min-h-10 w-full items-center justify-between gap-2 pr-3 text-[0.7rem] font-medium uppercase tracking-[0.13em] text-white/62 transition-colors duration-200 hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                : "group inline-flex items-center gap-2 text-xs font-medium uppercase tracking-[0.13em] text-white/70 transition-colors duration-300 hover:text-foreground"}
            >
              <span className="flex items-center gap-2">
                {!mobile ? <span className="h-px w-0 bg-accent transition-[width] duration-300 group-hover:w-3" /> : null}
                {link.label}
              </span>
              {mobile ? <span aria-hidden className="text-white/22 transition-colors group-hover:text-accent">→</span> : null}
            </Link>
          ) : (
            <span
              aria-disabled="true"
              title="Coming soon"
              className={mobile
                ? "flex min-h-10 cursor-default items-center text-[0.7rem] font-medium uppercase tracking-[0.13em] text-white/38"
                : "inline-flex cursor-default items-center text-xs font-medium uppercase tracking-[0.13em] text-white/50"}
            >
              {link.label}
            </span>
          )}
        </li>
      ))}
    </ul>
  );
}

function ChevronIcon({ open }: { open: boolean }) {
  return (
    <svg
      aria-hidden
      viewBox="0 0 16 16"
      className={`h-4 w-4 transition-[transform,color] duration-200 motion-reduce:transition-none ${open ? "rotate-180 text-accent" : "text-white/35"}`}
      fill="none"
    >
      <path d="m4 6 4 4 4-4" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}
