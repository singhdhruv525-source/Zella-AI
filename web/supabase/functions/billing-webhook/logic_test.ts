// deno test web/supabase/functions/billing-webhook/logic_test.ts   (no network)
import { assertEquals } from "jsr:@std/assert@1";
import { httpStatusFor, mapEvent, verifySignature } from "./logic.ts";

const enc = new TextEncoder();
async function sign(raw: string, secret: string, t: number) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = [...new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${raw}`)))].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `t=${t},v1=${mac}`;
}

Deno.test("signature: valid, wrong secret, old, missing, tampered body", async () => {
  const now = 1_800_000_000, raw = '{"id":"evt_1"}';
  assertEquals(await verifySignature(raw, await sign(raw, "whsec_test", now), "whsec_test", now), true);
  assertEquals(await verifySignature(raw, await sign(raw, "other", now), "whsec_test", now), false);
  assertEquals(await verifySignature(raw, await sign(raw, "whsec_test", now - 301), "whsec_test", now), false);
  assertEquals(await verifySignature(raw, null, "whsec_test", now), false);
  assertEquals(await verifySignature(raw + " ", await sign(raw, "whsec_test", now), "whsec_test", now), false);
  assertEquals(await verifySignature(raw, "v1=deadbeef", "whsec_test", now), false);
  assertEquals(await verifySignature(raw, "t=nope,v1=deadbeef", "whsec_test", now), false);
  assertEquals(await verifySignature(raw, await sign(raw, "whsec_test", now + 301), "whsec_test", now), false);
  // several v1 values (secret rotation): any match passes
  const good = await sign(raw, "whsec_test", now);
  assertEquals(await verifySignature(raw, `${good.split(",")[0]},v1=deadbeef,${good.split(",")[1]}`, "whsec_test", now), true);
});

const B = { livemode: false, account: null, currency: "usd" };
const inv = (type: string, obj: Record<string, unknown>, extra: Record<string, unknown> = {}) => ({ id: "evt", type, created: 1_800_000_000, livemode: false, data: { object: obj }, ...extra });
const PAID = { id: "in_1", status: "paid", paid: true, amount_paid: 4900, amount_due: 4900, amount_remaining: 0, currency: "usd", payment_intent: "pi_1", subscription: "sub_1",
  billing_reason: "subscription_cycle", lines: { data: [{ period: { start: 1_800_000_000, end: 1_802_592_000 } }] } };

Deno.test("a paid period comes only from invoice.paid, in integer minor units", () => {
  const m = mapEvent(inv("invoice.paid", PAID), B);
  assertEquals("args" in m && [m.args.p_type, m.args.p_amount_minor, m.args.p_currency, m.args.p_external_payment_id, m.args.p_period_end, m.args.p_reason],
    ["payment_succeeded", 4900, "usd", "pi_1", "2027-02-14T08:00:00.000Z", "subscription_cycle"]);
  assertEquals("args" in m && m.args.p_event_created, "2027-01-15T08:00:00.000Z");
  // the same payment also arrives as invoice.payment_succeeded and checkout.session.completed: neither grants again
  assertEquals("ignore" in mapEvent(inv("invoice.payment_succeeded", PAID), B), true);
  assertEquals("ignore" in mapEvent(inv("checkout.session.completed", { mode: "subscription", payment_status: "paid", subscription: "sub_1" }), B), true);
});

Deno.test("a status alone never grants a period (C-3)", () => {
  for (const status of ["active", "trialing", "past_due", "unpaid", "incomplete"]) {
    const m = mapEvent(inv("customer.subscription.updated", { id: "sub_1", status, current_period_start: 1, current_period_end: 2 }), B);
    assertEquals("ignore" in m, true, status);
  }
  for (const status of ["canceled", "incomplete_expired"]) {
    const m = mapEvent(inv("customer.subscription.updated", { id: "sub_1", status }), B);
    assertEquals("args" in m && m.args.p_type, "subscription_cancelled", status);
  }
});

Deno.test("a plan change or downgrade changes the plan only", () => {
  const m = mapEvent(inv("customer.subscription.updated", { id: "sub_1", status: "active", items: { data: [{ price: { lookup_key: "base" } }] } },
    { data: { object: { id: "sub_1", status: "active", items: { data: [{ price: { lookup_key: "base" } }] } }, previous_attributes: { items: {} } } }), B);
  assertEquals("args" in m && [m.args.p_type, m.args.p_plan_slug, m.args.p_period_start], ["plan_changed", "base", undefined]);
});

Deno.test("binding: wrong mode, wrong account, wrong currency or amounts that don't add up are quarantined (C-4)", () => {
  assertEquals("quarantine" in mapEvent(inv("invoice.paid", PAID, { livemode: true }), B), true);
  assertEquals("quarantine" in mapEvent(inv("invoice.paid", PAID, { account: "acct_other" }), B), true);
  assertEquals("quarantine" in mapEvent(inv("invoice.paid", PAID, { account: "acct_other" }), { ...B, account: "acct_ours" }), true);
  assertEquals("args" in mapEvent(inv("invoice.paid", PAID, { account: "acct_ours" }), { ...B, account: "acct_ours" }), true);
  assertEquals("args" in mapEvent(inv("invoice.paid", PAID), { ...B, account: "acct_ours" }), true);   // direct account events carry no account
  for (const bad of [{ currency: "eur" }, { amount_paid: 4000 }, { amount_remaining: 900 }, { status: "open" }, { paid: false }, { amount_paid: 49.5, amount_due: 49.5 },
    { amount_paid: -1, amount_due: -1 }, { payment_intent: null, charge: null, id: null }, { subscription: null }]) {
    assertEquals("quarantine" in mapEvent(inv("invoice.paid", { ...PAID, ...bad }), B), true, JSON.stringify(bad));
  }
  assertEquals("ignore" in mapEvent(inv("invoice.paid", { ...PAID, amount_paid: 0, amount_due: 0 }), B), true);
});

Deno.test("payment_intent may arrive expanded as an object; a failed payment is recorded", () => {
  const m = mapEvent(inv("invoice.payment_failed", { amount_due: 500, currency: "usd", payment_intent: { id: "pi_x" }, subscription: { id: "sub_x" } }), B);
  assertEquals("args" in m && [m.args.p_type, m.args.p_external_payment_id, m.args.p_external_subscription_id], ["payment_failed", "pi_x", "sub_x"]);
});

Deno.test("refunds: full reverses, partial is recorded as partial", () => {
  const full = mapEvent(inv("charge.refunded", { payment_intent: "pi_1", amount: 5000, amount_refunded: 5000, refunded: true }), B);
  const part = mapEvent(inv("charge.refunded", { payment_intent: "pi_1", amount: 5000, amount_refunded: 1000, refunded: false }), B);
  assertEquals("args" in full && [full.args.p_type, full.args.p_refund_minor], ["payment_reversed", 5000]);
  assertEquals("args" in part && [part.args.p_type, part.args.p_refund_minor], ["payment_refunded_partial", 1000]);
});

Deno.test("disputes: opened is not a refund; lost reverses; won clears", () => {
  const opened = mapEvent(inv("charge.dispute.created", { payment_intent: "pi_1", amount: 5000, status: "needs_response" }), B);
  const lost = mapEvent(inv("charge.dispute.closed", { payment_intent: "pi_1", amount: 5000, status: "lost" }), B);
  const won = mapEvent(inv("charge.dispute.closed", { payment_intent: "pi_1", amount: 5000, status: "won" }), B);
  assertEquals("args" in opened && opened.args.p_type, "payment_disputed");
  assertEquals("args" in lost && lost.args.p_type, "payment_reversed");
  assertEquals("args" in won && won.args.p_type, "dispute_won");
});

Deno.test("subscription deleted; unknown events ignored", () => {
  assertEquals(mapEvent(inv("customer.subscription.deleted", { id: "sub_1" }), B), { args: { p_event_created: "2027-01-15T08:00:00.000Z", p_type: "subscription_cancelled", p_external_subscription_id: "sub_1" } });
  assertEquals("ignore" in mapEvent(inv("customer.created", {}), B), true);
});

Deno.test("HTTP answers: waiting is 200 (Zella Voice retries itself), failure is 500 (provider retries)", () => {
  assertEquals([httpStatusFor("processed"), httpStatusFor("pending"), httpStatusFor("duplicate"), httpStatusFor("ignored"), httpStatusFor("failed"), httpStatusFor("??")],
    [200, 200, 200, 200, 500, 500]);
});

Deno.test("subscription events without a subscription id are quarantined", () => {
  for (const type of ["customer.subscription.deleted", "customer.subscription.updated"]) {
    assertEquals("quarantine" in mapEvent(inv(type, { status: "active" }), B), true);
  }
});
