// Voice page helpers (UI-14, COM-13, COM-09): which calls a tile or an alert opens, and the read only switches in
// plain words with the setting behind each as help text (UI-21). Pure, so node --test checks them.

export const CALL_DAYS = [1, 7, 30, 90];   // the periods the Calls tab offers (adminOps PERIODS)
const days = (d) => (CALL_DAYS.includes(Number(d)) ? Number(d) : 30);

// Overview tiles that open the Calls tab filtered: [key, filter]
export const TILE_FILTERS = {
  inbound: { direction: "inbound" },
  outbound: { direction: "outbound" },
  completed: { status: "completed" },
  missed: { status: "missed" },
  failed: { status: "failed" },
};
export const tileFilter = (key, period) => (TILE_FILTERS[key] ? { ...TILE_FILTERS[key], days: days(period) } : null);

// A "Needs attention" alert about calls opens the calls behind it: the missed call alert carries its own filter
export function alertCallFilter(alert) {
  const f = alert?.filter;
  if (f && typeof f === "object") {
    return { business: f.business_id ?? alert.business_id ?? null, status: f.status ?? null, direction: f.direction ?? null, days: days(f.days), failedOnly: false };
  }
  return { business: alert?.business_id ?? null, failedOnly: alert?.kind !== "call_volume_spike" };
}

// The Calls tab's starting filters from whatever opened it
export const initialCallFilter = (initial) => ({
  days: days(initial?.days), business: initial?.business ?? null, direction: initial?.direction ?? null, status: initial?.status ?? null,
  outcome: null, failedOnly: Boolean(initial?.failedOnly), q: initial?.q ?? "", offset: 0,
});

const AUTH_MODES = { bearer: "Shared token", hmac: "Signed requests", "not set": "Not set" };
const JOB_WORDS = {
  zella_jobs_every5: "Stuck and open call sweeps, every 5 minutes",
  zella_jobs_every15: "Call usage reconcile, every 15 minutes",
  zella_jobs_hourly: "Call verification, every hour",
};

// rows: { key, label, value, tone, hint } for the Switches panel; null when the database update isn't applied yet
export function voiceSwitches(s) {
  if (!s) return null;
  const mode = String(s.vapi_auth_mode ?? "not set");
  return [
    { key: "calls_live", label: "Outbound AI calls", value: s.calls_live ? "On" : "Off", tone: s.calls_live ? "success" : "neutral", hint: "Setting calls_live" },
    { key: "enforcement_calls", label: "Plan limits for calls", value: s.enforcement_calls ? "Enforced" : "Not enforced", tone: s.enforcement_calls ? "success" : "warning", hint: "Setting usage_enforcement.calls" },
    { key: "vapi_auth_mode", label: "How Vapi requests are checked", value: AUTH_MODES[mode] ?? "Unknown", tone: mode === "not set" ? "warning" : "neutral", hint: `Setting vapi_auth_mode (${mode})` },
    ...(s.jobs ?? []).map((j) => ({
      key: j.name, label: JOB_WORDS[j.name] ?? "Scheduled job",
      value: !j.exists ? "Not created" : j.active ? "On" : j.intended === "off" ? "Off on purpose" : "Off",
      tone: j.active ? "success" : "neutral", hint: `Scheduled job ${j.name}${(j.runs ?? []).length ? `, runs ${j.runs.join(", ")}` : ""}`,
    })),
  ];
}

// Phone numbers and time zones in words (docs/DESIGN_SYSTEM.md, Writing: phones use spaces). The same rules as the
// shared lib/format.js on the design system branch; switch to it once that lands.
const blank = (v) => v === null || v === undefined || v === "";

// "+15551230001" -> "(555) 123 0001". Numbers outside North America keep their country code, grouped with spaces.
// Anything that isn't a number (a caller's name) comes back as it was.
export function formatPhone(value) {
  if (blank(value)) return "";
  const raw = String(value).trim();
  const digits = raw.replace(/\D/g, "");
  if (!/^\+?[\d\s().]+$/.test(raw)) return raw;
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
  if (blank(zone)) return "";
  const city = String(zone).split("/").pop().replace(/_/g, " ");
  try {
    const part = new Intl.DateTimeFormat("en-US", { timeZone: zone, timeZoneName: "longGeneric" })
      .formatToParts(new Date()).find((p) => p.type === "timeZoneName")?.value;
    if (!part) return city;
    return part.includes(city) ? part : `${part} (${city})`;
  } catch {
    return city;
  }
}

// Calls table: Number, Length and Outcome are often all unrecorded (calls that never connected). When that is true
// for every row shown, the table shows one Details column instead of three columns of the same empty word.
export const callDetailsBare = (r) => blank(r?.number) && blank(r?.duration_seconds) && blank(r?.outcome);
export const callDetailsCollapsed = (rows) => Array.isArray(rows) && rows.length > 0 && rows.every(callDetailsBare);
