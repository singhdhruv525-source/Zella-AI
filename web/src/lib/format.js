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
  // Some runtimes put a narrow no break space before AM or PM; one plain space everywhere.
  const time = d.toLocaleTimeString(LOCALE, { hour: "numeric", minute: "2-digit" }).replace(/\s+/g, " ");
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

// A count with the word that agrees with it: (1, "arrival") -> "1 arrival", (4, "enquiry", "enquiries") -> "4 enquiries".
// Pass `many` whenever the plural is not just the word plus "s".
export function countWord(n, one, many) {
  return `${n} ${n === 1 ? one : many ?? `${one}s`}`;
}

// A calendar day with no time: "2026-11-23" -> "Nov 23". Read in UTC so the day never shifts with the viewer's zone.
export function formatMonthDay(value) {
  if (empty(value)) return "";
  const d = typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) ? new Date(`${value}T00:00:00Z`) : toDate(value);
  if (!d || Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString(LOCALE, { month: "short", day: "numeric", timeZone: "UTC" });
}

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
  // anything beyond digits and the usual separators (an extension such as "ext 45", "x45" or "#45") keeps its own text,
  // so its digits never merge into the number
  if (/[^\d\s+().\-/]/.test(raw)) return raw;
  const digits = raw.replace(/\D/g, "");
  const nanp = digits.length === 11 && digits.startsWith("1") ? digits.slice(1) : digits.length === 10 && !raw.startsWith("+") ? digits : null;
  if (nanp) return `(${nanp.slice(0, 3)}) ${nanp.slice(3, 6)} ${nanp.slice(6)}`;
  if (digits.length < 8) return raw;
  // An international number keeps its real country code (ITU E.164: 1, 7, a listed two digit code, else three digits),
  // and the rest is grouped from the right.
  const intl = raw.startsWith("+") || digits.length > 10;
  const cc = intl ? callingCode(digits) : "";
  const national = digits.slice(cc.length);
  const head = national.slice(0, -7);
  return `${cc ? `+${cc} ` : ""}${head ? `${head} ` : ""}${national.slice(-7, -4)} ${national.slice(-4)}`;
}

// A search finds a phone number whether it is typed raw ("+12025550123") or as shown ("(202) 555 0123"): digits only,
// at least 3 of them, matched with and without the leading 1 of a US or Canadian number.
export function phoneMatches(phone, query) {
  const want = String(query ?? "").replace(/\D/g, "");
  if (want.length < 3 || empty(phone)) return false;
  const have = String(phone).replace(/\D/g, "");
  const national = (d) => (d.length === 11 && d.startsWith("1") ? d.slice(1) : d);
  return have.includes(want) || national(have).includes(national(want));
}

const TWO_DIGIT_CODES = new Set(["20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47",
  "48", "49", "51", "52", "53", "54", "55", "56", "57", "58", "60", "61", "62", "63", "64", "65", "66", "81", "82", "84", "86",
  "90", "91", "92", "93", "94", "95", "98"]);
function callingCode(digits) {
  if (digits.startsWith("1") || digits.startsWith("7")) return digits[0];
  return TWO_DIGIT_CODES.has(digits.slice(0, 2)) ? digits.slice(0, 2) : digits.slice(0, 3);
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
  const n = Number(seconds);
  if (!Number.isFinite(n)) return "";
  const v = Math.max(0, Math.round(n));
  if (v < 60) return `${v} s`;
  if (v < 3600) return v % 60 ? `${Math.floor(v / 60)} min ${v % 60} s` : `${v / 60} min`;
  const m = Math.floor((v % 3600) / 60);
  return m ? `${Math.floor(v / 3600)} h ${m} min` : `${Math.floor(v / 3600)} h`;
}

// A wall clock time with no zone of its own, read as written: "2026-11-15T10:00" -> "Nov 15, 2026, 10:00 AM".
// For times stored in a business's local time (an offer's start and end): never shifted by the viewer's zone.
export function formatWallTime(value) {
  if (empty(value)) return "";
  const m = String(value).match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/);
  if (!m) return String(value);
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]));
  return d.toLocaleString(LOCALE, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit", timeZone: "UTC" }).replace(/\s+/g, " ");
}
