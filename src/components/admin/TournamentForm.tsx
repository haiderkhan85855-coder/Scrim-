"use client";

import { useActionState, useEffect, useRef, useState } from "react";

import {
  createTournament,
  type TournamentActionState,
  updateDraftTournament,
} from "@/app/admin/actions";
import type {
  AdminTournament,
  TournamentRewardModel,
} from "@/components/admin/types";
import { formatTournamentDateTimeInput } from "@/lib/tournaments/dateTime";
import { currencyFractionDigits } from "@/lib/tournaments/money";

const initialState: TournamentActionState = {};
const inputClasses =
  "mt-2 min-h-11 w-full rounded-[2px] border border-border-strong bg-background/75 px-3.5 text-sm text-foreground outline-none transition-colors placeholder:text-foreground-subtle focus:border-accent focus:ring-1 focus:ring-accent/30 disabled:opacity-50";
const labelClasses =
  "text-[0.58rem] font-semibold uppercase tracking-[0.17em] text-foreground-muted";

function minorToInput(value: number | null, currency: string) {
  if (value === null) return "";
  const digits = currencyFractionDigits(currency);
  const scale = 10 ** digits;
  const whole = Math.floor(value / scale);
  const fraction = String(value % scale).padStart(digits, "0");
  const significantFraction = fraction.replace(/0+$/, "");
  return significantFraction ? `${whole}.${significantFraction}` : String(whole);
}

type TournamentFormProps = {
  tournament?: AdminTournament;
  onCancel?: () => void;
  onSuccess?: (message: string) => void;
};

