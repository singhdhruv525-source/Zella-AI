// Batch 2 unit tests: the shared load / metric states behind the admin pages.
//   cd web && node --test tests/batch2_unit.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { countOf, emptyText, isCount, loadStatus, metric } from "../src/admin/loadStatus.js";

const r = (status) => ({ status });

test("load status: loading, failed, ok, stale", () => {
  assert.equal(loadStatus({ data: null, error: "", loading: true }), "loading");
  assert.equal(loadStatus({ data: null, error: "boom", loading: false }), "failed");
  assert.equal(loadStatus({ data: null, error: "boom", loading: true }), "failed", "retrying after a failure still has nothing to show");
  assert.equal(loadStatus({ data: { a: 1 }, error: "", loading: false }), "ok");
  assert.equal(loadStatus({ data: { a: 1 }, error: "boom", loading: false }), "stale");
  assert.equal(loadStatus({ data: { a: 1 }, error: "", loading: true }), "ok", "a refresh in progress keeps the data");
});

test("metric: valid zero is 0, missing is never 0", () => {
  assert.equal(metric(0, r("ok")), 0);
  assert.equal(metric(7, r("ok")), 7);
  assert.equal(metric(7, r("stale")), 7, "stale data still shows its number (with the warning)");
  for (const v of [undefined, null, "3", NaN, Infinity, {}]) assert.equal(metric(v, r("ok")), "—", String(v));
  assert.equal(metric(0, r("failed")), "—", "nothing loaded: no number at all");
  assert.equal(metric(5, r("loading")), "…");
  assert.equal(isCount(0), true); assert.equal(isCount(null), false);
});

test("countOf: only when the list is really there", () => {
  assert.equal(countOf([], null), 0);
  assert.equal(countOf([1, 2, 3], (x) => x > 1), 2);
  assert.equal(countOf(undefined), null);
  assert.equal(countOf({ length: 3 }), null);
});

test("emptyText: 'nothing here' only after a successful load", () => {
  assert.equal(emptyText(r("ok"), "No modules configured yet."), "No modules configured yet.");
  assert.equal(emptyText(r("stale"), "No modules."), "No modules.");
  assert.equal(emptyText(r("loading"), "x"), "Loading...");
  assert.match(emptyText(r("failed"), "No modules configured yet.", "the module catalog"), /^Not available: the module catalog couldn't be loaded/);
});
