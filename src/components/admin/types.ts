export type TournamentStatus =
  | "draft"
  | "registration_open"
  | "registration_closed"
  | "live"
  | "completed"
  | "cancelled";

export type TournamentRewardModel = "fixed_prize_pool" | "per_kill";
export type TournamentGameMode = "solo" | "duo" | "squad";
export type TournamentPerspective = "tpp" | "fpp";
export type TournamentRegistrationStatus =
  | "pending"
  | "confirmed"
  | "rejected"
  | "withdrawn";
export type TournamentRosterStatus = "draft" | "finalized" | "locked";
export type TournamentRosterRole = "captain" | "member" | "substitute";
export type TournamentPaymentStatus = "pending" | "verified" | "rejected";
export type TournamentCreditStatus = "available" | "used" | "refunded";

export type AdminTournament = {
  id: string;
  tournamentId: string;
  name: string;
  description: string | null;
  status: TournamentStatus;
  scheduledStartAt: string;
  scheduledEndAt: string | null;
  registrationOpensAt: string;
  registrationClosesAt: string;
  maxTeamSlots: number;
  matchesPerDay: number;
  numberOfDays: number;
  gameMode: TournamentGameMode;
  perspective: TournamentPerspective;
  entryFeeMinor: number;
  currency: string;
  rewardModel: TournamentRewardModel;
  prizePoolMinor: number | null;
  perKillRewardMinor: number | null;
  archivedAt: string | null;
  updatedAt: string;
};

export type TournamentRosterSnapshotMember = {
  id: string;
  displayName: string;
  pubgUid: string;
  pubgIgn: string | null;
  role: TournamentRosterRole;
};

export type AdminTournamentRegistration = {
  id: string;
  teamName: string;
  teamPublicId: string;
  teamStatus: "active" | "disbanded";
  status: TournamentRegistrationStatus;
  rosterStatus: TournamentRosterStatus;
  slotNumber: number | null;
  assignment: {
    id: string;
    registrationId: string;
    stageId: string;
    stageName: string;
    tierLabel: string | null;
    lobbyId: string;
    lobbyLabel: string;
    slotNumber: number;
  } | null;
  registeredAt: string;
  initialSession: {
    id: string;
    name: string;
    scheduledStartAt: string | null;
    scheduledEndAt: string | null;
    entryFeeMinor: number;
    feeCurrency: string;
  } | null;
  initialSessionValid: boolean;
  paymentRequired: boolean;
  paymentStatus: TournamentPaymentStatus | null;
  roster: TournamentRosterSnapshotMember[];
};

export type AdminTournamentLobby = {
  id: string;
  label: string;
  code: string;
  order: number;
  capacity: number;
  status: "planned" | "open" | "locked" | "completed" | "cancelled";
  stageId: string;
  stageNumber: number;
  sessionId: string;
  sessionNumber: number;
  sessionDisplayName: string;
};

export type AdminTournamentStage = {
  id: string;
  tournamentId: string;
  stageNumber: number;
  displayName: string;
  namePreset:
    | "open_qualifier"
    | "qualifier"
    | "quarterfinal"
    | "semifinal"
    | "grand_final";
  customName: string | null;
  status: "planned" | "active" | "completed" | "cancelled";
  matchesPerLobby: number | null;
  stageFeeMinor: number | null;
  feeCurrency: string | null;
  retryAllowed: boolean;
  knockoutEnabled: boolean;
  advancementCount: number | null;
  plannedLobbyCount: number | null;
  concurrentLobbyCapacity: number | null;
  rulesLockedAt: string | null;
  configurationReady: boolean;
};

export type AdminTournamentSession = {
  id: string;
  tournamentId: string;
  stageId: string;
  sessionNumber: number;
  displayName: string;
  scheduledStartAt: string | null;
  scheduledEndAt: string | null;
  maxConcurrentLobbies: number | null;
  defaultMatchesPerLobby: number | null;
  entryFeeMinor: number;
  feeCurrency: string;
  status: "planned" | "open" | "live" | "completed" | "cancelled";
  isLegacyBackfill: boolean;
};

export type AdminTournamentSessionEntry = {
  id: string;
  teamName: string;
  teamPublicId: string;
  stageName: string;
  sessionName: string;
  registrationStatus: string;
  status: "active" | "cancelled";
  sourceType: string;
  createdAt: string;
  reason: string;
  cancelledAt: string | null;
  cancellationReason: string | null;
};

export type AdminStageSetup = {
  stageId: string;
  setupState: string;
  actualLobbyCount: number;
  scheduledLobbyCount: number;
};

export type AdminSessionSetupCheck = {
  stageId: string;
  sessionId: string | null;
  setupComplete: boolean;
  issues: string[];
};

export type AdminTournamentPayment = {
  id: string;
  registrationId: string;
  teamName: string;
  teamPublicId: string;
  status: TournamentPaymentStatus;
  expectedAmountMinor: number;
  currency: string;
  referenceId: string;
  referenceConflict: boolean;
  submittedAt: string;
};

export type AdminTournamentCredit = {
  id: string;
  registrationId: string;
  teamName: string;
  teamPublicId: string;
  amountMinor: number;
  currency: string;
  sourceReferenceId: string;
  status: TournamentCreditStatus;
  createdAt: string;
};
