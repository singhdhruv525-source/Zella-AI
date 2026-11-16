// BIZ-30 part a: the tabs of one business's page, their addresses and keyboard moves.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DEFAULT_TAB, DETAIL_TABS, isDetailTab, tabKeyTarget } from "../src/business/tabs.js";

test("every tab has a one word slug, never the wizard's", () => {
  for (const t of DETAIL_TABS) assert.match(t.slug, /^[a-z]+$/, t.slug);
  assert.equal(isDetailTab("setup"), false);
  assert.equal(isDetailTab("people"), true);
  assert.equal(isDetailTab(undefined), false);
  assert.equal(DEFAULT_TAB, "overview");
});

test("arrow keys wrap, Home and End jump, other keys do nothing", () => {
  assert.equal(tabKeyTarget("ArrowRight", 7, 8), 0);
  assert.equal(tabKeyTarget("ArrowLeft", 0, 8), 7);
  assert.equal(tabKeyTarget("Home", 5, 8), 0);
  assert.equal(tabKeyTarget("End", 1, 8), 7);
  assert.equal(tabKeyTarget("Enter", 1, 8), null);
});

test("the address keeps the tab: /businesses/<id>/<tab>, setup still opens the wizard", () => {
  const dash = readFileSync(new URL("../src/OwnerDashboard.jsx", import.meta.url), "utf8");
  assert.match(dash, /third !== "setup"/);
  assert.match(dash, /isDetailTab\(third\) \? third : DEFAULT_TAB/);
  assert.match(dash, /third === "setup"\) route\.wizard/);
  const page = readFileSync(new URL("../src/BusinessDetails.jsx", import.meta.url), "utf8");
  for (const attr of ['role="tablist"', 'role="tabpanel"', "aria-controls", "aria-labelledby", "tabIndex={tab === t.slug ? 0 : -1}"]) assert.ok(page.includes(attr), attr);
});
