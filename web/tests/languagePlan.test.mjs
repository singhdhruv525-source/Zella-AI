// The receptionist's languages and the plan, in words (src/business/languagePlan.js, sql/zella_admin_languages.sql):
// the same rule as the server's zella_language_plan_refusal, and no dashes in what people read.
//   cd web && node --test tests/languagePlan.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { familyOf, languageError, planMessage, planRefusal, planSummary } from "../src/business/languagePlan.js";

const catalog = [
  { code: "en-US", label: "English (US)", english: true }, { code: "en-GB", label: "English (UK)", english: true },
  { code: "es", label: "Spanish", english: false }, { code: "es-419", label: "Spanish (Latin America)", english: false },
  { code: "fr", label: "French", english: false },
];
const one = { source: "business_plan", plan: "Base v1", allowance: 1, plan_languages: ["en"], spanish_allowed: false, second_language_allowed: false };
const two = { source: "business_plan", plan: "Pro v2", allowance: 2, plan_languages: ["en", "es"], spanish_allowed: true, second_language_allowed: true };
const legacy1 = { source: "subscription_plan", plan: "Starter", allowance: 1, plan_languages: null, spanish_allowed: false, second_language_allowed: false };
const none = { source: "none", plan: null, allowance: null, plan_languages: null, spanish_allowed: true, second_language_allowed: true };

test("language families: every English variant is en, Spanish variants are es", () => {
  assert.equal(familyOf("en-GB", catalog), "en");
  assert.equal(familyOf("es-419", catalog), "es");
  assert.equal(familyOf("fr", catalog), "fr");
  assert.equal(familyOf("", catalog), null);
});

test("a plan with 1 language means English only; 2 allows Spanish; no plan means no limit", () => {
  assert.equal(planRefusal(one, "en-US", ["es"], catalog), "This plan includes 1 language. Move the business to a plan with Spanish first.");
  assert.equal(planRefusal(one, "es", [], catalog), "This plan includes 1 language. Move the business to a plan with Spanish first.");
  assert.equal(planRefusal(one, "en-GB", [], catalog), null);
  assert.equal(planRefusal(legacy1, "es", [], catalog), planMessage(legacy1));
  assert.equal(planRefusal(two, "en-US", ["es"], catalog), null);
  assert.match(planRefusal(two, "en-US", ["fr"], catalog), /^This plan includes 2 languages \(English and Spanish\)/);
  assert.match(planRefusal(two, "en-US", ["es", "es-419"], catalog), /^This plan includes 2 languages/);
  assert.equal(planRefusal(none, "en-US", ["es", "fr"], catalog), null);
  assert.equal(planRefusal(null, "es", [], catalog), null);
});

test("the plan in one sentence, and the server's refusals in words", () => {
  assert.equal(planSummary(one), "The plan (Base v1) includes 1 language (English). A second language can't be added.");
  assert.equal(planSummary(two), "The plan (Pro v2) includes 2 languages (English and Spanish).");
  assert.match(planSummary(none), /^No plan is set for this business yet/);
  assert.equal(languageError({ message: "PLAN_LANGUAGES" }, one), "This plan includes 1 language. Move the business to a plan with Spanish first.");
  assert.match(languageError({ message: "LANGUAGES_ADMIN_ONLY" }), /^Only Zella Voice admins/);
  assert.match(languageError({ message: "Could not find the function" }), /latest Zella Voice update/);
});

test("no dashes or hyphens in the words people read", () => {
  const texts = [one, two, legacy1, none].flatMap((p) => [planSummary(p), planMessage(p)])
    .concat(["LANGUAGES_ADMIN_ONLY", "UNKNOWN_LANGUAGE", "TOO_MANY_LANGUAGES", "GREETING_LENGTH", "GREETING_TEXT", "GREETING_AI_DISCLOSURE", "NOT_FOUND"].map((m) => languageError({ message: m })));
  for (const t of texts) assert.equal(/[-–—]/.test(t), false, t);
});
