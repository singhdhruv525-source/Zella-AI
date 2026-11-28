// The CRM's first screen (src/crm/workspaceScreen.js): Loading while a read or a retry is pending, the error screen
// with Try again after a failed read or an answer without a list, and "No workspace yet" only after a read that
// worked and found none.
//   cd web && node --test tests/workspaceScreen.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { latestOnly, workspaceList, workspaceScreen } from "../src/crm/workspaceScreen.js";

test("only the latest read may write: an older answer that arrives late is dropped", async () => {
  const reads = latestOnly();
  const writes = [];
  const read = async (answer, delay) => {
    const n = reads.start();
    await new Promise((r) => setTimeout(r, delay));
    if (reads.isCurrent(n)) writes.push(answer);
  };
  // the first read fails late while the retry succeeds first: the late failure never shows
  await Promise.all([read("failed", 30), read("list", 5)]);
  assert.deepEqual(writes, ["list"]);
  const n = reads.start();
  assert.equal(reads.isCurrent(n), true);
  reads.start();
  assert.equal(reads.isCurrent(n), false);
});

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
