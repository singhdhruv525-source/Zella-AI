import { test } from "node:test";
import assert from "node:assert/strict";
import { signedOutText } from "../src/adminAccess.js";

test("signedOutText says how many devices were signed out, or why not", () => {
  assert.equal(signedOutText({ sessionsEnded: 0 }), "They had no signed in devices.");
  assert.equal(signedOutText({ sessionsEnded: 1 }), "They were signed out on 1 device.");
  assert.equal(signedOutText({ sessionsEnded: 3 }), "They were signed out on 3 devices.");
  assert.equal(signedOutText({ sessionsEnded: null, sessionsWarning: "Not signed out." }), "Not signed out.");
  assert.equal(signedOutText({}), "");
  assert.equal(signedOutText(null), "");
});
