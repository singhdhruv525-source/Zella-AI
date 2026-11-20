// Scheduled job helpers (web/src/admin/jobState.js): real state beside intended state, and the "job off" note.
import { test } from "node:test";
import assert from "node:assert/strict";
import { allJobs, jobLabel, jobOffNote, jobState } from "../src/admin/jobState.js";

const health = {
  jobs: [
    { name: "zella_dispatch", active: false, intended: "off", intent_reason: "Deliberately off until go live", intent_matches: true },
    { name: "zella_jobs_daily", active: true, intended: "off", intent_reason: "Deliberately off until go live", intent_matches: false },
    { name: "zella_usage_thresholds", active: true, intended: null, intent_matches: null },
    { name: "zella_jobs_hourly", active: false, intended: null, intent_matches: null },
  ],
  intent_only: [{ name: "zella_jobs_every5", intended: "off", intent_reason: "Deliberately off until go live" }],
};

test("an off job recorded as off reads off on purpose, with its reason", () => {
  const s = jobState(health, "zella_dispatch");
  assert.deepEqual([s.on, s.label, s.intent, s.mismatch, s.tone], [false, "Off on purpose", "Deliberately off until go live", false, "neutral"]);
});

test("a job on against its recorded intent is a mismatch", () => {
  const s = jobState(health, "zella_jobs_daily");
  assert.equal(s.on, true); assert.equal(s.mismatch, true); assert.equal(s.tone, "warning");
});

test("a job with nothing recorded reads plain on or off", () => {
  assert.equal(jobState(health, "zella_usage_thresholds").label, "On");
  assert.equal(jobState(health, "zella_jobs_hourly").label, "Off");
  assert.equal(jobState(health, "zella_jobs_hourly").intent, null);
});

test("an intent for a job that doesn't exist reads not created, and is listed", () => {
  assert.equal(jobState(health, "zella_jobs_every5").label, "Not created");
  assert.equal(jobState(health, "zella_nothing").label, "Not created");
  assert.deepEqual(allJobs(health).map((j) => j.exists), [true, true, true, true, false]);
});

test("the note names the job in plain words, only while it is off", () => {
  assert.equal(jobOffNote(health, "zella_dispatch"), "Needs the Dispatcher job, which is off (deliberately off until go live).");
  assert.equal(jobOffNote(health, "zella_jobs_hourly"), "Needs the Hourly job, which is off.");
  assert.equal(jobOffNote(health, "zella_usage_thresholds"), null);
  assert.equal(jobOffNote(null, "zella_dispatch"), null, "unknown state is never reported as off");
});

test("labels have no dashes and fall back to plain words", () => {
  assert.equal(jobLabel("zella_new_job"), "new job");
  for (const name of ["zella_dispatch", "zella_jobs_every5", "zella_platform_emails"]) assert.doesNotMatch(jobLabel(name), /[-‐–—]/);
});
