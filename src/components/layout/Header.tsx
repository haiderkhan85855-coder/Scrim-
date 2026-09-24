"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef, useState } from "react";

import { logout } from "@/app/auth/actions";
import {
  AuthModal,
  type AuthModalMode,
} from "@/components/auth/AuthModal";
import { Container } from "@/components/layout/Container";
import { Button } from "@/components/ui/Button";

const navLinks = [
  { label: "Tournaments", href: "/#upcoming-tournaments", number: "01" },
  { label: "Leaderboard", href: "/leaderboard", number: "02" },
  { label: "How It Works", href: "/#how-it-works", number: "03" },
] as const;

const mobileNavLinks = [
  { label: "Home", href: "/", icon: "home" },
  { label: "Tournaments", href: "/#upcoming-tournaments", icon: "trophy" },
  { label: "Leaderboard", href: "/leaderboard", icon: "leaderboard" },
  { label: "How It Works", href: "/#how-it-works", icon: "guide" },
  { label: "Scrims Live", href: "/#tournaments", icon: "live" },
] as const;

type HeaderProps = {
  hasAdminAccess?: boolean;
  isAuthenticated: boolean;
};

export function Header({
  hasAdminAccess = false,
  isAuthenticated,
}: HeaderProps) {
  const pathname = usePathname();
  const [scrolled, setScrolled] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [accountMenuOpen, setAccountMenuOpen] = useState(false);
  const [activeHash, setActiveHash] = useState("");
  const [authModalOpen, setAuthModalOpen] = useState(false);
  const [authModalMode, setAuthModalMode] = useState<AuthModalMode>("login");
  const menuButtonRef = useRef<HTMLButtonElement>(null);
  const mobileNavRef = useRef<HTMLDivElement>(null);
  const wasMenuOpenRef = useRef(false);
  const accountControlRef = useRef<HTMLDivElement>(null);
  const accountTriggerRef = useRef<HTMLButtonElement>(null);
  const accountMenuRef = useRef<HTMLDivElement>(null);
  const authTriggerRef = useRef<HTMLButtonElement | null>(null);
  const restoreAuthFocusRef = useRef(false);

  const openAuthModal = (trigger: HTMLButtonElement) => {
    authTriggerRef.current = trigger;
    restoreAuthFocusRef.current = false;
    setAuthModalMode("login");
    setAuthModalOpen(true);
  };

  const closeAuthModal = () => {
    restoreAuthFocusRef.current = true;
    setAuthModalOpen(false);
  };

  useEffect(() => {
    if (authModalOpen || !restoreAuthFocusRef.current) return;

    restoreAuthFocusRef.current = false;
    const trigger = authTriggerRef.current;
    if (trigger?.closest("[inert]")) menuButtonRef.current?.focus();
    else trigger?.focus();
  }, [authModalOpen, menuOpen]);

  useEffect(() => {
    const syncActiveHash = () => setActiveHash(window.location.hash);

    syncActiveHash();
    window.addEventListener("hashchange", syncActiveHash);

    return () => window.removeEventListener("hashchange", syncActiveHash);
  }, []);

  useEffect(() => {
    const onScroll = () => {
      setScrolled(window.scrollY > 28);
    };

    onScroll();

    window.addEventListener("scroll", onScroll, {
      passive: true,
    });

    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    const desktopMedia = window.matchMedia("(min-width: 1025px)");
    const closeMobileMenuOnDesktop = () => {
      if (desktopMedia.matches) setMenuOpen(false);
    };

    closeMobileMenuOnDesktop();
    desktopMedia.addEventListener("change", closeMobileMenuOnDesktop);

    return () =>
      desktopMedia.removeEventListener("change", closeMobileMenuOnDesktop);
  }, []);

  useEffect(() => {
    if (!accountMenuOpen) return;

    const onPointerDown = (event: PointerEvent) => {
      if (
        event.target instanceof Node &&
        !accountControlRef.current?.contains(event.target)
      ) {
        setAccountMenuOpen(false);
      }
    };

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;

      event.preventDefault();
      setAccountMenuOpen(false);
      window.requestAnimationFrame(() => accountTriggerRef.current?.focus());
    };

    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);

    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [accountMenuOpen]);

  const focusAccountItem = (position: "first" | "last") => {
    const items = accountMenuRef.current?.querySelectorAll<HTMLElement>(
      '[role="menuitem"]:not([aria-disabled="true"])',
    );

    if (!items?.length) return;
    items[position === "first" ? 0 : items.length - 1]?.focus();
  };

  const onAccountMenuKeyDown = (
    event: React.KeyboardEvent<HTMLDivElement>,
  ) => {
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
      return;
    }

    event.preventDefault();
    const items = Array.from(
      accountMenuRef.current?.querySelectorAll<HTMLElement>(
        '[role="menuitem"]:not([aria-disabled="true"])',
      ) ?? [],
    );

    if (!items.length) return;

    if (event.key === "Home") {
      items[0]?.focus();
      return;
    }

    if (event.key === "End") {
      items.at(-1)?.focus();
      return;
    }

    const activeIndex = items.indexOf(document.activeElement as HTMLElement);
    const direction = event.key === "ArrowDown" ? 1 : -1;
    const nextIndex =
      activeIndex === -1
        ? direction === 1
          ? 0
          : items.length - 1
        : (activeIndex + direction + items.length) % items.length;
    items[nextIndex]?.focus();
  };

  useEffect(() => {
    if (!menuOpen) {
      if (wasMenuOpenRef.current) {
        wasMenuOpenRef.current = false;
        window.requestAnimationFrame(() => menuButtonRef.current?.focus());
      }
      return;
    }

    const menuJustOpened = !wasMenuOpenRef.current;
    wasMenuOpenRef.current = true;

    const nav = mobileNavRef.current;
    const trigger = menuButtonRef.current;
    const firstMenuLink = nav?.querySelector<HTMLElement>("a[href]");

    const focusFrame = menuJustOpened
      ? window.requestAnimationFrame(() => firstMenuLink?.focus())
      : undefined;

    const onKeyDown = (event: KeyboardEvent) => {
      if (authModalOpen) return;

      if (event.key === "Escape") {
        event.preventDefault();
        setMenuOpen(false);
      }
    };

    const onPointerDown = (event: PointerEvent) => {
      if (authModalOpen) return;

      if (
        event.target instanceof Node &&
        !nav?.contains(event.target) &&
        !trigger?.contains(event.target)
      ) {
        setMenuOpen(false);
      }
    };

    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("pointerdown", onPointerDown);
    return () => {
      if (focusFrame !== undefined) window.cancelAnimationFrame(focusFrame);
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("pointerdown", onPointerDown);
    };
  }, [authModalOpen, menuOpen]);

  return (
    <header
      className={[
        "site-header fixed inset-x-0 top-0 z-50",
        "transition-[background-color,border-color,backdrop-filter] duration-500",
        scrolled || menuOpen
          ? "border-b border-white/[0.1] bg-[#07090b]/94 backdrop-blur-xl"
          : "border-b border-white/[0.08] bg-[#07090b]/88 backdrop-blur-md",
      ].join(" ")}
    >
      <Container className="flex h-[var(--header-height)] max-w-[90rem] items-center justify-between gap-3 lg:gap-4 xl:gap-6">
        {/* Brand */}
        <Link
          href="/"
          onClick={() => setMenuOpen(false)}
          className="group flex shrink-0 items-center"
          aria-label="LevelledUp home"
        >
          <Image
            src="/images/brand/levelledup-logo-horizontal.png"
            alt=""
            width={2172}
            height={724}
            priority
            sizes="(min-width: 1280px) 160px, (min-width: 640px) 148px, 136px"
            className="h-auto w-[8.5rem] object-contain sm:w-[9.25rem] xl:w-40"
          />
        </Link>

        {/* Desktop navigation */}
        <nav
          className="hidden items-center gap-1 min-[1025px]:flex"
          aria-label="Primary navigation"
        >
          {navLinks.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              className={[
                "group relative flex h-10 items-center gap-2 px-4",
                "text-[0.67rem] font-semibold uppercase tracking-[0.16em]",
                "text-white/70 transition-colors duration-300 hover:text-white",
              ].join(" ")}
            >
              <span className="hidden text-[0.52rem] text-orange-500/55 transition-colors duration-300 group-hover:text-orange-500">
                {link.number}
              </span>

              <span>{link.label}</span>

              <span
                aria-hidden
                className={[
                  "absolute bottom-0 left-4 right-4 h-px origin-left",
                  "scale-x-0 bg-orange-500",
                  "transition-transform duration-300 ease-out",
                  "group-hover:scale-x-100",
                ].join(" ")}
              />
            </Link>
          ))}
        </nav>

        {/* Desktop actions */}
        <div className="hidden items-center gap-3 min-[1025px]:flex">
          <Link
            href="/#tournaments"
            className="group flex items-center gap-2 text-[0.62rem] font-semibold uppercase tracking-[0.18em] text-white/65 transition-colors hover:text-white"
          >
            <span className="relative flex h-2 w-2 items-center justify-center">
              <span className="absolute inset-0 m-auto h-2 w-2 animate-ping rounded-full bg-orange-500/50" />
              <span className="relative h-1.5 w-1.5 rounded-full bg-orange-500" />
            </span>

            <span>Scrims Live</span>
          </Link>

          {isAuthenticated ? (
            <div ref={accountControlRef} className="relative">
              <button
                ref={accountTriggerRef}
                type="button"
                aria-haspopup="menu"
                aria-expanded={accountMenuOpen}
                aria-controls="account-menu"
                className="flex min-h-10 items-center gap-2 border border-white/15 bg-white/[0.035] px-4 text-[0.62rem] font-semibold uppercase tracking-[0.16em] text-white/75 transition-colors hover:border-orange-500/45 hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-orange-500"
                onClick={() => setAccountMenuOpen((open) => !open)}
                onKeyDown={(event) => {
                  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") {
                    return;
                  }

                  event.preventDefault();
                  setAccountMenuOpen(true);
                  window.requestAnimationFrame(() =>
                    focusAccountItem(
                      event.key === "ArrowDown" ? "first" : "last",
                    ),
                  );
                }}
              >
                <span className="flex h-5 w-5 items-center justify-center border border-orange-500/45 text-[0.55rem] text-orange-500">
                  P
                </span>
                Profile
                <span
                  aria-hidden="true"
                  className={`text-[0.55rem] text-white/40 transition-transform ${accountMenuOpen ? "rotate-180" : ""}`}
                >
                  ▾
                </span>
              </button>

              <div
                ref={accountMenuRef}
                id="account-menu"
                role="menu"
                aria-label="Account navigation"
                onKeyDown={onAccountMenuKeyDown}
                className={[
                  "absolute right-0 top-[calc(100%+0.6rem)] w-56 border border-white/10 bg-[#0b0b0b]/98 p-2 shadow-2xl shadow-black/50 backdrop-blur-xl",
                  "origin-top-right transition-[opacity,transform] duration-200",
                  accountMenuOpen
                    ? "visible scale-100 opacity-100"
                    : "invisible pointer-events-none scale-95 opacity-0",
                ].join(" ")}
              >
                <a
                  href="/account"
                  role="menuitem"
                  onClick={() => setAccountMenuOpen(false)}
                  className="flex items-center justify-between px-3 py-3 text-[0.64rem] font-semibold uppercase tracking-[0.15em] text-white/75 transition-colors hover:bg-white/[0.04] hover:text-orange-500 focus:bg-white/[0.04] focus:text-orange-500 focus:outline-none"
                >
                  Account
                  <span aria-hidden="true">→</span>
                </a>
                <a
                  href="/team"
                  role="menuitem"
                  onClick={() => setAccountMenuOpen(false)}
                  className="flex items-center justify-between px-3 py-3 text-[0.64rem] font-semibold uppercase tracking-[0.15em] text-white/75 transition-colors hover:bg-white/[0.04] hover:text-orange-500 focus:bg-white/[0.04] focus:text-orange-500 focus:outline-none"
                >
                  My Team
                  <span aria-hidden="true">→</span>
                </a>
                <div
                  role="menuitem"
                  aria-disabled="true"
                  className="flex cursor-not-allowed items-center justify-between px-3 py-3 text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-white/30"
                >
                  My Tournaments
                  <span className="text-[0.48rem] tracking-[0.12em] text-white/20">
                    Soon
                  </span>
                </div>
                {hasAdminAccess ? (
                  <a
                    href="/admin"
                    role="menuitem"
                    onClick={() => setAccountMenuOpen(false)}
                    className="mt-1 flex items-center justify-between border-t border-orange-500/15 px-3 py-3 text-[0.64rem] font-semibold uppercase tracking-[0.15em] text-orange-400 transition-colors hover:bg-orange-500/[0.07] hover:text-orange-300 focus:bg-orange-500/[0.07] focus:text-orange-300 focus:outline-none"
                  >
                    Admin Panel
                    <span
                      aria-hidden="true"
                      className="h-1.5 w-1.5 bg-orange-500"
                    />
                  </a>
                ) : null}
                <form action={logout} className="mt-1 border-t border-white/10 pt-1">
                  <button
                    type="submit"
                    role="menuitem"
                    onClick={() => setAccountMenuOpen(false)}
                    className="flex w-full items-center justify-between px-3 py-3 text-left text-[0.64rem] font-semibold uppercase tracking-[0.15em] text-white/75 transition-colors hover:bg-white/[0.04] hover:text-orange-500 focus:bg-white/[0.04] focus:text-orange-500 focus:outline-none"
                  >
                    Logout
                    <span aria-hidden="true">↗</span>
                  </button>
                </form>
              </div>
            </div>
          ) : (
            <button
              type="button"
              onClick={(event) => openAuthModal(event.currentTarget)}
              className="inline-flex min-h-10 items-center justify-center border border-white/15 bg-white/[0.025] px-4 text-[0.62rem] font-semibold uppercase tracking-[0.16em] text-white/75 transition-colors hover:border-orange-500/45 hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-orange-500"
            >
              Login
            </button>
          )}

          <Button href="/#join" className="min-h-10 px-5">
            Join a Scrim
          </Button>
        </div>

        {/* Mobile menu trigger */}
        <button
          ref={menuButtonRef}
          type="button"
          className={[
            "relative flex h-9 w-9 items-center justify-center sm:h-10 sm:w-10",
            "border border-white/10 bg-black/20 text-white",
            "transition-colors hover:border-orange-500/50",
            "z-10 min-[1025px]:hidden",
          ].join(" ")}
          aria-expanded={menuOpen}
          aria-controls="mobile-nav"
          aria-label={menuOpen ? "Close menu" : "Open menu"}
          onClick={() => {
            setAccountMenuOpen(false);
            setMenuOpen((open) => !open);
          }}
        >
          <span className="sr-only">{menuOpen ? "Close" : "Menu"}</span>

          <span
            className={[
              "absolute h-px w-5 bg-current transition-transform duration-300",
              menuOpen ? "translate-y-0 rotate-45" : "-translate-y-1.5",
            ].join(" ")}
          />

          <span
            className={[
              "absolute h-px w-5 bg-current transition-opacity duration-200",
              menuOpen ? "opacity-0" : "opacity-100",
            ].join(" ")}
          />

          <span
            className={[
              "absolute h-px w-5 bg-current transition-transform duration-300",
              menuOpen ? "translate-y-0 -rotate-45" : "translate-y-1.5",
            ].join(" ")}
          />
        </button>
      </Container>

      {/* Mobile navigation */}
      <div
        ref={mobileNavRef}
        id="mobile-nav"
        aria-hidden={!menuOpen}
        inert={!menuOpen}
        className={[
          "absolute right-4 top-[calc(100%+0.45rem)] z-20 w-[calc(100vw-2rem)] max-w-[22rem] sm:right-8 min-[1025px]:hidden",
          "origin-top-right overflow-hidden rounded-[3px] border border-white/[0.11]",
          "bg-[#091014]/98 shadow-2xl shadow-black/65 backdrop-blur-xl",
          "transition-[opacity,transform,visibility] duration-200 ease-[var(--ease-out-expo)] motion-reduce:transition-none",
          menuOpen
            ? "visible translate-y-0 scale-100 opacity-100"
            : "invisible pointer-events-none translate-y-2 scale-[0.98] opacity-0",
        ].join(" ")}
      >
        <div className="p-2.5 sm:p-3">
          <nav className="grid gap-0.5" aria-label="Mobile navigation">
            {mobileNavLinks.map((link) => {
              const isActive =
                link.href === "/"
                  ? pathname === "/" && activeHash === ""
                  : link.href === "/leaderboard"
                    ? pathname.startsWith("/leaderboard")
                    : pathname === "/" && link.href.endsWith(activeHash) && activeHash !== "";

              return (
                <Link
                  key={link.href}
                  href={link.href}
                  aria-current={
                    isActive
                      ? link.href.includes("#")
                        ? "location"
                        : "page"
                      : undefined
                  }
                  onClick={() => setMenuOpen(false)}
                  className={[
                    "group flex min-h-11 items-center gap-3 rounded-[2px] px-3 text-[0.82rem] font-medium transition-colors",
                    "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-accent",
                    isActive
                      ? "bg-accent/[0.1] text-accent"
                      : "text-white/72 hover:bg-white/[0.05] hover:text-white active:bg-white/[0.075]",
                  ].join(" ")}
                >
                  <MobileNavIcon icon={link.icon} active={isActive} />
                  <span>{link.label}</span>
                  {link.label === "Scrims Live" ? (
                    <span
                      aria-hidden="true"
                      className="ml-auto h-1.5 w-1.5 rounded-full bg-accent shadow-[0_0_10px_rgba(255,74,20,0.75)]"
                    />
                  ) : null}
                </Link>
              );
            })}
          </nav>

          <div className="mt-2.5 border-t border-white/10 pt-2.5">
            {isAuthenticated ? (
              <div className="mb-2.5 grid gap-1.5">
                <Link
                  href="/account"
                  onClick={() => setMenuOpen(false)}
                  className="group flex min-h-14 items-center gap-3 rounded-[2px] border border-white/[0.09] bg-white/[0.025] px-3 text-left transition-colors hover:border-accent/30 hover:bg-accent/[0.055] focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                >
                  <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full border border-accent/25 bg-accent/[0.08] text-accent">
                    <MobileNavIcon icon="profile" active />
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="block text-[0.82rem] font-semibold text-white">
                      Profile
                    </span>
                    <span className="mt-0.5 block text-[0.58rem] uppercase tracking-[0.14em] text-white/38">
                      View your account
                    </span>
                  </span>
                  <span aria-hidden="true" className="text-white/30 transition-colors group-hover:text-accent">
                    ›
                  </span>
                </Link>
                <Link
                  href="/team"
                  onClick={() => setMenuOpen(false)}
                  className="flex min-h-10 items-center gap-3 rounded-[2px] px-3 text-[0.7rem] font-medium uppercase tracking-[0.12em] text-white/58 transition-colors hover:bg-white/[0.05] hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                >
                  <MobileNavIcon icon="team" />
                  My Team
                </Link>
                {hasAdminAccess ? (
                  <Link
                    href="/admin"
                    onClick={() => setMenuOpen(false)}
                    className="flex min-h-10 items-center gap-3 rounded-[2px] px-3 text-[0.7rem] font-medium uppercase tracking-[0.12em] text-accent/80 transition-colors hover:bg-accent/[0.06] hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                  >
                    <MobileNavIcon icon="admin" active />
                    Admin Panel
                  </Link>
                ) : null}
                <form action={logout}>
                  <button
                    type="submit"
                    onClick={() => setMenuOpen(false)}
                    className="flex min-h-10 w-full items-center gap-3 rounded-[2px] px-3 text-left text-[0.7rem] font-medium uppercase tracking-[0.12em] text-white/50 transition-colors hover:bg-white/[0.05] hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                  >
                    <MobileNavIcon icon="logout" />
                    Logout
                  </button>
                </form>
              </div>
            ) : (
              <div className="mb-2.5">
                <button
                  type="button"
                  onClick={(event) => openAuthModal(event.currentTarget)}
                  className="group flex min-h-14 items-center gap-3 rounded-[2px] border border-white/[0.09] bg-white/[0.025] px-3 text-left transition-colors hover:border-accent/30 hover:bg-accent/[0.055] focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                >
                  <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full border border-white/10 bg-white/[0.035] text-white/65 transition-colors group-hover:border-accent/25 group-hover:text-accent">
                    <MobileNavIcon icon="profile" />
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="block text-[0.82rem] font-semibold text-white">
                      Login
                    </span>
                    <span className="mt-0.5 block text-[0.58rem] uppercase tracking-[0.14em] text-white/38">
                      Access your profile
                    </span>
                  </span>
                  <span aria-hidden="true" className="text-white/30 transition-colors group-hover:text-accent">
                    ›
                  </span>
                </button>
              </div>
            )}

            <Button
              href="/#join"
              className="min-h-12 w-full"
              onClick={() => setMenuOpen(false)}
            >
              <MobileNavIcon icon="play" active />
              Join a Scrim
            </Button>
          </div>
        </div>
      </div>

      {!isAuthenticated ? (
        <AuthModal
          open={authModalOpen}
          mode={authModalMode}
          onClose={closeAuthModal}
          onModeChange={setAuthModalMode}
        />
      ) : null}
    </header>
  );
}

