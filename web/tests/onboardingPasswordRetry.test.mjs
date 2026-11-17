import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

// Exercise the real submit handler, retaining React state between submissions.
const source = readFileSync(new URL("../src/onboarding/StartScreens.jsx", import.meta.url), "utf8");
const start = source.indexOf("  async function save(event)");
const handler = source.slice(start, source.indexOf("\n  return (", start));
function form({ saveFailures = 0, refreshFailures = 0 } = {}) {
  let saves = 0, refreshes = 0;
  const context = {
    password: "A-long-password9!", confirm: "A-long-password9!", passwordSaved: false,
    passwordProblems: () => [], friendlyAuthError: (err) => err.message, errorWords: (err) => err.message,
    setTried() {}, setError(value) { context.error = value; }, setBusy(value) { context.busy = value; },
    setPasswordSaved(value) { context.passwordSaved = value; },
    api: { async setPassword() { saves++; if (saves <= saveFailures) throw new Error("Save failed"); } },
    async onDone() { refreshes++; if (refreshes <= refreshFailures) throw new Error("Refresh failed"); },
  };
  return {
    context,
    submit: () => runInNewContext(`${handler}\nsave({ preventDefault() {} })`, context),
    counts: () => ({ saves, refreshes }),
  };
}

test("saved password survives repeated refresh failures; retry only refreshes", async () => {
  const f = form({ refreshFailures: 2 });
  await f.submit();
  assert.equal(f.context.passwordSaved, true);
  assert.equal(f.context.busy, false);
  assert.equal(f.context.error, "Your password is saved. Refresh failed");
  // Password input validity must not block retrying a completed save.
  f.context.password = "";
  f.context.confirm = "different";
  await f.submit();
  assert.equal(f.context.passwordSaved, true);
  await f.submit();
  assert.deepEqual(f.counts(), { saves: 1, refreshes: 3 });
  assert.equal(f.context.passwordSaved, false);
});

test("failed password save can be retried and never refreshes prematurely", async () => {
  const f = form({ saveFailures: 1 });
  await f.submit();
  assert.equal(f.context.passwordSaved, false);
  assert.equal(f.context.error, "Save failed");
  assert.equal(f.context.busy, false);
  assert.deepEqual(f.counts(), { saves: 1, refreshes: 0 });
  await f.submit();
  assert.deepEqual(f.counts(), { saves: 2, refreshes: 1 });
  assert.equal(f.context.passwordSaved, false);
});

test("initial password validation still prevents writes", async () => {
  const f = form();
  f.context.confirm = "different";
  await f.submit();
  assert.deepEqual(f.counts(), { saves: 0, refreshes: 0 });
  assert.equal(f.context.error, "The two passwords don't match.");
});
