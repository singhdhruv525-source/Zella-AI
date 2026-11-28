// Plan cards list every allowance in words, never a raw key such as "languages: 2" (UI-12).
import test from "node:test";
import assert from "node:assert/strict";
import { allowanceLabel, planAllowances, planFeatures } from "../src/copy/planAllowances.js";

const map = (rows) => Object.fromEntries(rows);

test("a plan with only a language limit still lists every allowance", () => {
  const rows = map(planAllowances({ languages: 2 }));
  assert.equal(rows["Languages the AI receptionist speaks"], "2");
  assert.equal(rows["AI voice minutes per period"], "No limit");
  assert.equal(rows["Texts per period"], "No limit");
  assert.equal(rows["Emails per period"], "No limit");
  assert.equal(rows["Team seats (including the owner)"], "No limit");
  assert.equal(rows["Phone numbers"], "No limit");
});

test("values read as words and numbers", () => {
  const rows = map(planAllowances({ voice_minutes: 1500, texts: "500", support_level: "priority", onboarding: "done_for_you" }));
  assert.equal(rows["AI voice minutes per period"], "1,500");
  assert.equal(rows["Texts per period"], "500");
  assert.equal(rows["Support level"], "Priority");
  assert.equal(rows["Onboarding service"], "Done for you");
  assert.ok(!("Reporting" in rows), "an unset level isn't listed");
});

test("texts and sms_messages are one line", () => {
  const a = planAllowances({ sms_messages: 300 }).filter(([l]) => l === "Texts per period");
  assert.deepEqual(a, [["Texts per period", "300"]]);
  const b = planAllowances({ texts: 100, sms_messages: 300 }).filter(([l]) => l === "Texts per period");
  assert.deepEqual(b, [["Texts per period", "100"]]);
});

test("an allowance the page doesn't know is still shown, in words", () => {
  const rows = map(planAllowances({ contacts_per_month: 200, beta_access: true }));
  assert.equal(rows["Contacts per month"], "200");
  assert.equal(rows["Beta access"], "Included");
});

test("no label or value has a key, underscore or dash", () => {
  for (const [label, value] of planAllowances({ languages: 1, call_recording_days: 30, voice_minutes: null })) {
    assert.doesNotMatch(`${label} ${value}`, /_|[A-Za-z]-[A-Za-z]|[—–]/);
  }
  assert.equal(allowanceLabel("team_members"), "Team seats (including the owner)");
  assert.deepEqual(planFeatures({ priority_support: false }), [["Priority support", "Not included"]]);
  assert.deepEqual(planAllowances(null).length > 0, true);
});
