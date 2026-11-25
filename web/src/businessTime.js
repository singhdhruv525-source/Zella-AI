// Date helpers that work in the business's own time zone, so "today"
// for a Chicago clinic is Chicago's today, whoever is looking.

import { formatRelative } from "./lib/format.js";

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
  // Where the clocks skip midnight (America/Santiago in September jumps from 00:00 to 01:00), that instant is still
  // the evening before in the zone: move on to the first instant whose local date is the requested day.
  const p = zonedParts(new Date(instant), timeZone);
  if (Date.UTC(p.year, p.month - 1, p.day) < guess) {
    instant += (24 * 3600 - (p.hour * 3600 + p.minute * 60 + p.second)) * 1000;
  }
  return new Date(instant);
}

// Start and end of a day in the zone. offsetDays: 0 = today, 1 = tomorrow, -7 = a week ago.
export function dayRange(timeZone, offsetDays = 0, now = new Date()) {
  const p = zonedParts(now, timeZone);
  const start = zonedMidnight(p.year, p.month, p.day + offsetDays, timeZone);
  const end = zonedMidnight(p.year, p.month, p.day + offsetDays + 1, timeZone);
  return { start, end };
}

// Milliseconds from now until a moment after the business's next midnight (one second past it), kept within what a
// browser timer accepts. Reports schedules its day rollover refresh with it.
export function msUntilNextDay(timeZone, now = new Date()) {
  const wait = dayRange(timeZone, 1, now).start.getTime() - now.getTime() + 1000;
  return Math.max(1000, Math.min(wait, 2147483647));
}

export function formatTime(value, timeZone) {
  if (!value) return "None";
  return new Date(value).toLocaleTimeString("en-US", { timeZone, hour: "numeric", minute: "2-digit" });
}

export function formatDay(value, timeZone) {
  if (!value) return "None";
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

// "13 minutes ago", "2 hours ago", "yesterday", "5 days ago", in full words (lib/format.js formatRelative), written to
// sit inside a sentence ("added yesterday"). timeAgoLabel is the same on its own, as in a table cell ("Yesterday").
export function timeAgo(value) {
  const text = timeAgoLabel(value);
  return /^(Just now|Yesterday)$/.test(text) ? text.toLowerCase() : text;
}

export function timeAgoLabel(value) {
  if (!value) return "None";
  return formatRelative(value) || "None";
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
