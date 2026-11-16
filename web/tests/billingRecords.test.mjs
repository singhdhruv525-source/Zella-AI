// Admin payments lists: money shown from integer cents, every status has words and a tone, no dashes in the words.
//   cd web && node --test tests/billingRecords.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { DISPUTE_STATUS, INVOICE_STATUS, REFUND_KIND, REFUND_STATUS, usd } from "../src/admin/billingRecords.js";

const DASH = /[—–]|[A-Za-z]-[A-Za-z]/;
test("cents to dollars, without rounding errors, and unknowns said in words", () => {
  assert.equal(usd(89800), "$898.00");
  assert.equal(usd(1), "$0.01");
  assert.equal(usd(0), "$0.00");
  assert.equal(usd(-2900), "-$29.00");
  assert.equal(usd(null), "$0.00");
  assert.equal(usd("abc"), "Not available");
});
test("every status the database writes has words and a known tone", () => {
  const tones = new Set(["neutral", "info", "success", "warning", "danger"]);
  for (const [map, keys] of [[INVOICE_STATUS, ["draft", "open", "paid", "payment_failed", "void", "uncollectible"]], [REFUND_STATUS, ["requested", "sending", "processed", "failed", "rejected", "uncertain"]], [DISPUTE_STATUS, ["open", "won", "lost", "closed"]]]) {
    for (const k of keys) { assert.ok(map[k], k); assert.ok(tones.has(map[k][1]), k); assert.ok(!DASH.test(map[k][0]), k); }
  }
  for (const k of ["guarantee", "setup_fee", "pack", "annual", "error", "outside"]) assert.ok(REFUND_KIND[k] && !DASH.test(REFUND_KIND[k]), k);
});
