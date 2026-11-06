// Release 1 unit tests: People & consent words and rules (web/src/peopleLogic.js).
//   cd web && node --test tests/release1_unit.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { CONSENT_KINDS, KINDS, PERMISSIONS, consentGivers, peopleError, personLabel, suggestedKinds } from "../src/peopleLogic.js";

test("kinds, permissions and consent kinds match the database's allowed values", () => {
  assert.deepEqual(KINDS.map(([k]) => k).sort(), ["authorized_contact", "emergency_contact", "guardian", "household", "other", "owner", "parent", "proxy", "representative", "tenant", "vendor"]);
  assert.deepEqual(PERMISSIONS.map(([k]) => k).sort(), ["approve", "book", "discuss", "documents", "pickup", "receive_updates"]);
  assert.deepEqual(CONSENT_KINDS.map(([k]) => k).sort(), ["data_sharing", "emergency_care", "medication", "other", "photo_media", "pickup_change", "recording", "terms", "treatment"]);
});

test("suggested kinds put the likely ones first and keep every kind", () => {
  for (const [typeKey, first] of [["children", "parent"], ["pets", "owner"], ["units", "tenant"], ["policies", "authorized_contact"], [undefined, "household"]]) {
    const list = suggestedKinds({ typeKey });
    assert.equal(list[0][0], first, String(typeKey));
    assert.equal(new Set(list.map(([k]) => k)).size, KINDS.length, "no duplicates, none missing");
  }
});

test("consent givers: self, primary contact and verified approvers only", () => {
  const panel = { primary_contact: { id: "p", first_name: "Pat" }, relationships: [
    { state: "active", kind: "guardian", permissions: ["approve"], person: { id: "g", first_name: "Gail" } },
    { state: "unverified", kind: "guardian", permissions: ["approve"], person: { id: "u", first_name: "Una" } },
    { state: "active", kind: "household", permissions: ["pickup"], person: { id: "h", first_name: "Hal" } },
    { state: "expired", kind: "parent", permissions: ["approve"], person: { id: "e", first_name: "Eve" } },
  ] };
  assert.deepEqual(consentGivers(panel, { recordId: "r" }).map((g) => g.id), ["p", "g"]);
  assert.deepEqual(consentGivers({ relationships: [] }, { customer: { id: "s", first_name: "Sam" } }).map((g) => g.id), ["s"]);
});

test("errors are explained without database wording", () => {
  for (const [message, want] of [["NOT_AUTHORIZED_GIVER", /can't give consent/], ["SAME_PERSON", /themselves/], ["BAD_DATE", /past/],
    ['duplicate key value violates unique constraint "customer_relationships_one_active_record"', /already has an active link/],
    ["NOT_ALLOWED", /permission/], ["NOT_VALID", /isn't part of this business/], ["Could not find the function public.zella_people_panel", /isn't available/],
    ["TypeError: Failed to fetch", /Couldn't reach Zella/], ["weird internal thing", /didn't work/]]) {
    const text = peopleError({ message });
    assert.match(text, want, message);
    assert.doesNotMatch(text, /constraint|zella_|duplicate key/, message);
  }
  assert.equal(personLabel({ first_name: "A", last_name: "B" }), "A B");
  assert.equal(personLabel({ phone: "+1" }), "+1");
});
