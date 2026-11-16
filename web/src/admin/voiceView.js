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
