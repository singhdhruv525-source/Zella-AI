// BIZ-17: the Activity tab shows what each audit row changed.
import test from "node:test";
import assert from "node:assert/strict";
import { changeLines } from "../src/business/changes.js";

test("only changed fields, before and after, in words", () => {
  assert.deepEqual(changeLines({ is_active: true, suspended_at: null, onboarding_status: "active" }, { is_active: false, suspended_at: "2026-11-16", onboarding_status: "active", reason: "Payment" }),
    ["Is active: true → false", "Suspended at: not set → 2026-11-16", "Reason: Payment"]);
  assert.deepEqual(changeLines(null, { size: "large" }), ["Size: large"]);
  assert.deepEqual(changeLines(null, null), []);
  assert.deepEqual(changeLines({ enabled: ["a"] }, { enabled: ["a", "b"] }), ["Enabled: a → a, b"]);
  assert.equal(changeLines({}, { note: "x".repeat(100) })[0].length < 80, true);
  assert.equal(changeLines({}, { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6 }).length, 5);
});
