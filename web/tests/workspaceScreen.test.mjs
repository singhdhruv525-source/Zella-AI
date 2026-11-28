// The CRM's first screen (src/crm/workspaceScreen.js): Loading while a read or a retry is pending, the error screen
// with Try again after a failed read or an answer without a list, and "No workspace yet" only after a read that
// worked and found none.
//   cd web && node --test tests/workspaceScreen.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { workspaceList, workspaceScreen } from "../src/crm/workspaceScreen.js";

test("pending reads and retries show Loading, never the empty state", () => {
  assert.equal(workspaceScreen({ workspaces: null, failed: false }), "loading");
  assert.equal(workspaceScreen({ workspaces: undefined, failed: false }), "loading");
});

test("a failed read is an error, whatever list is held", () => {
  assert.equal(workspaceScreen({ workspaces: [], failed: true }), "error");
  assert.equal(workspaceScreen({ workspaces: null, failed: true }), "error");
});

test("empty only after a read that worked", () => {
  assert.equal(workspaceScreen({ workspaces: [], failed: false }), "empty");
  assert.equal(workspaceScreen({ workspaces: [{ id: "a" }], failed: false }), "app");
});

test("an answer without a list counts as a failed read", () => {
  assert.equal(workspaceList(null), null);
  assert.equal(workspaceList({ rows: [] }), null);
  assert.deepEqual(workspaceList([]), []);
  assert.deepEqual(workspaceList([{ id: "a" }]), [{ id: "a" }]);
});
