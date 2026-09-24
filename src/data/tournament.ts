export type PublicTournamentPresentation = {
  id: string;
  title: string;
  status: "LIVE" | "REGISTRATION OPEN" | "REGISTRATION CLOSED";
  statusCode: "live" | "registration_open" | "registration_closed";
  game: string;
  mode: string;
  rewardLabel: "Prize Pool" | "Per Kill";
  rewardValue: string;
  entryFee: string;
  maxTeams: number;
  registeredTeams: number;
  formatTags: string[];
  startsAt: string;
  ctaLabel: "JOIN SCRIM" | "VIEW DETAILS";
  priority?: boolean;
};
