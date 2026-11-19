import { test } from "node:test";
import assert from "node:assert/strict";
import { businessWord, modulesLosingUsers, switchesOff } from "../src/industryModules.js";

const saved = [
  { id: "cal", name: "Calendar", is_active: true },
  { id: "sms", name: "Text messages", is_active: true },
  { id: "old", name: "Old", is_active: false },
];
const draft = (changes) => saved.map((m) => ({ id: m.id, name: m.name, isActive: changes[m.id] ?? m.is_active }));

test("only modules switched off now that businesses have on need a confirmation", () => {
  const usage = { cal: 12, sms: 0, old: 3 };
  assert.deepEqual(modulesLosingUsers(saved, draft({ cal: false, sms: false }), usage), [{ id: "cal", name: "Calendar", businesses: 12 }]);
  assert.deepEqual(modulesLosingUsers(saved, draft({}), usage), []);
  assert.deepEqual(modulesLosingUsers(saved, draft({ old: false }), usage), []);   // already off
  assert.deepEqual(modulesLosingUsers(saved, [...draft({}), { name: "New", isActive: false }], usage), []);   // new module
});

test("the saved name is shown even while the draft renames it", () => {
  const d = draft({ cal: false }); d[0].name = "Bookings";
  assert.equal(modulesLosingUsers(saved, d, { cal: 1 })[0].name, "Calendar");
});

test("switchesOff spots any offered module being switched off, used or not", () => {
  assert.equal(switchesOff(saved, draft({ sms: false })), true);
  assert.equal(switchesOff(saved, draft({ old: true })), false);
  assert.equal(switchesOff(saved, draft({})), false);
});

test("business counts read in words", () => {
  assert.equal(businessWord(1), "1 business");
  assert.equal(businessWord(1101), "1,101 businesses");
});
