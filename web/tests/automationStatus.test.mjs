// OPS-22 and UI-09 (copy): one automation status language, and catalog titles that start with a capital.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// automationCatalog.js imports industryAutomations.js without an extension (Vite resolves it); load both as data.
const read = (name) => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8");
const industry = "data:text/javascript;base64," + Buffer.from(read("industryAutomations.js")).toString("base64");
const catalogSource = read("automationCatalog.js").replace(/from "\.\/industryAutomations"/, `from "${industry}"`);
const { AUTOMATION_STATUS, CATALOG, automationStatusPill } = await import("data:text/javascript;base64," + Buffer.from(catalogSource).toString("base64"));

test("each stored status has one word and tone", () => {
  assert.deepEqual(AUTOMATION_STATUS.active, { label: "Active", tone: "success" });
  assert.deepEqual(AUTOMATION_STATUS.paused, { label: "Paused", tone: "warning" });
  assert.deepEqual(AUTOMATION_STATUS.disabled, { label: "Turned off", tone: "neutral" });
  assert.deepEqual(automationStatusPill("needs_review"), { label: "Needs review", tone: "neutral" });
});

test("the business page's automation list uses the shared map, not its own words", () => {
  const overview = read("AutomationOverview.jsx");
  assert.match(overview, /automationStatusPill\(row\.status\)/);
  assert.doesNotMatch(overview, /"off"|"None"/);
});

test("catalog titles start with a capital for any appointment word", () => {
  for (const word of ["visit", "appointment", "Job"]) {
    for (const [type, title] of CATALOG) assert.match(title(word), /^[A-Z0-9]/, `${type} with "${word}"`);
  }
  assert.equal(CATALOG[0][1]("visit"), "Visit reminders");
});
