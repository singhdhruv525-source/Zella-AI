import { test } from "node:test";
import assert from "node:assert/strict";
import { FIGURES, figureRows, reportError, scheduleFacts, weekLabel } from "./weeklyReport.js";

const when = (v) => (v ? `at ${v}` : "None");

test("a week reads Monday to Sunday in UTC, across a year end too", () => {
  assert.equal(weekLabel("2026-11-02", "2026-11-08"), "Nov 2 to Nov 8, 2026");
  assert.equal(weekLabel("2026-12-28", "2027-01-03"), "Dec 28, 2026 to Jan 3, 2027");
  assert.equal(weekLabel(null, "2026-11-08"), "Unknown week");
  assert.equal(weekLabel("not a date", "2026-11-08"), "Unknown week");
});

test("every figure the server counts is shown once, in order, with its definition", () => {
  const summary = { new_businesses: 1, live_businesses: 12, calls: 1234, missed_calls: 3, texts_sent: 2, texts_received: 1,
    open_alerts: 4, urgent_alerts: 1, tickets_opened: 2, tickets_open: 5, failed_automations: 0 };
  const rows = figureRows(summary);
  assert.deepEqual(rows.map((r) => r.key), FIGURES.map(([k]) => k));
  assert.equal(rows.find((r) => r.key === "calls").value, "1,234");
  assert.equal(rows.find((r) => r.key === "open_alerts").value, "4 (1 urgent)");
  assert.equal(rows.find((r) => r.key === "tickets_opened").value, "2 (5 open when the report was made)");
  assert.equal(rows.find((r) => r.key === "failed_automations").value, "0", "zero is a count, not missing");
  for (const r of rows) assert.ok(r.definition.length > 10, `${r.key} has a definition`);
});

test("a figure the server didn't send says so instead of showing zero", () => {
  const rows = figureRows({ calls: 5 });
  assert.equal(rows.find((r) => r.key === "missed_calls").value, "Not counted");
  assert.equal(rows.find((r) => r.key === "open_alerts").value, "Not counted");
  assert.equal(figureRows(null).length, FIGURES.length);
});

test("the schedule says whether the weekly job runs and whether email is live", () => {
  const off = Object.fromEntries(scheduleFacts({ job_found: true, job_on: false, email_live: false }, when));
  assert.match(off.Runs, /switched off/);
  assert.match(off["By email"], /once email is live/);
  const missing = Object.fromEntries(scheduleFacts({ job_found: false, job_on: false }, when));
  assert.match(missing.Runs, /isn't set up/);
  const on = Object.fromEntries(scheduleFacts({ job_found: true, job_on: true, next_run_at: "2026-11-23T08:00:00Z", email_live: true }, when));
  assert.equal(on.Runs, "Mondays at 08:00 UTC, for the week before. Next run at 2026-11-23T08:00:00Z.");
  assert.match(on["By email"], /goes in the admin email digest/);
  assert.match(on["In the app"], /Weekly platform report permission/);
});

test("a refusal is explained; other errors pass through", () => {
  assert.match(reportError("NOT_ALLOWED"), /Weekly platform report permission/);
  assert.equal(reportError("network down"), "network down");
});

test("no dash or hyphen in anything a person reads", () => {
  const text = [...FIGURES.flat(), ...scheduleFacts({ job_found: true }, when).flat(), ...scheduleFacts({ job_on: true, email_live: true }, when).flat(),
    reportError("NOT_ALLOWED"), weekLabel("2026-11-02", "2026-11-08")].join(" ");
  assert.doesNotMatch(text, /[-‐-―]/);
});

test("an empty server answer is a plain load error, and a missing list is no report yet (S62)", async () => {
  const { readWeeklyReports } = await import("./weeklyReport.js");
  for (const bad of [null, undefined, "", [], 0]) assert.equal(readWeeklyReports(bad), null);
  assert.deepEqual(readWeeklyReports({}), { schedule: {}, reports: [] });
  assert.deepEqual(readWeeklyReports({ reports: null, schedule: null }), { schedule: {}, reports: [] });
  const r = readWeeklyReports({ schedule: { job_on: true }, reports: [{ id: 1 }, null, "x"] });
  assert.deepEqual(r.reports, [{ id: 1 }]);
  assert.equal(r.schedule.job_on, true);
});
