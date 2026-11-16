// BIZ-25: every audit action Zella Voice writes has a label, and the labels admins already see are unchanged.
import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { ACTION_FAMILIES, ACTION_LABELS, actionLabel } from "../src/copy/auditActions.js";
import { ACTION_LABELS as OLD_LABELS } from "../src/ownerFormat.js";
import { collectActions, sqlActions, tsActions } from "./auditActionScan.mjs";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const familyOf = (prefix) => ACTION_FAMILIES.find(([p]) => p === prefix);

test("every action written by sql/*.sql and the admin function has a label", () => {
  const found = collectActions(ROOT);
  assert.ok(found.size > 60, `the scan found only ${found.size} actions, so its scope is broken`);
  const missing = [];
  for (const [action, files] of found) {
    const ok = /[._]$/.test(action) ? Boolean(familyOf(action)) : Object.hasOwn(ACTION_LABELS, action);
    if (!ok) missing.push(`${action} (${files.join(", ")})`);
  }
  assert.deepEqual(missing, [], "add these to web/src/copy/auditActions.js");
});

test("labels already shown on Activity and Audit logs are unchanged", () => {
  for (const [action, label] of Object.entries(OLD_LABELS)) assert.equal(actionLabel(action), label, action);
});

test("system change records name the table", () => {
  assert.equal(actionLabel("privileged_update", "businesses"), "Changed business (system record)");
  assert.equal(actionLabel("privileged_insert", "business_members"), "Added member (system record)");
  assert.equal(actionLabel("privileged_delete", "automations"), "Removed automation (system record)");
  assert.equal(actionLabel("privileged_update", "some_new_table"), "Changed some new table (system record)");
  assert.equal(actionLabel("privileged_update"), "Changed record (system record)");
});

test("families and unknown actions read as words, never raw code", () => {
  assert.equal(actionLabel("platform.alert_resolved"), "Platform alert resolved");
  assert.equal(actionLabel("business.document_verified"), "Verification document verified");
  assert.equal(actionLabel("automation.paused"), "Paused automation");
  assert.equal(actionLabel("automation.something_new"), "Automation something new");
  assert.equal(actionLabel("brand_new.thing_done"), "Brand new thing done");
  assert.equal(actionLabel(null), "Unknown action");
  for (const label of Object.values(ACTION_LABELS)) {
    assert.doesNotMatch(label, /[_]|\b[a-z]+\.[a-z]+\b/, label);
    assert.doesNotMatch(label, /[–—]|[A-Za-z]-[A-Za-z]/, label);
  }
});

test("the scan reads insert statements, zella_admin_audit calls and action: lines, and skips comments", () => {
  const sql = `-- insert into audit_logs (action) values ('not.real');
insert into public.audit_logs (business_id, action) values (v_b, 'offer.' || p_kind);
insert into audit_logs (action, new_data) values ('customer.added', jsonb_build_object('reason', 1));
perform public.zella_admin_audit('telephony.number_released', 'phone_number', n.id);`;
  assert.deepEqual(sqlActions(sql).sort(), ["customer.added", "offer.", "telephony.number_released"].sort());
  const ts = `  a: (r) => ({
    action: r.created
      ? "business.draft_created"
      : "business.updated",
    business_id: r.businessId,
  }),
  b: (r) => ({ action: "platform.alert_" + r.status, entity_type: "platform_alert" }),
  c: "not.an_action",`;
  assert.deepEqual(tsActions(ts).sort(), ["business.draft_created", "business.updated", "platform.alert_"]);
});
