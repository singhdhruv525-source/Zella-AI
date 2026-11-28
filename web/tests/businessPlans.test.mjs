import { test } from "node:test";
import assert from "node:assert/strict";
import { allowanceText, balanceText, money, planFacts, planFromGet, priceText, tierShort, tierText } from "../src/businessPlans.js";

const plan = { version: 3, versions: 3, tier: "pro", billingInterval: "yearly", priceCents: 39900, setupFeeCents: 5000, currency: "USD",
  minutes: 900, texts: 200, emails: 1200, teamSeats: 5, phoneNumbers: 1, locations: 1, languages: ["en", "es"], trialEnabled: false, overageCentsPerMinute: 12 };

test("a business plan in words, never Unknown plan", () => {
  assert.equal(tierText(plan), "Pro, version 3 of 3");
  assert.equal(tierText({ ...plan, versions: 1, version: 1, tier: "base" }), "Base, version 1");
  assert.equal(tierText(null), "No plan saved");
  assert.equal(tierShort(plan), "Pro v3");
  assert.equal(tierShort({ ...plan, tier: "base", version: 1 }), "Base v1");
  assert.equal(tierShort(null), "");
  assert.equal(priceText(plan), "$399.00 a year, plus $50.00 setup");
  assert.equal(priceText({ ...plan, billingInterval: "monthly", setupFeeCents: 0 }), "$399.00 a month");
  assert.equal(priceText(null), "No plan saved");
  assert.equal(allowanceText(plan), "900 minutes, 200 texts, 1,200 emails");
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

test("the drawer's plan comes from the plan it just read, not the list's older copy", () => {
  const listPlan = { version: 3, tier: "base", priceCents: 4900, currency: "USD" };
  const read = { version: 4, tier: "pro", billing_interval: "monthly", price_cents: 9900, setup_fee_cents: 0, minutes: 500, texts: 300, emails: 1000,
    team_seats: 5, phone_numbers: 1, locations: 1, languages: ["en"], trial_enabled: false, overage_cents_per_minute: 12 };
  const p = planFromGet(read, 4, listPlan);
  assert.equal(p.version, 4);
  assert.equal(priceText(p), "$99.00 a month");
  assert.equal(planFacts(p)[0][1], "Pro, version 4 of 4");
  assert.equal(planFromGet(null, 0, listPlan), null);
});
