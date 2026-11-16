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
