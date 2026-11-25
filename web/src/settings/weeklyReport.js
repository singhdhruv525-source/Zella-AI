// The weekly platform report (sql/zella_weekly_platform_report.sql) in words, for Settings, Reporting configuration.
// Pure functions, so they can be tested without a browser (weeklyReport.test.mjs).

// Each figure, in the order shown, with what it counts (the same definitions as zella_platform_weekly_summary).
export const FIGURES = [
  ["new_businesses", "New businesses", "Businesses created in the week, at any setup stage."],
  ["live_businesses", "Live businesses", "Live when the report ran, by the one shared definition: active, receptionist switched on, a number linked to Vapi."],
  ["calls", "Calls", "Every call in the week, answered or not, both directions."],
  ["missed_calls", "Missed calls", "Calls in the week whose status is missed."],
  ["texts_sent", "Texts sent", "Texts that reached the provider (sent or delivered). Test mode and blocked texts are not counted."],
  ["texts_received", "Texts received", "Texts customers sent to a business in the week."],
  ["open_alerts", "Open platform alerts", "Platform alerts still open when the report ran, of which urgent in brackets."],
  ["tickets_opened", "Support tickets opened", "Tickets opened in the week; still open or in progress when the report ran in brackets."],
  ["failed_automations", "Failed automations", "Automation runs started in the week that failed."],
];

const DAY = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
const YEAR = new Intl.DateTimeFormat("en-US", { year: "numeric", timeZone: "UTC" });
const day = (iso) => new Date(`${iso}T00:00:00Z`);

// "Nov 2 to Nov 8, 2026" (weeks run Monday to Sunday in UTC)
export function weekLabel(start, end) {
  if (!start || !end) return "Unknown week";
  const a = day(start), b = day(end);
  if (Number.isNaN(a.getTime()) || Number.isNaN(b.getTime())) return "Unknown week";
  const ya = YEAR.format(a), yb = YEAR.format(b);
  return ya === yb ? `${DAY.format(a)} to ${DAY.format(b)}, ${yb}` : `${DAY.format(a)}, ${ya} to ${DAY.format(b)}, ${yb}`;
}

const n = (v) => (typeof v === "number" && Number.isFinite(v) ? v.toLocaleString("en-US") : "Not counted");

// One row per figure: { key, label, value, definition }. Two figures carry a second number in brackets.
export function figureRows(summary) {
  const s = summary ?? {};
  return FIGURES.map(([key, label, definition]) => {
    let value = n(s[key]);
    if (key === "open_alerts" && typeof s.urgent_alerts === "number") value = `${value} (${n(s.urgent_alerts)} urgent)`;
    if (key === "tickets_opened" && typeof s.tickets_open === "number") value = `${value} (${n(s.tickets_open)} open when the report was made)`;
    return { key, label, value, definition };
  });
}

// The schedule's state in plain words. `when` formats a date and time.
export function scheduleFacts(schedule, when) {
  const s = schedule ?? {};
  const runs = s.job_on
    ? `Mondays at 08:00 UTC, for the week before. Next run ${when(s.next_run_at)}.`
    : s.job_found
      ? "Not running: the weekly scheduled job is switched off. The Zella Voice owner switches it on."
      : "Not running: the weekly scheduled job isn't set up on this database.";
  return [
    ["Report", "One weekly summary of the whole platform"],
    ["Covers", "Monday to Sunday, in UTC. A week the job didn't run has no report."],
    ["Runs", runs],
    ["In the app", "Every admin gets a notification in the alerts bell that the report is ready. Only admins with the Weekly platform report permission see the figures, here."],
    ["By email", s.email_live ? "The same notification goes in the admin email digest." : "Not yet: it goes in the admin email digest once email is live."],
  ];
}

// The server's refusal in words.
export function reportError(message) {
  return /NOT_ALLOWED/.test(String(message ?? ""))
    ? "Your admin role can't read the weekly platform report. The Zella Voice owner can give it the Weekly platform report permission in Platform roles."
    : String(message ?? "Something went wrong.");
}

// The zella_admin_weekly_reports answer, checked. Returns null when the server sent no answer, or no report list, so
// the page shows its plain load error with Try again: a missing list is never "no report yet". An explicit empty list is.
export function readWeeklyReports(data) {
  if (!data || typeof data !== "object" || Array.isArray(data) || !Array.isArray(data.reports)) return null;
  const reports = data.reports.filter((r) => r && typeof r === "object");
  return { schedule: data.schedule && typeof data.schedule === "object" ? data.schedule : {}, reports };
}

export const NO_ANSWER = "The server didn't answer.";
