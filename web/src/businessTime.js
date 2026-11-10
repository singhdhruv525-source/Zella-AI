// Date helpers that work in the business's own time zone, so "today"
// for a Chicago clinic is Chicago's today, whoever is looking.

function zonedParts(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date);
  const v = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  return {
    year: Number(v.year),
    month: Number(v.month),
    day: Number(v.day),
    hour: Number(v.hour),
    minute: Number(v.minute),
    second: Number(v.second),
  };
}

// Milliseconds the zone is ahead of UTC at the given instant.
function zoneOffset(date, timeZone) {
  const p = zonedParts(date, timeZone);
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - date.getTime();
}

// The instant when the given calendar day starts in the zone.
function zonedMidnight(year, month, day, timeZone) {
  const guess = Date.UTC(year, month - 1, day);
  let instant = guess - zoneOffset(new Date(guess), timeZone);
  // Second pass corrects for a daylight-saving change between guess and result.
  instant = guess - zoneOffset(new Date(instant), timeZone);
  return new Date(instant);
}

// Start and end of a day in the zone. offsetDays: 0 = today, 1 = tomorrow, -7 = a week ago.
export function dayRange(timeZone, offsetDays = 0, now = new Date()) {
  const p = zonedParts(now, timeZone);
  const start = zonedMidnight(p.year, p.month, p.day + offsetDays, timeZone);
  const end = zonedMidnight(p.year, p.month, p.day + offsetDays + 1, timeZone);
  return { start, end };
}

export function formatTime(value, timeZone) {
  if (!value) return "—";
  return new Date(value).toLocaleTimeString("en-US", { timeZone, hour: "numeric", minute: "2-digit" });
}

export function formatDay(value, timeZone) {
  if (!value) return "—";
  return new Date(value).toLocaleDateString("en-US", {
    timeZone, weekday: "short", month: "short", day: "numeric",
  });
}

export function formatLongDate(value, timeZone) {
  return new Date(value).toLocaleDateString("en-US", {
    timeZone, weekday: "long", month: "long", day: "numeric",
  });
}

export function greeting(timeZone, now = new Date()) {
  const hour = zonedParts(now, timeZone).hour;
  if (hour < 12) return "Good morning";
  if (hour < 17) return "Good afternoon";
  return "Good evening";
}

export function timeAgo(value) {
  if (!value) return "—";
  const minutes = Math.round((Date.now() - new Date(value).getTime()) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  return `${Math.round(hours / 24)} d ago`;
}

// "2026-10-30" + "14:00" in the business's zone → the exact instant.
export function zonedDateTime(dateStr, timeStr, timeZone) {
  const [year, month, day] = dateStr.split("-").map(Number);
  const [hour, minute] = timeStr.split(":").map(Number);
  const guess = Date.UTC(year, month - 1, day, hour, minute);
  let instant = guess - zoneOffset(new Date(guess), timeZone);
  instant = guess - zoneOffset(new Date(instant), timeZone);
  return new Date(instant);
}

// Today's date in the zone as "YYYY-MM-DD" (for date inputs).
export function todayInput(timeZone, now = new Date()) {
  const p = zonedParts(now, timeZone);
  return `${p.year}-${String(p.month).padStart(2, "0")}-${String(p.day).padStart(2, "0")}`;
}
