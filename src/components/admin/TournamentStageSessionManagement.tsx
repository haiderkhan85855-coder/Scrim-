"use client";

import { useActionState } from "react";

import {
  configureTournamentSession,
  configureTournamentStage,
  createTournamentSession,
  createTournamentStage,
  setTournamentSessionPrice,
  type TournamentSetupActionState,
} from "@/app/admin/tournaments/[tournamentId]/actions";
import type {
  AdminSessionSetupCheck,
  AdminStageSetup,
  AdminTournamentSession,
  AdminTournamentStage,
} from "@/components/admin/types";
import { formatTournamentDateTime } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

const initialState: TournamentSetupActionState = {};
const inputClass =
  "min-h-10 w-full rounded-[2px] border border-border-strong bg-background px-3 text-xs text-foreground outline-none transition-colors placeholder:text-foreground-subtle focus:border-accent focus:ring-1 focus:ring-accent/20 disabled:opacity-45";
const labelClass =
  "grid gap-1.5 text-[0.52rem] font-semibold uppercase tracking-[0.13em] text-foreground-muted";
const buttonClass =
  "inline-flex min-h-10 items-center justify-center rounded-[2px] border px-4 text-[0.56rem] font-semibold uppercase tracking-[0.13em] transition-colors disabled:pointer-events-none disabled:opacity-40";

const stagePresetLabels: Record<AdminTournamentStage["namePreset"], string> = {
  open_qualifier: "Open Qualifier",
  qualifier: "Qualifier",
  quarterfinal: "Quarterfinal",
  semifinal: "Semifinal",
  grand_final: "Grand Final",
};

function minorToInput(value: number | null, currency: string | null) {
  if (value === null || !currency) return "";
  const digits = currencyFractionDigits(currency);
  const scale = 10 ** digits;
  const whole = Math.floor(value / scale);
  const fraction = String(value % scale).padStart(digits, "0").replace(/0+$/, "");
  return fraction ? `${whole}.${fraction}` : String(whole);
}

function formatMoney(value: number | null, currency: string | null) {
  if (value === null || !currency) return "Not configured";
  const digits = currencyFractionDigits(currency);
  const amount = value / 10 ** digits;
  try {
    return new Intl.NumberFormat("en-PK", {
      style: "currency",
      currency,
      minimumFractionDigits: 0,
      maximumFractionDigits: digits,
    }).format(amount);
  } catch {
    return `${currency} ${amount.toLocaleString("en-PK")}`;
  }
}

function humanizeIssue(issue: string) {
  return issue
    .split("_")
    .filter(Boolean)
    .map((part) => `${part[0]?.toUpperCase() ?? ""}${part.slice(1)}`)
    .join(" ");
}

function Feedback({ state }: { state: TournamentSetupActionState }) {
  if (!state.error && !state.success) return null;
  return (
    <p
      className={`mt-3 text-xs leading-5 ${state.error ? "text-[#ff8a65]" : "text-[#79d49b]"}`}
      role={state.error ? "alert" : "status"}
    >
      {state.error ?? `✓ ${state.success}`}
    </p>
  );
}

function HiddenReferences({
  tournamentId,
  tournamentPublicId,
}: {
  tournamentId: string;
  tournamentPublicId: string;
}) {
  return (
    <>
      <input type="hidden" name="tournament_id" value={tournamentId} />
      <input
        type="hidden"
        name="tournament_public_id"
        value={tournamentPublicId}
      />
    </>
  );
}

