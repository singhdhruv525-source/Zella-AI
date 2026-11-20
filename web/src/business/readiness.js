// The readiness ladder from zella_business_readiness, as rows for the Overview (BIZ-11). Pure:
// web/tests/businessReadiness.test.mjs.
export const RUNG_LABELS = {
  saved: "saved, setup not complete",
  setup_complete: "setup complete",
  integrations_verified: "connections verified",
  ready: "ready to go live",
  live: "live",
};
const TITLES = {
  owner: "Owner", steps: "Setup steps", hours: "Opening hours", records: "Industry records", phone: "Phone number",
  voice: "Voice connection", capabilities: "Switched on features", receptionist: "AI receptionist", live: "Live",
};
const ORDER = ["setup_complete", "integrations_verified", "ready", "live"];

// { state, rows: [{ key, title, ok, detail, rung }] } in ladder order; tolerant of a missing or odd report.
export function readinessRows(report) {
  const checks = Array.isArray(report?.checks) ? report.checks : [];
  const rows = checks
    .map((c) => ({ key: String(c.key), title: TITLES[c.key] ?? String(c.key), ok: c.ok === true, detail: String(c.detail ?? ""), rung: c.rung }))
    .sort((a, b) => ORDER.indexOf(a.rung) - ORDER.indexOf(b.rung));
  return { state: typeof report?.state === "string" ? report.state : "saved", rows };
}