type MobileNavIconName =
  | (typeof mobileNavLinks)[number]["icon"]
  | "profile"
  | "team"
  | "admin"
  | "logout"
  | "play";

function MobileNavIcon({
  icon,
  active = false,
}: {
  icon: MobileNavIconName;
  active?: boolean;
}) {
  const path = {
    home: <path d="m3 10 9-7 9 7v10H6V10m4 10v-6h4v6" />,
    trophy: <path d="M8 4h8v4c0 4-2 6-4 6s-4-2-4-6V4Zm0 2H4v2c0 2 1.3 3 3.3 3M16 6h4v2c0 2-1.3 3-3.3 3M12 14v4m-4 2h8" />,
    leaderboard: <path d="M5 20v-7h4v7m2 0V4h4v16m2 0v-11h4v11M3 20h19" />,
    guide: <path d="M4 5.5A3.5 3.5 0 0 1 7.5 2H11v17H7.5A3.5 3.5 0 0 0 4 22V5.5Zm16 0A3.5 3.5 0 0 0 16.5 2H13v17h3.5A3.5 3.5 0 0 1 20 22V5.5Z" />,
    live: <path d="M3 12h4l2-6 4 12 2-6h6" />,
    profile: <path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8c.8-4 3.2-6 7-6s6.2 2 7 6" />,
    team: <path d="M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7-1a2.5 2.5 0 1 0 0-5M3 20c.6-4 2.6-6 6-6s5.4 2 6 6m1-7c2.8.2 4.5 1.8 5 5" />,
    admin: <path d="m12 3 7 3v5c0 4.6-2.3 7.7-7 10-4.7-2.3-7-5.4-7-10V6l7-3Zm-3 9 2 2 4-5" />,
    logout: <path d="M10 5H5v14h5m5-4 4-3-4-3m4 3H9" />,
    play: <path d="m9 7 8 5-8 5V7Z" />,
  }[icon];

  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={`h-[1.15rem] w-[1.15rem] shrink-0 ${active ? "text-accent" : "text-white/52 transition-colors group-hover:text-accent"}`}
    >
      {path}
    </svg>
  );
}
