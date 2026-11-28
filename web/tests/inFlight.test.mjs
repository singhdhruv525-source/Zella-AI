// Per item requests in flight (src/crm/inFlight.js), used by "Send again" (Sending failed) and each run's "Try again"
// (automation runs): a second click on a pending item sends nothing, other items still can, and each item is cleared
// when its own request ends, even when it fails.
//   cd web && node --test tests/inFlight.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { inFlight } from "../src/crm/inFlight.js";

const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };

test("a second start for a pending item is ignored; other items run", async () => {
  let changes = 0;
  const f = inFlight(() => changes++);
  const a = deferred(), b = deferred();
  let calls = 0;
  const first = f.run("a", () => { calls++; return a.promise; });
  assert.equal(f.has("a"), true);
  assert.deepEqual(await f.run("a", () => { calls++; }), { skipped: true });
  const other = f.run("b", () => { calls++; return b.promise; });
  assert.equal(calls, 2);
  assert.deepEqual([...f.ids()].sort(), ["a", "b"]);
  // b ends first: only b is cleared
  b.resolve("done b");
  assert.deepEqual(await other, { value: "done b" });
  assert.equal(f.has("b"), false);
  assert.equal(f.has("a"), true);
  a.resolve("done a");
  assert.deepEqual(await first, { value: "done a" });
  assert.equal(f.has("a"), false);
  assert.equal(changes, 4);
});

test("a failed request still clears its item, and the item can start again", async () => {
  const f = inFlight();
  await assert.rejects(f.run("x", async () => { throw new Error("network"); }), /network/);
  assert.equal(f.has("x"), false);
  assert.deepEqual(await f.run("x", async () => 1), { value: 1 });
});