export function TournamentForm({
  tournament,
  onCancel,
  onSuccess,
}: TournamentFormProps) {
  const action = tournament ? updateDraftTournament : createTournament;
  const [state, formAction, pending] = useActionState(action, initialState);
  const reportedSuccessRef = useRef<string | null>(null);
  const [rewardModel, setRewardModel] = useState<TournamentRewardModel>(
    tournament?.rewardModel ?? "fixed_prize_pool",
  );
  const currency = tournament?.currency ?? "PKR";

  useEffect(() => {
    if (!state.success || reportedSuccessRef.current === state.success) return;
    reportedSuccessRef.current = state.success;
    onSuccess?.(state.success);
  }, [onSuccess, state.success]);

  return (
    <form action={formAction} className="mt-6">
      {tournament ? (
        <>
          <input type="hidden" name="tournament_id" value={tournament.id} />
          <input
            type="hidden"
            name="public_tournament_id"
            value={tournament.tournamentId}
          />
        </>
      ) : null}

      <div className="grid gap-5 lg:grid-cols-2">
        <label className="block lg:col-span-2">
          <span className={labelClasses}>Tournament Name</span>
          <input
            name="name"
            type="text"
            required
            minLength={2}
            maxLength={120}
            defaultValue={tournament?.name}
            disabled={pending}
            className={inputClasses}
            placeholder="LevelledUp Weekend Clash"
          />
        </label>

        <label className="block lg:col-span-2">
          <span className={labelClasses}>Description · Optional</span>
          <textarea
            name="description"
            maxLength={5000}
            defaultValue={tournament?.description ?? ""}
            disabled={pending}
            rows={4}
            className={`${inputClasses} resize-y py-3`}
            placeholder="Operational notes and public tournament details."
          />
        </label>

        <label className="block">
          <span className={labelClasses}>Start Date / Time · PKT</span>
          <input
            name="scheduled_start_at"
            type="datetime-local"
            required
            step={60}
            defaultValue={formatTournamentDateTimeInput(
              tournament?.scheduledStartAt ?? null,
            )}
            disabled={pending}
            className={inputClasses}
          />
        </label>

        <label className="block">
          <span className={labelClasses}>End Date / Time · PKT · Optional</span>
          <input
            name="scheduled_end_at"
            type="datetime-local"
            step={60}
            defaultValue={formatTournamentDateTimeInput(
              tournament?.scheduledEndAt ?? null,
            )}
            disabled={pending}
            className={inputClasses}
          />
        </label>

        <label className="block">
          <span className={labelClasses}>Registration Opens · PKT</span>
          <input
            name="registration_opens_at"
            type="datetime-local"
            required
            step={60}
            defaultValue={formatTournamentDateTimeInput(
              tournament?.registrationOpensAt ?? null,
            )}
            disabled={pending}
            className={inputClasses}
          />
        </label>

        <label className="block">
          <span className={labelClasses}>Registration Closes · PKT</span>
          <input
            name="registration_closes_at"
            type="datetime-local"
            required
            step={60}
            defaultValue={formatTournamentDateTimeInput(
              tournament?.registrationClosesAt ?? null,
            )}
            disabled={pending}
            className={inputClasses}
          />
        </label>

        <label className="block">
          <span className={labelClasses}>Maximum Team Slots</span>
          <input
            name="max_team_slots"
            type="number"
            min={1}
            max={1000}
            required
            defaultValue={tournament?.maxTeamSlots ?? 16}
            disabled={pending}
            className={inputClasses}
          />
        </label>

        <div className="grid grid-cols-2 gap-3">
          <label className="block">
            <span className={labelClasses}>Matches / Day · Legacy Display</span>
            <input
              name="matches_per_day"
              type="number"
              min={1}
              max={100}
              required
              defaultValue={tournament?.matchesPerDay ?? 3}
              disabled={pending}
              className={inputClasses}
            />
          </label>
          <label className="block">
            <span className={labelClasses}>Schedule Days · Legacy Display</span>
            <input
              name="number_of_days"
              type="number"
              min={1}
              max={365}
              required
              defaultValue={tournament?.numberOfDays ?? 1}
              disabled={pending}
              className={inputClasses}
            />
          </label>
        </div>
        <p className="-mt-2 text-[0.58rem] leading-4 text-foreground-subtle">
          Presentation defaults only. Runtime match counts are configured per
          Stage and Session.
        </p>

        <label className="block">
          <span className={labelClasses}>Game Mode</span>
          <select
            name="game_mode"
            defaultValue={tournament?.gameMode ?? "squad"}
            disabled={pending}
            className={inputClasses}
          >
            <option value="solo">Solo</option>
            <option value="duo">Duo</option>
            <option value="squad">Squad</option>
          </select>
        </label>

        <label className="block">
          <span className={labelClasses}>Perspective</span>
          <select
            name="perspective"
            defaultValue={tournament?.perspective ?? "tpp"}
            disabled={pending}
            className={inputClasses}
          >
            <option value="tpp">TPP</option>
            <option value="fpp">FPP</option>
          </select>
        </label>

        <label className="block">
          <span className={labelClasses}>Initial Registration Fee</span>
          <input
            name="entry_fee"
            type="text"
            inputMode="decimal"
            required
            defaultValue={minorToInput(tournament?.entryFeeMinor ?? 0, currency)}
            disabled={pending}
            className={inputClasses}
            placeholder="150"
          />
          <span className="mt-1 block text-[0.58rem] leading-4 text-foreground-subtle">
            0 = Free Tournament; greater than 0 = Paid Tournament. Later paid
            attempts use each Session&apos;s authoritative price.
          </span>
        </label>

        <label className="block">
          <span className={labelClasses}>Currency</span>
          <input
            name="currency"
            type="text"
            required
            minLength={3}
            maxLength={3}
            defaultValue={currency}
            disabled={pending}
            className={`${inputClasses} uppercase`}
            placeholder="PKR"
          />
        </label>

        <label className="block">
          <span className={labelClasses}>Reward Model</span>
          <select
            name="reward_model"
            value={rewardModel}
            onChange={(event) =>
              setRewardModel(event.target.value as TournamentRewardModel)
            }
            disabled={pending}
            className={inputClasses}
          >
            <option value="fixed_prize_pool">Fixed Prize Pool</option>
            <option value="per_kill">Per Kill</option>
          </select>
        </label>

        {rewardModel === "fixed_prize_pool" ? (
          <label className="block">
            <span className={labelClasses}>Prize Pool</span>
            <input
              name="prize_pool"
              type="text"
              inputMode="decimal"
              required
              defaultValue={minorToInput(tournament?.prizePoolMinor ?? 0, currency)}
              disabled={pending}
              className={inputClasses}
              placeholder="5000"
            />
          </label>
        ) : (
          <label className="block">
            <span className={labelClasses}>Per Kill Reward</span>
            <input
              name="per_kill_reward"
              type="text"
              inputMode="decimal"
              required
              defaultValue={minorToInput(
                tournament?.perKillRewardMinor ?? null,
                currency,
              )}
              disabled={pending}
              className={inputClasses}
              placeholder="100"
            />
          </label>
        )}
      </div>

      <div aria-live="polite" className="mt-5 min-h-6">
        {state.error ? (
          <p role="alert" className="text-sm text-[#ff8a65]">
            {state.error}
          </p>
        ) : state.success ? (
          <p role="status" className="text-sm text-[#79d49b]">
            ✓ {state.success}
          </p>
        ) : null}
      </div>

      <div className="mt-2 flex flex-wrap gap-3">
        <button
          type="submit"
          disabled={pending}
          className="inline-flex min-h-11 items-center justify-center rounded-[2px] bg-accent px-5 text-[0.62rem] font-semibold uppercase tracking-[0.16em] text-background transition-colors hover:bg-accent-hover disabled:opacity-50"
        >
          {pending
            ? tournament
              ? "Publishing..."
              : "Saving..."
            : tournament
              ? "Publish Changes"
              : "Create Tournament"}
        </button>
        {onCancel ? (
          <button
            type="button"
            onClick={onCancel}
            disabled={pending}
            className="inline-flex min-h-11 items-center justify-center rounded-[2px] border border-border-strong px-5 text-[0.62rem] font-semibold uppercase tracking-[0.16em] text-foreground-muted transition-colors hover:border-foreground/35 hover:text-foreground"
          >
            Close Editor
          </button>
        ) : null}
      </div>
    </form>
  );
}
