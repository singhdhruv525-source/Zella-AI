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

test("module slugs read as their real names on the Industry profile (C45)", async () => {
  const { moduleName } = await import("../src/industryModules.js");
  assert.equal(moduleName("ai-receptionist"), "AI receptionist");
  assert.deepEqual(["ai-receptionist", "automations", "calendar", "calls"].map(moduleName), ["AI receptionist", "Automations", "Calendar", "Calls"]);
  assert.equal(moduleName("sms"), "Text messages");
  assert.equal(moduleName("ai-follow-up"), "AI follow up");
  assert.equal(moduleName("ai-new_thing"), "AI new thing");   // unknown slugs: words, AI in capitals, no hyphens
  assert.equal(moduleName(""), "");
  assert.equal(moduleName(null), "");
  assert.equal(moduleName("constructor"), "Constructor");   // never the inherited Object constructor
  assert.equal(moduleName("toString"), "Tostring");
});

test("an empty or broken industries answer is a load failure, not a code error (A41)", async () => {
  const { readIndustriesAnswer } = await import("../src/industryModules.js");
  for (const bad of [undefined, null, "", {}, { industries: null }, { industries: "x" }]) assert.equal(readIndustriesAnswer(bad), null);
  assert.deepEqual(readIndustriesAnswer({ industries: [] }), { industries: [], industryData: false });
  const r = readIndustriesAnswer({ industries: [{ id: "a", name: "Dental", modules: [{ id: "m" }] }, { id: "b", name: "Spa" }, null, { name: "no id" }], industryData: true });
  assert.deepEqual(r.industries.map((i) => i.id), ["a", "b"]);
  assert.deepEqual(r.industries[1].modules, []);
  assert.equal(r.industryData, true);
});

test("industry rows without a string name, and module entries that aren't objects, are left out (A41)", async () => {
  const { readIndustriesAnswer } = await import("../src/industryModules.js");
  const r = readIndustriesAnswer({ industries: [
    { id: "a", name: "Dental", modules: [{ id: "m1", name: "Calls" }, null, "calls", 7, ["x"], { id: "m2", name: "Email" }] },
    { id: "b" }, { id: "c", name: null }, { id: "d", name: 42 }, ["e"], { id: "f", name: "" },
  ] });
  assert.deepEqual(r.industries.map((i) => i.id), ["a", "f"]);
  assert.deepEqual(r.industries[0].modules.map((m) => m.id), ["m1", "m2"]);
  assert.deepEqual(r.industries[1].modules, []);
  assert.deepEqual(readIndustriesAnswer({ industries: [] }).industries, []);   // no industries yet is still valid
});
