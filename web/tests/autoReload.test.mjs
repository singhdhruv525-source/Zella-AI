import { test } from "node:test";
import assert from "node:assert/strict";
import { autoReloadChoices } from "../src/settings/autoReload.js";

const packs = [
  { code: "minutes_100", resource: "minutes", quantity: 100, price_cents: 2900 },
  { code: "texts_500", resource: "texts", quantity: 500, price_cents: 1800 },
];

test("each resource gets only its own packs and its saved choice", () => {
  const o = { packs, auto_reload: [{ resource: "texts", enabled: true, pack: "texts_500" }] };
  assert.deepEqual(autoReloadChoices(o, "minutes").packs.map((p) => p.code), ["minutes_100"]);
  assert.equal(autoReloadChoices(o, "minutes").current, null);
  assert.equal(autoReloadChoices(o, "texts").current.pack, "texts_500");
});

test("a missing, empty or broken packs list gives no packs instead of a crash", () => {
  for (const o of [{}, { packs: null }, { packs: [] }, { packs: "x" }, { packs: [null, 3] }, null, undefined]) {
    const c = autoReloadChoices(o, "emails");
    assert.deepEqual(c.packs, []);
    assert.equal(c.current, null);
  }
});

test("a resource with no packs on offer has none to choose, while others still do", () => {
  const c = autoReloadChoices({ packs, auto_reload: null }, "emails");
  assert.deepEqual(c.packs, []);
  assert.equal(autoReloadChoices({ packs }, "minutes").packs.length, 1);
});
