import { test } from "node:test";
import assert from "node:assert/strict";
import { RUN_STATUS, runActions } from "../src/settings/panels/purgeRuns.js";

const run = (o = {}) => ({ status: "requested", owner_approved_by: null, second_approved_by: null, ...o });

test("nobody approves twice, and two approvals need an owner", () => {
  assert.equal(runActions(run(), { you: "a", owner: false, manage: true }).approve, true);
  assert.equal(runActions(run({ second_approved_by: "a" }), { you: "a", owner: false, manage: true }).approve, false);
  assert.equal(runActions(run({ second_approved_by: "a" }), { you: "b", owner: false, manage: true }).approve, false);
  assert.equal(runActions(run({ second_approved_by: "a" }), { you: "b", owner: true, manage: true }).approve, true);
  assert.equal(runActions(run(), { you: "b", owner: true, manage: false }).approve, false);
});

test("only an approver may run it, only once approved and only while purges are on", () => {
  const ok = run({ status: "approved", owner_approved_by: "o", second_approved_by: "s" });
  assert.equal(runActions(ok, { you: "o", owner: true, manage: true, purgeEnabled: true }).run, true);
  assert.equal(runActions(ok, { you: "o", owner: true, manage: true, purgeEnabled: false }).run, false);
  assert.equal(runActions(ok, { you: "x", owner: true, manage: true, purgeEnabled: true }).run, false);
  assert.equal(runActions({ ...ok, status: "done" }, { you: "o", owner: true, manage: true, purgeEnabled: true }).run, false);
  assert.equal(runActions({ ...ok, status: "done" }, { you: "o", owner: true, manage: true }).cancel, false);
});

test("every state has words without dashes", () => {
  for (const [k, [w]] of Object.entries(RUN_STATUS)) assert.doesNotMatch(w, /[-–—]/, k);
});
