export type HowItWorksStep = {
  id: string;
  title: string;
  description: string;
  help?: {
    term: string;
    description: string;
  };
};

export const howItWorksSteps = [
  {
    id: "register",
    title: "Register",
    description: "Create or join your Squad.",
  },
  {
    id: "enter",
    title: "Enter",
    description: "Choose a Tournament Session and secure your entry.",
    help: {
      term: "Session",
      description: "One scheduled opportunity for Squads to enter and compete in a Tournament Stage.",
    },
  },
  {
    id: "drop",
    title: "Drop",
    description: "Receive Lobby and room information, then play your scheduled Matches.",
    help: {
      term: "Lobby",
      description: "The room grouping for entered Squads. Your Session Entry remains your participation identity.",
    },
  },
  {
    id: "dominate",
    title: "Dominate",
    description: "Finalized results, points and standings build your competitive record.",
  },
] satisfies HowItWorksStep[];
