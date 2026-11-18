import { test } from "node:test";
import assert from "node:assert/strict";
import { needsFreshCode, refusalReason, signedOutText } from "../src/adminAccess.js";

test("signedOutText says how many devices were signed out, or why not", () => {
  assert.equal(signedOutText({ sessionsEnded: 0 }), "They had no signed in devices.");
  assert.equal(signedOutText({ sessionsEnded: 1 }), "They were signed out on 1 device.");
  assert.equal(signedOutText({ sessionsEnded: 3 }), "They were signed out on 3 devices.");
  assert.equal(signedOutText({ sessionsEnded: null, sessionsWarning: "Not signed out." }), "Not signed out.");
  assert.equal(signedOutText({}), "");
  assert.equal(signedOutText(null), "");
});

test("a FRESH_CODE_REQUIRED answer is recognised from the server's code, nothing else", () => {
  assert.equal(needsFreshCode({ code: "FRESH_CODE_REQUIRED" }), true);
  for (const e of [{ code: "MFA_REQUIRED" }, { message: "FRESH_CODE_REQUIRED" }, null, undefined]) assert.equal(needsFreshCode(e), false);
});

test("refusalReason puts each refusal in words", () => {
  assert.equal(refusalReason({ code: "NOT_ADMIN" }), "Not a Zella Voice admin");
  assert.equal(refusalReason({ code: "MFA_REQUIRED" }), "Two step sign in code not entered");
  assert.equal(refusalReason({ code: "MFA_SETUP_REQUIRED" }), "Two step sign in not set up");
  assert.equal(refusalReason({ code: "NOT_PERMITTED", permission: "admins.manage" }), "Their role doesn't allow it (admins.manage)");
  assert.equal(refusalReason({ code: "OTHER" }), "Refused");
  assert.equal(refusalReason(null), "Refused");
});

test("the audit page's Action filter lists every catalog action by label, and empty filters are dropped", async () => {
  const { auditActionOptions, auditQuery } = await import("../src/adminAccess.js");
  const catalog = JSON.parse((await import("node:fs")).readFileSync(new URL("../supabase/functions/_shared/catalog.json", import.meta.url), "utf8"));
  const opts = auditActionOptions(catalog);
  // every catalog action exactly once, each with its own catalog label
  assert.deepEqual(Object.fromEntries(opts.map((o) => [o.value, o.label])), catalog.audit_actions);
  assert.equal(opts.length, Object.keys(catalog.audit_actions).length);
  assert.deepEqual(opts.map((o) => o.label), [...opts.map((o) => o.label)].sort((a, b) => a.localeCompare(b)));
  assert.deepEqual(auditQuery({ businessId: "", auditAction: " admin.updated ", from: "2026-11-01", to: "" }), { auditAction: "admin.updated", from: "2026-11-01" });
});

test("business hours in words", async () => {
  const { businessHoursText } = await import("../src/adminAccess.js");
  assert.equal(businessHoursText(0.4), "under a business hour");
  assert.equal(businessHoursText(1), "1 business hour");
  assert.equal(businessHoursText(3.46), "3.5 business hours");
  assert.equal(businessHoursText(null), "");
});
