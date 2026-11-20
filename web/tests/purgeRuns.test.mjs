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

test("a stopped file removal is offered again to the person who ran it or an approver, while purges are on", () => {
  const stopped = run({ status: "failed", executed_at: "2026-11-20T10:00:00Z", executed_by: "e", owner_approved_by: "o", second_approved_by: "s", files_left: 2 });
  for (const you of ["e", "o", "s"]) assert.equal(runActions(stopped, { you, owner: false, manage: true, purgeEnabled: true }).retry, true);
  assert.equal(runActions({ ...stopped, status: "files_pending" }, { you: "e", owner: false, manage: true, purgeEnabled: true }).retry, true);
  assert.equal(runActions(stopped, { you: "x", owner: true, manage: true, purgeEnabled: true }).retry, false);
  assert.equal(runActions(stopped, { you: "e", owner: false, manage: true, purgeEnabled: false }).retry, false);
  assert.equal(runActions({ ...stopped, files_left: 0 }, { you: "e", owner: false, manage: true, purgeEnabled: true }).retry, false);
  assert.equal(runActions({ ...stopped, executed_at: null }, { you: "e", owner: false, manage: true, purgeEnabled: true }).retry, false);
});

test("every state has words without dashes", () => {
  for (const [k, [w]] of Object.entries(RUN_STATUS)) assert.doesNotMatch(w, /[-–—]/, k);
});