function ReadinessIssues({
  issues,
  ready,
}: {
  issues: string[];
  ready: boolean;
}) {
  return (
    <div
      className={`rounded-[2px] border px-3 py-2.5 ${
        ready
          ? "border-[#79d49b]/30 bg-[#79d49b]/[0.05]"
          : "border-[#ff8a65]/25 bg-[#ff8a65]/[0.04]"
      }`}
    >
      <p
        className={`text-[0.52rem] font-semibold uppercase tracking-[0.13em] ${
          ready ? "text-[#79d49b]" : "text-[#ff8a65]"
        }`}
      >
        {ready ? "Ready" : "Blocking setup issues"}
      </p>
      {!ready ? (
        <ul className="mt-2 grid gap-1 text-xs leading-5 text-foreground-muted">
          {(issues.length ? issues : ["setup_incomplete"]).map((issue) => (
            <li key={issue}>• {humanizeIssue(issue)}</li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function SessionCard({
  canManage,
  check,
  isFreeTournament,
  session,
  tournamentId,
  tournamentPublicId,
}: {
  canManage: boolean;
  check: AdminSessionSetupCheck | null;
  isFreeTournament: boolean;
  session: AdminTournamentSession;
  tournamentId: string;
  tournamentPublicId: string;
}) {
  const [configureState, configureAction, configurePending] = useActionState(
    configureTournamentSession,
    initialState,
  );
  const [priceState, priceAction, pricePending] = useActionState(
    setTournamentSessionPrice,
    initialState,
  );
  const configurable =
    canManage && !["live", "completed", "cancelled"].includes(session.status);
  const priceEditable =
    canManage && !isFreeTournament && ["planned", "open"].includes(session.status);

  return (
    <article className="rounded-[2px] border border-border bg-background/55 p-4 sm:p-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-mono text-[0.5rem] uppercase tracking-[0.12em] text-accent">
              Session {String(session.sessionNumber).padStart(2, "0")}
            </span>
            <span className="rounded-[2px] border border-border-strong px-2 py-1 text-[0.48rem] font-semibold uppercase tracking-[0.11em] text-foreground-muted">
              {session.status}
            </span>
            {session.isLegacyBackfill ? (
              <span className="rounded-[2px] border border-white/10 px-2 py-1 text-[0.48rem] uppercase tracking-[0.11em] text-foreground-subtle">
                Legacy backfill
              </span>
            ) : null}
          </div>
          <h4 className="type-display mt-2 break-words text-2xl uppercase">
            {session.displayName}
          </h4>
        </div>
        <div className="shrink-0 text-left sm:text-right">
          <p className="text-[0.48rem] uppercase tracking-[0.13em] text-foreground-subtle">
            Authoritative attempt price
          </p>
          <p className="mt-1 text-sm font-semibold text-accent">
            {formatMoney(session.entryFeeMinor, session.feeCurrency)}
          </p>
        </div>
      </div>

      <dl className="mt-4 grid gap-px overflow-hidden rounded-[2px] border border-border bg-border sm:grid-cols-2 xl:grid-cols-4">
        {[
          ["Starts", formatTournamentDateTime(session.scheduledStartAt)],
          ["Ends", formatTournamentDateTime(session.scheduledEndAt)],
          [
            "Concurrent lobbies",
            session.maxConcurrentLobbies?.toString() ?? "Not configured",
          ],
          [
            "Matches per lobby",
            session.defaultMatchesPerLobby?.toString() ?? "Not configured",
          ],
        ].map(([label, value]) => (
          <div key={label} className="bg-background-elevated/80 p-3">
            <dt className="text-[0.47rem] uppercase tracking-[0.12em] text-foreground-subtle">
              {label}
            </dt>
            <dd className="mt-1.5 text-xs leading-5 text-foreground">{value}</dd>
          </div>
        ))}
      </dl>

      <div className="mt-4">
        <ReadinessIssues
          ready={check?.setupComplete ?? false}
          issues={check?.issues ?? ["readiness_unavailable"]}
        />
      </div>

      <div className="mt-4 grid gap-3 lg:grid-cols-2">
        <details className="rounded-[2px] border border-border-strong bg-background-elevated/45 p-3 open:border-accent/35">
          <summary className="cursor-pointer text-[0.55rem] font-semibold uppercase tracking-[0.13em] text-foreground marker:text-accent">
            Configure runtime defaults
          </summary>
          <form action={configureAction} className="mt-4 grid gap-3 sm:grid-cols-2">
            <HiddenReferences
              tournamentId={tournamentId}
              tournamentPublicId={tournamentPublicId}
            />
            <input type="hidden" name="session_id" value={session.id} />
            <label className={labelClass}>
              Max concurrent lobbies <span title="How many lobbies may run concurrently in this Session.">ⓘ</span>
              <input
                className={inputClass}
                name="max_concurrent_lobbies"
                type="number"
                min={1}
                max={26}
                required
                defaultValue={session.maxConcurrentLobbies ?? ""}
                disabled={configurePending || !configurable}
              />
            </label>
            <label className={labelClass}>
              Default matches / lobby
              <input
                className={inputClass}
                name="default_matches_per_lobby"
                type="number"
                min={1}
                max={100}
                required
                defaultValue={session.defaultMatchesPerLobby ?? ""}
                disabled={configurePending || !configurable}
              />
            </label>
            <button
              className={`${buttonClass} border-accent bg-accent text-background hover:bg-accent-hover sm:col-span-2`}
              type="submit"
              disabled={configurePending || !configurable}
            >
              {configurePending ? "Saving..." : "Save Session Defaults"}
            </button>
          </form>
          <Feedback state={configureState} />
        </details>

        {isFreeTournament ? (
          <div className="rounded-[2px] border border-[#79d49b]/30 bg-[#79d49b]/[0.04] p-3">
            <p className="text-[0.55rem] font-semibold uppercase tracking-[0.13em] text-[#79d49b]">
              Free Tournament
            </p>
            <p className="mt-2 text-xs leading-5 text-foreground-muted">
              This Session&apos;s authoritative price is fixed at zero. Payment and credit actions are not available.
            </p>
          </div>
        ) : (
          <details className="rounded-[2px] border border-border-strong bg-background-elevated/45 p-3 open:border-accent/35">
          <summary className="cursor-pointer text-[0.55rem] font-semibold uppercase tracking-[0.13em] text-foreground marker:text-accent">
            Set authoritative price <span title="This price belongs to this exact Session attempt and becomes locked after participation or financial history exists.">ⓘ</span>
          </summary>
          <form action={priceAction} className="mt-4 grid gap-3 sm:grid-cols-2">
            <HiddenReferences
              tournamentId={tournamentId}
              tournamentPublicId={tournamentPublicId}
            />
            <input type="hidden" name="session_id" value={session.id} />
            <label className={labelClass}>
              Entry fee
              <input
                className={inputClass}
                name="entry_fee"
                inputMode="decimal"
                required
                defaultValue={minorToInput(
                  session.entryFeeMinor,
                  session.feeCurrency,
                )}
                disabled={pricePending || !priceEditable}
              />
            </label>
            <label className={labelClass}>
              Currency
              <input
                className={`${inputClass} uppercase`}
                name="fee_currency"
                minLength={3}
                maxLength={3}
                required
                defaultValue={session.feeCurrency}
                disabled={pricePending || !priceEditable}
              />
            </label>
            <label className={`${labelClass} sm:col-span-2`}>
              Audit reason
              <textarea
                className={`${inputClass} min-h-20 resize-y py-2.5 normal-case tracking-normal`}
                name="reason"
                minLength={10}
                maxLength={1000}
                required
                placeholder="Explain why this pre-participation Session price is changing."
                disabled={pricePending || !priceEditable}
              />
            </label>
            <button
              className={`${buttonClass} border-accent bg-accent text-background hover:bg-accent-hover sm:col-span-2`}
              type="submit"
              disabled={pricePending || !priceEditable}
            >
              {pricePending ? "Updating..." : "Update Session Price"}
            </button>
          </form>
          {!priceEditable ? (
            <p className="mt-3 text-xs leading-5 text-foreground-muted">
              Price editing is unavailable for this Session status.
            </p>
          ) : null}
          <Feedback state={priceState} />
          </details>
        )}
      </div>
    </article>
  );
}

function StageCard({
  canManage,
  isFreeTournament,
  sessions,
  sessionChecks,
  setup,
  stage,
  tournamentId,
  tournamentCurrency,
  tournamentPublicId,
}: {
  canManage: boolean;
  isFreeTournament: boolean;
  sessions: AdminTournamentSession[];
  sessionChecks: AdminSessionSetupCheck[];
  setup: AdminStageSetup | null;
  stage: AdminTournamentStage;
  tournamentId: string;
  tournamentCurrency: string;
  tournamentPublicId: string;
}) {
  const [configureState, configureAction, configurePending] = useActionState(
    configureTournamentStage,
    initialState,
  );
  const [createSessionState, createSessionAction, createSessionPending] =
    useActionState(createTournamentSession, initialState);
  const stageEditable =
    canManage && !["completed", "cancelled"].includes(stage.status);
  const stageIssues = sessionChecks.flatMap((check) => check.issues);
  if (!stage.configurationReady) stageIssues.unshift("configuration_incomplete");
  if (setup?.setupState && setup.setupState !== "ready") {
    stageIssues.unshift(setup.setupState);
  }
  const uniqueIssues = [...new Set(stageIssues)];
  const ready = stage.configurationReady && setup?.setupState === "ready";

  return (
    <article className="overflow-hidden rounded-[2px] border border-border-strong bg-background-elevated/55">
      <div className="border-b border-border p-4 sm:p-5">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-mono text-[0.52rem] font-semibold uppercase tracking-[0.13em] text-accent">
                Stage {String(stage.stageNumber).padStart(2, "0")}
              </span>
              <span className="rounded-[2px] border border-border-strong px-2 py-1 text-[0.48rem] uppercase tracking-[0.11em] text-foreground-muted">
                {stage.status}
              </span>
              <span
                className={`rounded-[2px] border px-2 py-1 text-[0.48rem] font-semibold uppercase tracking-[0.11em] ${
                  stage.configurationReady
                    ? "border-[#79d49b]/30 text-[#79d49b]"
                    : "border-[#ff8a65]/30 text-[#ff8a65]"
                }`}
              >
                {stage.configurationReady ? "Configured" : "Configuration required"}
              </span>
              {stage.rulesLockedAt ? (
                <span className="rounded-[2px] border border-accent/30 px-2 py-1 text-[0.48rem] uppercase tracking-[0.11em] text-accent">
                  Rules locked
                </span>
              ) : null}
            </div>
            <h3 className="type-display mt-3 break-words text-3xl uppercase sm:text-4xl">
              {stage.displayName}
            </h3>
          </div>
          <ReadinessIssues ready={ready} issues={uniqueIssues} />
        </div>

        <dl className="mt-5 grid gap-px overflow-hidden rounded-[2px] border border-border bg-border sm:grid-cols-2 lg:grid-cols-4">
          {[
            ["Matches / lobby template", stage.matchesPerLobby?.toString() ?? "Not configured"],
            ["Stage fee template", isFreeTournament ? "FREE" : formatMoney(stage.stageFeeMinor, stage.feeCurrency)],
            ["Retry allowed", isFreeTournament ? "No · Free Tournament" : stage.retryAllowed ? "Yes" : "No"],
            ["Knockout", stage.knockoutEnabled ? "Yes" : "No"],
            ["Advancement count", stage.advancementCount?.toString() ?? "Not configured"],
            ["Planned lobbies", stage.plannedLobbyCount?.toString() ?? "Not configured"],
            ["Concurrent lobby template", stage.concurrentLobbyCapacity?.toString() ?? "Not configured"],
            ["Sessions", sessions.length.toString()],
          ].map(([label, value]) => (
            <div key={label} className="bg-background p-3.5">
              <dt className="text-[0.47rem] uppercase tracking-[0.12em] text-foreground-subtle">
                {label}
              </dt>
              <dd className="mt-1.5 text-xs leading-5 text-foreground">{value}</dd>
            </div>
          ))}
        </dl>

        <div className="mt-4 grid gap-3 lg:grid-cols-2">
          <details className="rounded-[2px] border border-border-strong bg-background/60 p-3 open:border-accent/35">
            <summary className="cursor-pointer text-[0.55rem] font-semibold uppercase tracking-[0.13em] text-foreground marker:text-accent">
              Edit Stage configuration <span title="Stage values are templates copied into new Sessions; they do not rewrite existing Sessions.">ⓘ</span>
            </summary>
            <form action={configureAction} className="mt-4 grid gap-3 sm:grid-cols-2">
              <HiddenReferences tournamentId={tournamentId} tournamentPublicId={tournamentPublicId} />
              <input type="hidden" name="stage_id" value={stage.id} />
              <label className={labelClass}>
                Stage number
                <input className={inputClass} name="stage_number" type="number" min={1} max={1000} required defaultValue={stage.stageNumber} disabled={configurePending || !stageEditable} />
              </label>
              <label className={labelClass}>
                Professional name
                <select className={inputClass} name="name_preset" required defaultValue={stage.namePreset} disabled={configurePending || !stageEditable}>
                  {Object.entries(stagePresetLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
                </select>
              </label>
              <label className={`${labelClass} sm:col-span-2`}>
                Custom name · optional
                <input className={inputClass} name="custom_name" maxLength={100} defaultValue={stage.customName ?? ""} disabled={configurePending || !stageEditable} />
              </label>
              <label className={labelClass}>
                Matches / lobby template
                <input className={inputClass} name="matches_per_lobby" type="number" min={1} max={100} required defaultValue={stage.matchesPerLobby ?? ""} disabled={configurePending || !stageEditable} />
              </label>
              <label className={labelClass}>
                Advancement count
                <input className={inputClass} name="advancement_count" type="number" min={0} max={100} required defaultValue={stage.advancementCount ?? 0} disabled={configurePending || !stageEditable} />
              </label>
              {isFreeTournament ? (
                <div className="rounded-[2px] border border-[#79d49b]/30 bg-[#79d49b]/[0.04] p-3 text-xs leading-5 text-foreground-muted sm:col-span-2">
                  <input type="hidden" name="stage_fee" value="0" />
                  <input type="hidden" name="fee_currency" value={tournamentCurrency} />
                  <strong className="block text-[#79d49b]">Free Tournament · Stage fee 0</strong>
                  Retries are not available in free tournaments.
                </div>
              ) : (
                <>
                  <label className={labelClass}>
                    Stage fee template
                    <input className={inputClass} name="stage_fee" inputMode="decimal" required defaultValue={minorToInput(stage.stageFeeMinor, stage.feeCurrency)} disabled={configurePending || !stageEditable} />
                  </label>
                  <label className={labelClass}>
                    Currency
                    <input className={`${inputClass} uppercase`} name="fee_currency" minLength={3} maxLength={3} required defaultValue={stage.feeCurrency ?? tournamentCurrency} disabled={configurePending || !stageEditable} />
                  </label>
                </>
              )}
              <label className={labelClass}>
                Planned lobbies · optional
                <input className={inputClass} name="planned_lobby_count" type="number" min={1} max={26} defaultValue={stage.plannedLobbyCount ?? ""} disabled={configurePending || !stageEditable} />
              </label>
              <label className={labelClass}>
                Concurrent lobby template · optional <span title="Copied into new Sessions; each Session owns its runtime limit.">ⓘ</span>
                <input className={inputClass} name="concurrent_lobby_capacity" type="number" min={1} max={26} defaultValue={stage.concurrentLobbyCapacity ?? ""} disabled={configurePending || !stageEditable} />
              </label>
              <label className="flex min-h-10 items-center gap-2 text-xs text-foreground-muted">
                <input name="retry_allowed" type="checkbox" defaultChecked={!isFreeTournament && stage.retryAllowed} disabled={configurePending || !stageEditable || isFreeTournament} className="accent-[var(--color-accent)]" />
                {isFreeTournament ? "Retries unavailable for free tournaments" : "Paid retries allowed"}
              </label>
              <label className="flex min-h-10 items-center gap-2 text-xs text-foreground-muted">
                <input name="knockout_enabled" type="checkbox" defaultChecked={stage.knockoutEnabled} disabled={configurePending || !stageEditable} className="accent-[var(--color-accent)]" />
                Knockout Stage
              </label>
              {stage.rulesLockedAt ? (
                <label className={`${labelClass} sm:col-span-2`}>
                  Required Admin override reason
                  <textarea className={`${inputClass} min-h-20 resize-y py-2.5 normal-case tracking-normal`} name="override_reason" minLength={10} maxLength={1000} required disabled={configurePending || !stageEditable} />
                </label>
              ) : null}
              <button className={`${buttonClass} border-accent bg-accent text-background hover:bg-accent-hover sm:col-span-2`} type="submit" disabled={configurePending || !stageEditable}>
                {configurePending ? "Saving..." : "Save Stage Configuration"}
              </button>
            </form>
            <Feedback state={configureState} />
          </details>

          <details className="rounded-[2px] border border-border-strong bg-background/60 p-3 open:border-accent/35">
            <summary className="cursor-pointer text-[0.55rem] font-semibold uppercase tracking-[0.13em] text-foreground marker:text-accent">
              Create Session
            </summary>
            <form action={createSessionAction} className="mt-4 grid gap-3 sm:grid-cols-2">
              <HiddenReferences tournamentId={tournamentId} tournamentPublicId={tournamentPublicId} />
              <input type="hidden" name="stage_id" value={stage.id} />
              <label className={`${labelClass} sm:col-span-2`}>
                Session name
                <input className={inputClass} name="display_name" minLength={2} maxLength={120} required placeholder={`${stage.displayName} — Session ${sessions.length + 1}`} disabled={createSessionPending || !stageEditable || !stage.configurationReady} />
              </label>
              <label className={labelClass}>
                Starts · PKT · optional
                <input className={inputClass} name="scheduled_start_at" type="datetime-local" step={60} disabled={createSessionPending || !stageEditable || !stage.configurationReady} />
              </label>
              <label className={labelClass}>
                Ends · PKT · optional
                <input className={inputClass} name="scheduled_end_at" type="datetime-local" step={60} disabled={createSessionPending || !stageEditable || !stage.configurationReady} />
              </label>
              <button className={`${buttonClass} border-accent bg-accent text-background hover:bg-accent-hover sm:col-span-2`} type="submit" disabled={createSessionPending || !stageEditable || !stage.configurationReady}>
                {createSessionPending ? "Creating..." : "Create Session From Stage Templates"}
              </button>
            </form>
            {!stage.configurationReady ? (
              <p className="mt-3 text-xs leading-5 text-foreground-muted">
                Complete the Stage configuration before creating its first Session.
              </p>
            ) : null}
            <Feedback state={createSessionState} />
          </details>
        </div>
      </div>

      <div className="grid gap-4 p-4 sm:p-5">
        {sessions.length ? sessions.map((session) => (
          <SessionCard
            key={session.id}
            canManage={canManage}
            check={sessionChecks.find((check) => check.sessionId === session.id) ?? null}
            isFreeTournament={isFreeTournament}
            session={session}
            tournamentId={tournamentId}
            tournamentPublicId={tournamentPublicId}
          />
        )) : (
          <div className="rounded-[2px] border border-dashed border-border p-4 text-sm leading-6 text-foreground-muted">
            No Sessions exist under this Stage. Configure the Stage, then create the first exact attempt.
          </div>
        )}
      </div>
    </article>
  );
}

export function TournamentStageSessionManagement({
  canManage,
  isFreeTournament,
  sessionChecks,
  sessions,
  stageSetups,
  stages,
  tournamentId,
  tournamentCurrency,
  tournamentPublicId,
}: {
  canManage: boolean;
  isFreeTournament: boolean;
  sessionChecks: AdminSessionSetupCheck[];
  sessions: AdminTournamentSession[];
  stageSetups: AdminStageSetup[];
  stages: AdminTournamentStage[];
  tournamentId: string;
  tournamentCurrency: string;
  tournamentPublicId: string;
}) {
  const [createState, createAction, createPending] = useActionState(
    createTournamentStage,
    initialState,
  );
  const nextStageNumber = Math.max(0, ...stages.map((stage) => stage.stageNumber)) + 1;

  return (
    <section id="stages-sessions" className="scroll-mt-28 pt-10" aria-labelledby="stages-sessions-heading">
      <div className="flex flex-col gap-5 border-b border-border pb-5 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-accent">
            Competition structure
          </p>
          <h2 id="stages-sessions-heading" className="type-display mt-3 text-3xl uppercase sm:text-4xl">
            Stages &amp; Sessions
          </h2>
          <p className={`mt-3 text-[0.58rem] font-semibold uppercase tracking-[0.15em] ${isFreeTournament ? "text-[#79d49b]" : "text-accent"}`}>
            {isFreeTournament ? "Free Tournament" : "Paid Tournament"}
          </p>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-foreground-muted">
            Configure each Stage as a template, then create exact Sessions with independent runtime defaults and authoritative attempt pricing.
          </p>
        </div>

        <details className="w-full rounded-[2px] border border-border-strong bg-background-elevated/55 p-3 open:border-accent/35 lg:max-w-md">
          <summary className="cursor-pointer text-[0.56rem] font-semibold uppercase tracking-[0.13em] text-foreground marker:text-accent">
            Create Stage
          </summary>
          <form action={createAction} className="mt-4 grid gap-3 sm:grid-cols-2">
            <HiddenReferences tournamentId={tournamentId} tournamentPublicId={tournamentPublicId} />
            <label className={labelClass}>
              Stage number
              <input className={inputClass} name="stage_number" type="number" min={1} max={1000} required defaultValue={nextStageNumber} disabled={createPending || !canManage} />
            </label>
            <label className={labelClass}>
              Professional name
              <select className={inputClass} name="name_preset" defaultValue={stages.length ? "qualifier" : "open_qualifier"} disabled={createPending || !canManage}>
                {Object.entries(stagePresetLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </select>
            </label>
            <label className={`${labelClass} sm:col-span-2`}>
              Custom name · optional
              <input className={inputClass} name="custom_name" maxLength={100} disabled={createPending || !canManage} />
            </label>
            <button className={`${buttonClass} border-accent bg-accent text-background hover:bg-accent-hover sm:col-span-2`} type="submit" disabled={createPending || !canManage}>
              {createPending ? "Creating..." : "Create Stage"}
            </button>
          </form>
          <Feedback state={createState} />
        </details>
      </div>

      <div className="mt-6 grid gap-5">
        {stages.length ? stages.map((stage) => (
          <StageCard
            key={stage.id}
            canManage={canManage}
            isFreeTournament={isFreeTournament}
            sessions={sessions.filter((session) => session.stageId === stage.id)}
            sessionChecks={sessionChecks.filter((check) => check.stageId === stage.id)}
            setup={stageSetups.find((setup) => setup.stageId === stage.id) ?? null}
            stage={stage}
            tournamentId={tournamentId}
            tournamentCurrency={tournamentCurrency}
            tournamentPublicId={tournamentPublicId}
          />
        )) : (
          <div className="rounded-[2px] border border-dashed border-border p-5 text-sm leading-6 text-foreground-muted">
            No Stages exist. Create Stage 1 to begin the modern Tournament → Stage → Session setup flow.
          </div>
        )}
      </div>
    </section>
  );
}
