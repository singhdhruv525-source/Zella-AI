import { test } from "node:test";
import assert from "node:assert/strict";
import { duplicateCheck, duplicateState, matchedWords, newCreationKey } from "../src/businessDuplicates.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

test("a creation key is a uuid, and a new one each time", () => {
  const a = newCreationKey(), b = newCreationKey();
  assert.match(a, UUID);
  assert.notEqual(a, b);
});

test("without randomUUID the key is still a version 4 uuid", () => {
  const fake = { getRandomValues: (arr) => arr.fill(255) };
  assert.match(newCreationKey(fake), UUID);
});

test("the matches are named in a fixed order, and unknown kinds are left out", () => {
  assert.equal(matchedWords(["phone"]), "Same phone number");
  assert.equal(matchedWords(["website", "name"]), "Same name and website");
  assert.equal(matchedWords(["website", "phone", "name", "other"]), "Same name, phone number and website");
  assert.equal(matchedWords([]), "");
  assert.equal(matchedWords(undefined), "");
});

test("a duplicate's state reads Live, its setup stage, or Draft in setup", () => {
  assert.equal(duplicateState({ isActive: true, onboardingStatus: "active" }), "Live");
  assert.equal(duplicateState({ isActive: false, onboardingStatus: "testing" }), "Testing");
  assert.equal(duplicateState({ isActive: false, onboardingStatus: "owner_setup" }), "Draft in setup");
});

test("the duplicate check: only a checked list counts; anything else is unchecked, never no duplicates", () => {
  assert.equal(duplicateCheck({ checked: true, duplicates: [] }), "none");
  assert.deepEqual(duplicateCheck({ checked: true, duplicates: [{ id: "a" }] }), [{ id: "a" }]);
  for (const found of [{ duplicates: [] }, { checked: false, duplicates: [] }, { checked: true }, { checked: true, duplicates: "x" }, null, undefined])
    assert.equal(duplicateCheck(found), "unchecked", JSON.stringify(found));
});
