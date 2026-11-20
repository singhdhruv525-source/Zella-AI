// CFG-05 / UI-28: the default automations seeded into industry_configurations.automation_defaults
// (sql/zella_industry_data.sql) must equal what the browser's automationDefaultsFor gives today, for every industry.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { automationDefaultsFor } from "../src/industryAutomations.js";

const sql = readFileSync(new URL("../../sql/zella_industry_data.sql", import.meta.url), "utf8");
const rows = [...sql.matchAll(/^\s+\('([a-z]+)', '(\{.*\})'\)/gm)].map(([, key, json]) => [key, JSON.parse(json)]);

test("the seed covers all 28 industries, each equal to automationDefaultsFor", () => {
  assert.equal(rows.length, 28);
  for (const [key, seeded] of rows) assert.deepEqual(seeded, automationDefaultsFor(key), key);
});

test("the seed is keyed by the same normalised name the browser uses", () => {
  assert.ok(rows.some(([k]) => k === "beautysalon"));
  assert.deepEqual(automationDefaultsFor("Beauty & Salon"), rows.find(([k]) => k === "beautysalon")[1]);
});
