// Voice page helpers (web/src/admin/voiceView.js): tiles and alerts open filtered calls; switches in plain words.
import { test } from "node:test";
import assert from "node:assert/strict";
import { alertCallFilter, initialCallFilter, tileFilter, voiceSwitches } from "../src/admin/voiceView.js";

test("each tile opens the calls behind it for the same period", () => {
  assert.deepEqual(tileFilter("missed", 7), { status: "missed", days: 7 });
  assert.deepEqual(tileFilter("inbound", 30), { direction: "inbound", days: 30 });
  assert.deepEqual(tileFilter("failed", 1), { status: "failed", days: 1 });
  assert.equal(tileFilter("numbers", 30), null);
  assert.equal(tileFilter("completed", 45).days, 30, "a period the Calls tab doesn't offer falls back to 30 days");
});

test("the missed call alert opens that business's missed inbound calls for the last day", () => {
  const f = alertCallFilter({ kind: "missed_call_rate", business_id: "b1", filter: { status: "missed", direction: "inbound", days: 1, business_id: "b1" } });
  assert.deepEqual(f, { business: "b1", status: "missed", direction: "inbound", days: 1, failedOnly: false });
  assert.deepEqual(alertCallFilter({ kind: "high_failure_rate", business_id: "b2" }), { business: "b2", failedOnly: true });
  assert.deepEqual(alertCallFilter({ kind: "call_volume_spike" }), { business: null, failedOnly: false });
});

test("the Calls tab starts from status, direction, days and business", () => {
  const f = initialCallFilter({ status: "missed", direction: "inbound", days: 1, business: "b1" });
  assert.deepEqual([f.status, f.direction, f.days, f.business, f.failedOnly, f.offset], ["missed", "inbound", 1, "b1", false, 0]);
  assert.deepEqual([initialCallFilter(null).days, initialCallFilter(null).status], [30, null]);
});

test("switches read in plain words, the key only as help text, and never claim on when off", () => {
  const rows = voiceSwitches({ calls_live: false, enforcement_calls: false, vapi_auth_mode: "bearer",
    jobs: [{ name: "zella_jobs_every5", active: false, exists: true, intended: "off", runs: ["zella_sweep_stuck_calls"] }, { name: "zella_jobs_hourly", active: true, exists: true }, { name: "zella_jobs_every15", active: false, exists: false }] });
  const by = Object.fromEntries(rows.map((r) => [r.key, r]));
  assert.equal(by.calls_live.value, "Off");
  assert.equal(by.enforcement_calls.value, "Not enforced");
  assert.equal(by.vapi_auth_mode.value, "Shared token");
  assert.equal(by.zella_jobs_every5.value, "Off on purpose");
  assert.equal(by.zella_jobs_hourly.value, "On");
  assert.equal(by.zella_jobs_every15.value, "Not created");
  for (const r of rows) {
    assert.doesNotMatch(`${r.label} ${r.value}`, /_|[-‐–—]/, `${r.key} shows a key or a dash`);
    assert.match(r.hint, /Setting|Scheduled job/);
  }
  assert.equal(voiceSwitches(undefined), null);
});

import { callDetailsBare, callDetailsCollapsed, formatPhone, formatTimeZone } from "../src/admin/voiceView.js";

test("phone numbers read with spaces, never in E.164 or with dashes", () => {
  assert.equal(formatPhone("+15551230001"), "(555) 123 0001");
  assert.equal(formatPhone("5551230001"), "(555) 123 0001");
  assert.equal(formatPhone("+442071234567"), "+44 207 123 4567");
  assert.equal(formatPhone("Jane Doe"), "Jane Doe", "a caller's name stays a name");
  assert.equal(formatPhone(null), "");
  assert.doesNotMatch(formatPhone("+15551230001"), /-/);
});

test("time zones read as words", () => {
  assert.equal(formatTimeZone("America/New_York"), "Eastern Time (New York)");
  assert.equal(formatTimeZone("Not/A_Zone"), "A Zone");
  assert.equal(formatTimeZone(""), "");
});

test("the calls table collapses Number, Length and Outcome only when all three are unrecorded on every row", () => {
  const bare = { number: null, duration_seconds: null, outcome: null };
  assert.equal(callDetailsBare(bare), true);
  assert.equal(callDetailsBare({ ...bare, duration_seconds: 0 }), false, "a zero length is recorded");
  assert.equal(callDetailsCollapsed([bare, bare]), true);
  assert.equal(callDetailsCollapsed([bare, { ...bare, outcome: "booked" }]), false);
  assert.equal(callDetailsCollapsed([]), false);
});
