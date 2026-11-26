import { test } from "node:test";
import assert from "node:assert/strict";
import { ATTEND_ACTION, attendOutcome, pageAction } from "./rescheduleAction.js";

test("the Confirm and Cancel buttons open the page in their own mode; anything else is Reschedule", () => {
  assert.equal(pageAction("?do=confirm"), "confirm");
  assert.equal(pageAction("?do=cancel"), "cancel");
  assert.equal(pageAction(""), "reschedule");
  assert.equal(pageAction("?do=delete"), "reschedule");
  assert.equal(pageAction("?do=CANCEL"), "reschedule");
  assert.equal(pageAction(undefined), "reschedule");
});
test("each button calls its own action", () => assert.deepEqual(ATTEND_ACTION, { confirm: "attend_confirm", cancel: "attend_cancel" }));
test("only a confirmed server answer is a success (UX-2)", () => {
  assert.deepEqual(attendOutcome({ ok: true, result: "confirmed" }), { done: "confirmed" });
  assert.deepEqual(attendOutcome({ ok: true, result: "already_confirmed" }), { done: "already_confirmed" });
  assert.deepEqual(attendOutcome({ ok: true, result: "cancelled" }), { done: "cancelled" });
  assert.deepEqual(attendOutcome({ ok: true }), { problem: "invalid" });
  assert.deepEqual(attendOutcome({ ok: false, reason: "past" }), { problem: "past" });
  assert.deepEqual(attendOutcome({ ok: false, reason: "not_available" }), { problem: "not_available" });
  assert.deepEqual(attendOutcome({ ok: false, reason: "weird" }), { problem: "invalid" });
  assert.deepEqual(attendOutcome(null), { problem: "invalid" });
});
