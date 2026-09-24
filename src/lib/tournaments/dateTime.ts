export const TOURNAMENT_TIME_ZONE = "Asia/Karachi";
export const TOURNAMENT_TIME_ZONE_LABEL = "PKT";

const dateTimeInputPattern =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;

type DateTimeParts = {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
};

const partsFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: TOURNAMENT_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

const displayFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: TOURNAMENT_TIME_ZONE,
  day: "2-digit",
  month: "short",
  year: "numeric",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});

function dateParts(date: Date) {
  const values = new Map(
    partsFormatter
      .formatToParts(date)
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, Number(part.value)]),
  );

  return {
    year: values.get("year") ?? 0,
    month: values.get("month") ?? 0,
    day: values.get("day") ?? 0,
    hour: values.get("hour") ?? 0,
    minute: values.get("minute") ?? 0,
    second: values.get("second") ?? 0,
  };
}

function timeZoneOffsetMilliseconds(instant: number) {
  const parts = dateParts(new Date(instant));
  const representedAsUtc = Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
    parts.second,
  );

  return representedAsUtc - instant;
}

function sameWallClock(parts: DateTimeParts, date: Date) {
  const rendered = dateParts(date);
  return (
    rendered.year === parts.year &&
    rendered.month === parts.month &&
    rendered.day === parts.day &&
    rendered.hour === parts.hour &&
    rendered.minute === parts.minute
  );
}

export function tournamentDateTimeInputToUtc(value: string) {
  const match = dateTimeInputPattern.exec(value);
  if (!match) return null;

  const parts: DateTimeParts = {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
    hour: Number(match[4]),
    minute: Number(match[5]),
  };
  const wallClockAsUtc = Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
  );
  const normalized = new Date(wallClockAsUtc);

  if (
    normalized.getUTCFullYear() !== parts.year ||
    normalized.getUTCMonth() + 1 !== parts.month ||
    normalized.getUTCDate() !== parts.day ||
    normalized.getUTCHours() !== parts.hour ||
    normalized.getUTCMinutes() !== parts.minute
  ) {
    return null;
  }

  let instant =
    wallClockAsUtc - timeZoneOffsetMilliseconds(wallClockAsUtc);
  const resolvedOffset = timeZoneOffsetMilliseconds(instant);
  instant = wallClockAsUtc - resolvedOffset;

  const date = new Date(instant);
  return sameWallClock(parts, date) ? date.toISOString() : null;
}

export function formatTournamentDateTimeInput(value: string | null) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const parts = dateParts(date);

  return `${String(parts.year).padStart(4, "0")}-${String(parts.month).padStart(
    2,
    "0",
  )}-${String(parts.day).padStart(2, "0")}T${String(parts.hour).padStart(
    2,
    "0",
  )}:${String(parts.minute).padStart(2, "0")}`;
}

export function formatTournamentDateTime(value: string | null) {
  if (!value) return "Not set";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Invalid date";

  const formatted = displayFormatter
    .format(date)
    .replace(/\b(am|pm)\b/i, (period) => period.toUpperCase());

  return `${formatted} ${TOURNAMENT_TIME_ZONE_LABEL}`;
}
