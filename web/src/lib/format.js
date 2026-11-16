// One place for how numbers, times, phone numbers and time zones read on screen (docs/DESIGN_SYSTEM.md, Writing).
// Each helper returns plain text, or "" when there is no value, so callers choose the empty word
// (EmptyValue: "None", "Not set" or "Never").

const LOCALE = "en-US";
const empty = (v) => v === null || v === undefined || v === "";

const countFormat = new Intl.NumberFormat(LOCALE);

// 1203 -> "1,203"
export function formatCount(n) {
  if (empty(n)) return "";
  const v = Number(n);
  return Number.isFinite(v) ? countFormat.format(v) : "";
}

const toDate = (value) => {
  if (empty(value)) return null;
  const d = value instanceof Date ? value : new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
};

// "Nov 16, 2026 at 2:49 PM"
export function formatDateTime(value) {
  const d = toDate(value);
  if (!d) return "";
  const date = d.toLocaleDateString(LOCALE, { month: "short", day: "numeric", year: "numeric" });
  const time = d.toLocaleTimeString(LOCALE, { hour: "numeric", minute: "2-digit" });
  return `${date} at ${time}`;
}

// "Nov 16, 2026"
export function formatDate(value) {
  const d = toDate(value);
  return d ? d.toLocaleDateString(LOCALE, { month: "short", day: "numeric", year: "numeric" }) : "";
}

// "2:44 PM"
export function formatTime(value) {
  const d = toDate(value);
  return d ? d.toLocaleTimeString(LOCALE, { hour: "numeric", minute: "2-digit" }) : "";
}

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

// "Just now", "5 minutes ago", "3 hours ago", "Yesterday", "5 days ago", then the date. Never "5 d ago".
// Put formatDateTime(value) in a title next to it so the exact time is one hover away.
export function formatRelative(value, now = Date.now()) {
  const d = toDate(value);
  if (!d) return "";
  const seconds = Math.round((now - d.getTime()) / 1000);
  if (seconds < 0) return formatDateTime(d);
  if (seconds < 60) return "Just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${plural(minutes, "minute")} ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${plural(hours, "hour")} ago`;
  const days = Math.round(hours / 24);
  if (days === 1) return "Yesterday";
  if (days < 30) return `${plural(days, "day")} ago`;
  return formatDate(d);
}

// "+15551230001" -> "(555) 123 0001". Phones use spaces, never dashes. Numbers outside North America keep their
// country code and are grouped with spaces.
export function formatPhone(value) {
  if (empty(value)) return "";
  const raw = String(value).trim();
  const digits = raw.replace(/\D/g, "");
  const nanp = digits.length === 11 && digits.startsWith("1") ? digits.slice(1) : digits.length === 10 && !raw.startsWith("+") ? digits : null;
  if (nanp) return `(${nanp.slice(0, 3)}) ${nanp.slice(3, 6)} ${nanp.slice(6)}`;
  if (digits.length < 8) return raw;
  const national = digits.slice(-10);
  const country = digits.length > 10 ? `+${digits.slice(0, digits.length - 10)} ` : raw.startsWith("+") ? "+" : "";
  const head = national.slice(0, -7);
  return `${country}${head ? `${head} ` : ""}${national.slice(-7, -4)} ${national.slice(-4)}`;
}

// "America/New_York" -> "Eastern Time (New York)"
export function formatTimeZone(zone) {
  if (empty(zone)) return "";
  const city = String(zone).split("/").pop().replace(/_/g, " ");
  try {
    const part = new Intl.DateTimeFormat(LOCALE, { timeZone: zone, timeZoneName: "longGeneric" })
      .formatToParts(new Date()).find((p) => p.type === "timeZoneName")?.value;
    if (!part) return city;
    return part.includes(city) ? part : `${part} (${city})`;
  } catch {
    return city;
  }
}

// 75 -> "1 min 15 s"
export function formatDuration(seconds) {
  if (empty(seconds)) return "";
  const v = Math.round(Number(seconds));
  if (!Number.isFinite(v)) return "";
  return v < 60 ? `${v} s` : `${Math.floor(v / 60)} min ${v % 60} s`;
}
