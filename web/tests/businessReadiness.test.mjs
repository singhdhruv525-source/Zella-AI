// BIZ-11: the server's readiness ladder as Overview rows.
import test from "node:test";
import assert from "node:assert/strict";
import { RUNG_LABELS, readinessRows } from "../src/business/readiness.js";

test("rows in ladder order with titles, state kept", () => {
  const out = readinessRows({ state: "setup_complete", checks: [
    { key: "live", rung: "live", ok: false, detail: "Not live yet" },
    { key: "owner", rung: "setup_complete", ok: true, detail: "Owner active or invited" },
    { key: "phone", rung: "integrations_verified", ok: false, detail: "No phone number assigned" },
  ] });
  assert.equal(out.state, "setup_complete");
  assert.deepEqual(out.rows.map((r) => [r.title, r.ok]), [["Owner", true], ["Phone number", false], ["Live", false]]);
  assert.ok(RUNG_LABELS[out.state]);
});

test("a missing or odd report gives no rows, never a crash", () => {
  assert.deepEqual(readinessRows(null), { state: "saved", rows: [] });
  assert.deepEqual(readinessRows({ checks: "x" }).rows, []);
  assert.equal(readinessRows({ checks: [{ key: "new_one", ok: "yes" }] }).rows[0].ok, false);
});

test("no row or rung label says None", () => {
  for (const v of Object.values(RUNG_LABELS)) assert.doesNotMatch(v, /\bNone\b/);
});
