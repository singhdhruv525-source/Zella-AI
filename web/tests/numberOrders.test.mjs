import { test } from "node:test";
import assert from "node:assert/strict";
import { ORDER_STATUS, orderActions, ordersBlocked } from "../src/admin/numberOrders.js";

test("ordering is off until both keys are added, then until the owner switches it on", () => {
  assert.match(ordersBlocked({ telnyx: false, vapi: true, enabled: true }), /^Not connected yet/);
  assert.match(ordersBlocked({ telnyx: true, vapi: false, enabled: true }), /^Not connected yet/);
  assert.match(ordersBlocked({ telnyx: true, vapi: true, enabled: false }), /switched off/);
  assert.equal(ordersBlocked({ telnyx: true, vapi: true, enabled: true }), "");
  assert.equal(ordersBlocked(null), "");
});

test("only an owner who didn't ask is offered Approve, and only while ordering is on", () => {
  const row = { status: "requested", requested_by: "a" };
  assert.deepEqual(orderActions(row, { you: "a", owner: true, manage: true, blocked: "" }), { approve: false, reject: false, cancel: true });
  assert.deepEqual(orderActions(row, { you: "b", owner: true, manage: true, blocked: "" }), { approve: true, reject: true, cancel: true });
  assert.deepEqual(orderActions(row, { you: "b", owner: true, manage: true, blocked: "off" }), { approve: false, reject: true, cancel: true });
  assert.deepEqual(orderActions(row, { you: "b", owner: false, manage: true, blocked: "" }), { approve: false, reject: false, cancel: false });
  assert.deepEqual(orderActions({ ...row, status: "approved" }, { you: "b", owner: true, manage: true, blocked: "" }), { approve: false, reject: false, cancel: false });
});

test("every state has words without dashes", () => {
  for (const k of ["requested", "approved", "placing", "completed", "failed", "needs_check", "rejected", "cancelled"]) {
    assert.ok(ORDER_STATUS[k]); assert.doesNotMatch(ORDER_STATUS[k][0], /[-–—]/);
  }
});
