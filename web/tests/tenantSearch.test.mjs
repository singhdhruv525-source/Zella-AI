import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../supabase/functions/owner-provision-business/settings.ts", import.meta.url), "utf8");
const { settingsHandlers } = await import("data:text/javascript;base64," + Buffer.from(stripTypeScriptTypes(source)).toString("base64"));
for (const [label, subscriptions, failed] of [
  ["subscription", { data: [{ business_id: "fake-business", status: "active", plan_id: "fake-plan" }] }, false],
  ["none", { data: [] }, false],
  ["failed", { data: null, error: { message: "unavailable" } }, true],
  ["empty page", { data: [] }, false],
]) test("tenants_search: " + label, async () => {
  const tables = [];
  const admin = { from(table) {
    tables.push(table);
    const response = table === "businesses" ? { data: label === "empty page" ? [] : [{ id: "fake-business" }], count: label === "empty page" ? 0 : 1 }
      : table === "subscriptions" ? subscriptions : { data: [] };
    const query = new Proxy({}, { get: (_, key) => key === "then" ? (resolve) => resolve(response) : () => query });
    return query;
  }};
  const k = { text: (v) => v ?? "", UUID_RE: /^never$/ };
  const result = await settingsHandlers(admin, {}, {}, k).handlers.tenants_search();
  assert.equal(result.subscriptionLookupFailed, failed);
  assert.equal(result.rows.length, label === "empty page" ? 0 : 1);
  if (result.rows.length) assert.equal(Boolean(result.rows[0].subscription), label === "subscription");
  else assert.ok(!tables.includes("subscriptions"));
});
const panels = readFileSync(new URL("../src/settings/AdminPanels.jsx", import.meta.url), "utf8");
test("plan display distinguishes unavailable, none and a subscription", () => {
  const expression = panels.match(/\["Plan", \(b\) => \((.*?)\)\],/)[1];
  const display = new Function("r", "b", "words", "return " + expression);
  assert.equal(display({ subscriptionLookupFailed: true }, {}, String), "Unavailable");
  assert.equal(display({}, {}, String), "None");
  assert.equal(display({}, { subscription: { plan: "Basic", status: "active" } }, String), "Basic · active");
});
test("summary toggle labels match expanded state without an overriding accessible name", () => {
  const button = panels.split('aria-expanded={expanded === b.id}')[1].split("</button>")[0];
  assert.ok(!button.includes("aria-label"));
  const expression = button.match(/>\{(.*?)\}$/)[1];
  const label = new Function("expanded", "b", "return " + expression);
  assert.equal(label(null, { id: "fake" }), "Show summary");
  assert.equal(label("fake", { id: "fake" }), "Hide summary");
});
