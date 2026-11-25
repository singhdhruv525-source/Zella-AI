// BIZ-17: the Activity tab shows what each audit row changed.
import test from "node:test";
import assert from "node:assert/strict";
import { changeLines, changeRows } from "../src/business/changes.js";

test("only changed fields, before and after, in words", () => {
  assert.deepEqual(changeLines({ is_active: true, suspended_at: null, onboarding_status: "active" }, { is_active: false, suspended_at: "2026-11-16", onboarding_status: "active", reason: "Payment" }),
    ["Is active: true → false", "Suspended at: not set → 2026-11-16", "Reason: Payment"]);
  assert.deepEqual(changeLines(null, { size: "large" }), ["Size: large"]);
  assert.deepEqual(changeLines(null, null), []);
  assert.deepEqual(changeLines({ enabled: ["a"] }, { enabled: ["a", "b"] }), ["Enabled: a → a, b"]);
  assert.equal(changeLines({}, { note: "x".repeat(100) })[0].length < 80, true);
  assert.equal(changeLines({}, { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6 }).length, 5);
});

// Audit logs (owner approved 25 Nov 2026): the opened row lists every change in words, raw record one click away.
test("changeRows lists every changed field with before and after", () => {
  const rows = changeRows({ is_active: true, suspended_at: null, onboarding_status: "active" }, { is_active: false, suspended_at: "2026-11-16", onboarding_status: "active" });
  assert.deepEqual(rows.map((r) => [r.label, r.before, r.after, r.hadBefore]), [["Is active", "true", "false", true], ["Suspended at", "not set", "2026-11-16", true]]);
  assert.equal(changeRows({}, Object.fromEntries([..."abcdefg"].map((k, i) => [k, i]))).length, 7);
  assert.deepEqual(changeRows(null, { status: "sent" }).map((r) => [r.label, r.after, r.hadBefore]), [["Status", "sent", false]]);
  assert.deepEqual(changeRows(["x"], "text"), []);
  assert.deepEqual(changeRows({ a: 1 }, { a: 1 }), []);
  // a single record lists its null fields too; with both records an unchanged null stays out
  assert.deepEqual(changeRows(null, { suspended_at: null }).map((r) => [r.label, r.after]), [["Suspended at", "not set"]]);
  assert.deepEqual(changeRows({ suspended_at: null }, null).map((r) => [r.label, r.before]), [["Suspended at", "not set"]]);
  assert.deepEqual(changeRows({ suspended_at: null, a: 1 }, { suspended_at: null, a: 2 }).map((r) => r.key), ["a"]);
});
