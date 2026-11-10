import { test } from "node:test";
import assert from "node:assert/strict";
import { templatesForBusiness } from "./templatePrecedence.js";

// A person who belongs to businesses A and B; both override the same key.
const rows = [
  { id: "g", business_id: null, industry_id: null, key: "booking_confirmed", channel: "sms", status: "active", version: 1 },
  { id: "gi", business_id: null, industry_id: "salon", key: "booking_confirmed", channel: "sms", status: "active", version: 1 },
  { id: "gx", business_id: null, industry_id: "clinic", key: "booking_confirmed", channel: "sms", status: "active", version: 1 },
  { id: "a", business_id: "A", industry_id: null, key: "booking_confirmed", channel: "sms", status: "active", version: 1 },
  { id: "b", business_id: "B", industry_id: null, key: "booking_confirmed", channel: "sms", status: "active", version: 1 },
  { id: "g2", business_id: null, industry_id: null, key: "reminder", channel: "sms", status: "active", version: 1 },
];

test("only the viewed business's own templates are listed as Yours", () => {
  const list = templatesForBusiness(rows, "A", "salon");
  assert.deepEqual(list.filter((t) => t.source === "Yours").map((t) => t.id), ["a"]);
  assert.ok(!list.some((t) => t.id === "b"), "business B's template must not appear in A");
  assert.ok(!list.some((t) => t.id === "gx"), "another industry's template must not appear");
});

test("the business's own version is the one in use; Zella's stays listed but not in use", () => {
  const list = templatesForBusiness(rows, "A", "salon");
  assert.deepEqual(list.filter((t) => t.inUse).map((t) => t.id).sort(), ["a", "g2"]);
});

test("without an override, the industry version beats the general one", () => {
  const list = templatesForBusiness(rows, "C", "salon");
  assert.equal(list.find((t) => t.inUse && t.key === "booking_confirmed").id, "gi");
});

test("an inactive own version doesn't hide Zella's active one", () => {
  const list = templatesForBusiness(rows.map((t) => (t.id === "a" ? { ...t, status: "draft" } : t)), "A", "salon");
  assert.equal(list.find((t) => t.inUse && t.key === "booking_confirmed").id, "gi");
});
