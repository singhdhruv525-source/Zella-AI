// Release 2: the words and rules the scheduling screens use (src/schedulingLogic.js).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JOB_STATUS, RESOURCE_KINDS, arrivalText, checklistProgress, describePlan, nextSteps, scheduleError } from "../src/schedulingLogic.js";

const sql = readFileSync(new URL("../../sql/zella_scheduling.sql", import.meta.url), "utf8");
const listIn = (constraint) => [...sql.match(new RegExp(`constraint ${constraint} check \\(\\w+ in \\(([^)]*)\\)`))[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort();

test("resource kinds and job states match the database's allowed values", () => {
  assert.deepEqual(RESOURCE_KINDS.map(([k]) => k).sort(), listIn("resources_kind"));
  assert.deepEqual(RESOURCE_KINDS.map(([k]) => k).sort(), listIn("resource_needs_kind"));
  assert.deepEqual(Object.keys(JOB_STATUS).filter((k) => k !== "unassigned").sort(), listIn("job_dispatch_status"));
});

test("the buttons offer exactly the steps the server allows", () => {
  const body = sql.slice(sql.indexOf("function public.zella_dispatch_status"), sql.indexOf("raise exception 'BAD_STEP'"));
  for (const [from, steps] of Object.entries({ assigned: ["en_route", "on_site"], en_route: ["on_site", "assigned"], on_site: ["paused", "completed", "needs_return"], paused: ["on_site", "needs_return"] })) {
    assert.deepEqual(nextSteps(from).map(([to]) => to).sort(), [...steps].sort(), from);
    assert.match(body, new RegExp(`v_cur = '${from}' and p_to in \\(${steps.map((s) => `'${s}'`).join(", ")}\\)`), `server step list for ${from}`);
  }
  assert.deepEqual(nextSteps("completed"), []);
  assert.deepEqual(nextSteps("needs_return"), []);
});

test("arrival windows and checklist progress read plainly", () => {
  const start = "2026-11-09T15:00:00Z";
  assert.equal(arrivalText(start, 120, "America/Chicago"), "Arrive 9:00 AM - 11:00 AM");
  assert.equal(arrivalText(start, null, "America/Chicago"), "9:00 AM");
  assert.equal(arrivalText(null, 60, "UTC"), "");
  assert.deepEqual(checklistProgress([{ label: "a", done: true }, { label: "b", required: true }]), { done: 1, total: 2, missing: 1, text: "1 of 2 done · 1 required left" });
  assert.equal(checklistProgress(null).text, "");
});

test("plans are described the way people say them", () => {
  assert.equal(describePlan({ frequency: "weekly", interval_count: 2, weekday: 2, start_at: "09:00:00" }), "Every 2 weeks on Tuesday at 9:00 AM");
  assert.equal(describePlan({ frequency: "weekly", interval_count: 1, weekday: 0, start_at: "13:30" }), "Every week on Sunday at 1:30 PM");
  assert.equal(describePlan({ frequency: "monthly", interval_count: 3, month_day: 15, start_at: "00:05" }), "Every 3 months on the 15th at 12:05 AM");
  assert.equal(describePlan({ frequency: "monthly", interval_count: 1, month_day: 1 }), "Monthly on the 1st");
  assert.equal(describePlan({ frequency: "monthly", interval_count: 1, month_day: 22 }), "Monthly on the 22nd");
  assert.equal(describePlan({ frequency: "monthly", interval_count: 1, month_day: 11 }), "Monthly on the 11th");
});

test("refusals are explained in plain words", () => {
  assert.match(scheduleError({ message: "SLOT_TAKEN", details: "Chair 1 is booked, full or blocked then" }), /^Chair 1 is booked, full or blocked then/);
  assert.match(scheduleError({ message: "SLOT_TAKEN", details: "someone on this crew is on another job then" }), /crew/);
  assert.match(scheduleError({ message: "SLOT_TAKEN", details: "no free room, chair or other resource this service needs then" }), /resource this service needs/);
  assert.match(scheduleError({ message: "SLOT_TAKEN" }), /already booked/);
  for (const [code, want] of [["CHANGED", /changed while you were looking/], ["BAD_STEP", /doesn't follow/], ["CHECKLIST_INCOMPLETE", /required checklist/],
    ["NOT_ASSIGNED", /Assign the job/], ["TENANT_MISMATCH: x", /isn't part of this business/], ["duplicate key value violates unique constraint \"resources_one_name\"", /already a resource/],
    ["NOT_ALLOWED", /permission/], ["Could not find the function public.zella_dispatch_board", /isn't available/]]) {
    assert.match(scheduleError({ message: code }), want, code);
  }
  assert.doesNotMatch(scheduleError({ message: "NOT_CHANGED" }), /changed while you were looking/);
  // each duplicate names the rule that failed, and an unknown duplicate is not blamed on resource names
  assert.match(scheduleError({ message: 'duplicate key value violates unique constraint "resource_needs_one"', code: "23505" }), /listed once/);
  assert.match(scheduleError({ message: 'duplicate key value violates unique constraint "resources_one_name"', code: "23505" }), /already a resource/);
  assert.doesNotMatch(scheduleError({ message: 'duplicate key value violates unique constraint "something_else"', code: "23505" }), /resource with that name/);
  assert.match(scheduleError({ message: "something odd" }), /didn't work/);
});

test("a block on a resource doesn't close the business; a person's block covers only them", async () => {
  const { blockCovers, blocksEveryone } = await import("../src/schedulingLogic.js");
  const holiday = { staff_id: null, resource_id: null }, bay = { staff_id: null, resource_id: "r1" }, ana = { staff_id: "s1", resource_id: null };
  assert.equal(blocksEveryone(holiday), true);
  assert.equal(blocksEveryone(bay), false);
  assert.equal(blocksEveryone(ana), false);
  assert.equal(blockCovers(holiday, "s1"), true);
  assert.equal(blockCovers(bay, "s1"), false);
  assert.equal(blockCovers(ana, "s1"), true);
  assert.equal(blockCovers(ana, "s2"), false);
  assert.equal(blockCovers(ana, null), false);
});
