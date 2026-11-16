// Alert rules editor helpers (web/src/settings/panels/alertRules.js, SET-ALERT-RULES).
import { test } from "node:test";
import assert from "node:assert/strict";
import { formFrom, ruleFromForm, ruleRows, ruleSummary } from "../src/settings/panels/alertRules.js";

const catalog = { alert_kinds: { provider_down: "A provider is not responding", offer_ending_soon: "An offer ends soon" } };
const data = { protected: ["provider_down"], seen: { offer_ending_soon: 3 },
  rules: [{ kind: "offer_ending_soon", enabled: true, severity: "info", destination: "bell_and_email", email_permission: "billing.view", repeat_minutes: 60, quiet_start: "22:00:00", quiet_end: "07:00:00", quiet_tz: "UTC" }] };

test("every kind from the shared catalog is listed, with its rule, protection and count", () => {
  const rows = ruleRows(catalog, data);
  assert.deepEqual(rows.map((r) => [r.kind, r.protected, r.seen, Boolean(r.rule)]), [["offer_ending_soon", false, 3, true], ["provider_down", true, 0, false]]);
});

test("a rule reads as one plain sentence", () => {
  const [offer, provider] = ruleRows(catalog, data);
  assert.equal(ruleSummary(offer), "Info, email to admins with billing.view, at most every hour, quiet 22:00 to 07:00");
  assert.equal(ruleSummary(provider), "As raised, always urgent");
  assert.equal(ruleSummary({ rule: { enabled: false } }), "Off");
});

test("a protected kind can't be switched off or lowered from the form", () => {
  const f = { ...formFrom({ rule: null }), enabled: false, severity: "info" };
  const r = ruleFromForm(f, true);
  assert.equal(r.enabled, true);
  assert.equal(r.severity, null);
  assert.equal(ruleFromForm({ ...f, severity: "urgent" }, true).severity, "urgent");
  assert.equal(ruleFromForm(f, false).enabled, false);
});

test("bell only drops the email group; quiet hours only when switched on", () => {
  const f = formFrom(ruleRows(catalog, data)[0]);
  assert.deepEqual([f.quiet, f.quiet_start, f.quiet_end], [true, "22:00", "07:00"]);
  const r = ruleFromForm({ ...f, destination: "bell", quiet: false }, false);
  assert.deepEqual([r.destination, r.email_permission, r.quiet_start, r.quiet_end], ["bell", null, null, null]);
});

test("rules group by area, and the search and changed switch narrow them", async () => {
  const { groupRules, ruleArea } = await import("../src/settings/panels/alertRules.js");
  assert.equal(ruleArea("payment_failed"), "Billing");
  assert.equal(ruleArea("offer_new_kind"), "Offers");
  assert.equal(ruleArea("provider_down"), "Platform");
  const rows = ruleRows(catalog, data);
  assert.deepEqual(groupRules(rows).map((g) => [g.area, g.rows.length]), [["Offers", 1], ["Platform", 1]]);
  assert.deepEqual(groupRules(rows, { changedOnly: true }).map((g) => g.area), ["Offers"]);
  assert.deepEqual(groupRules(rows, { query: "provider" }).map((g) => g.rows[0].kind), ["provider_down"]);
  assert.deepEqual(groupRules(rows, { query: "nothing like this" }), []);
});
