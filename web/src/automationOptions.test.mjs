import { test } from "node:test";
import assert from "node:assert/strict";
import { hoursList } from "./automationOptions.js";

// Live data (2026-11-04): appointment_confirmation keeps hours_before as a number, appointment_reminder as a list.
// The automations screens called .map on the number and the page crashed.
test("reminder times accept a list or a single number", () => {
  assert.deepEqual(hoursList([2, 24]), [2, 24]);
  assert.deepEqual(hoursList(24), [24]);
  assert.deepEqual(hoursList("48"), [48]);
});
test("missing or broken values fall back to one day", () => {
  for (const v of [undefined, null, "", [], ["x"], {}, -3]) assert.deepEqual(hoursList(v), [24]);
});
