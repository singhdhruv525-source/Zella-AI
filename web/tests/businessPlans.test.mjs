import { test } from "node:test";
import assert from "node:assert/strict";
import { allowanceText, balanceText, money, planFacts, priceText, tierText } from "../src/businessPlans.js";

const plan = { version: 3, versions: 3, tier: "pro", billingInterval: "yearly", priceCents: 39900, setupFeeCents: 5000, currency: "USD",
  minutes: 900, texts: 200, emails: 1200, teamSeats: 5, phoneNumbers: 1, locations: 1, languages: ["en", "es"], trialEnabled: false, overageCentsPerMinute: 12 };

test("a business plan in words, never Unknown plan", () => {
  assert.equal(tierText(plan), "Pro, version 3 of 3");
  assert.equal(tierText({ ...plan, versions: 1, version: 1, tier: "base" }), "Base, version 1");
  assert.equal(tierText(null), "No plan saved");
  assert.equal(priceText(plan), "$399.00 a year, plus $50.00 setup");
  assert.equal(priceText({ ...plan, billingInterval: "monthly", setupFeeCents: 0 }), "$399.00 a month");
  assert.equal(priceText(null), "No plan saved");
  assert.equal(allowanceText(plan), "900 minutes · 200 texts · 1,200 emails");
  assert.equal(money(undefined), "Not set");
});

test("the drawer lists every allowance", () => {
  const facts = Object.fromEntries(planFacts(plan));
  assert.equal(facts.Languages, "English, Spanish");
  assert.equal(facts["Extra minutes"], "$0.12 a minute");
  assert.equal(facts["Team seats (including the owner)"], "5");
  assert.deepEqual(planFacts(null), []);
  assert.deepEqual(balanceText({ resource: "minutes", kind: "rollover", granted: 100, remaining: 40 }), ["Minutes (rolled over)", "40 left of 100"]);
});
