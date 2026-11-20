// BIZ-21: the page shows when Resend can go again, from the server's rule.
import test from "node:test";
import assert from "node:assert/strict";
import { RESEND_COOLDOWN_MINUTES, resendAt } from "../src/business/people.js";

test("resend cooldown mirrors the server's five minutes", () => {
  const now = new Date("2026-11-16T12:00:00Z");
  assert.equal(RESEND_COOLDOWN_MINUTES, 5);
  assert.equal(resendAt(null, now), null);
  assert.equal(resendAt("2026-11-16T11:50:00Z", now), null);
  assert.equal(resendAt("2026-11-16T11:58:00Z", now).toISOString(), "2026-11-16T12:03:00.000Z");
});
