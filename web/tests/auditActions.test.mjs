// BIZ-25: the business page's Activity labels come from the shared catalog (PLT-08), system records name the table,
// and nothing reads as raw code. That every written action is in the catalog is tests/catalog/drift_test.mjs's job.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { ACTION_LABELS, actionLabel } from "../src/copy/auditActions.js";
import { ACTION_LABELS as OLD_LABELS } from "../src/ownerFormat.js";

const catalog = JSON.parse(readFileSync(new URL("../supabase/functions/_shared/catalog.json", import.meta.url), "utf8"));

test("every catalog action reads with its catalog label", () => {
  for (const [action, label] of Object.entries(catalog.audit_actions)) assert.equal(actionLabel(action), label, action);
  assert.equal(Object.keys(ACTION_LABELS).length, Object.keys(catalog.audit_actions).length);
});

test("every action the old label list knew still has a label", () => {
  for (const action of Object.keys(OLD_LABELS)) assert.ok(Object.hasOwn(ACTION_LABELS, action), action);
});

test("system change records name the table", () => {
  assert.equal(actionLabel("privileged_update", "businesses"), "Changed business (system record)");
  assert.equal(actionLabel("privileged_insert", "business_members"), "Added member (system record)");
  assert.equal(actionLabel("privileged_delete", "automations"), "Removed automation (system record)");
  assert.equal(actionLabel("privileged_update", "some_new_table"), "Changed some new table (system record)");
  assert.equal(actionLabel("privileged_update"), catalog.audit_actions.privileged_update);
});

test("unknown actions read as words, never raw code", () => {
  assert.equal(actionLabel("brand_new.thing_done"), "Brand new thing done");
  assert.equal(actionLabel(null), "Unknown action");
  assert.equal(actionLabel("automation.archived"), "Turned off automation");
});
