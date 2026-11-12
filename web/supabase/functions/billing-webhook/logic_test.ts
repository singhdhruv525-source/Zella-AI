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

const inv = (type: string, obj: Record<string, unknown>) => ({ id: "evt", type, created: 1_800_000_000, data: { object: obj } });

Deno.test("amounts stay in integer minor units for every currency (no /100)", () => {
  for (const [currency, amount] of [["usd", 1999], ["jpy", 1500], ["kwd", 1234], ["USD", 0]] as const) {
    const m = mapEvent(inv("invoice.payment_succeeded", { amount_paid: amount, currency, payment_intent: "pi_1", subscription: "sub_1" }));
    assertEquals("args" in m && m.args.p_amount_minor, amount, currency);
    assertEquals("args" in m && m.args.p_currency, currency.toLowerCase());
  }
  const m = mapEvent(inv("invoice.payment_succeeded", { amount_paid: 1999, currency: "usd", payment_intent: "pi_1", subscription: "sub_1" }));
  assertEquals("args" in m && m.args.p_event_created, "2027-01-15T08:00:00.000Z");
});

Deno.test("bad amounts and currencies are refused, not guessed", () => {
  for (const obj of [{ amount_paid: 19.99, currency: "usd", payment_intent: "pi" }, { amount_paid: -1, currency: "usd", payment_intent: "pi" },
    { amount_paid: 100, currency: "dollars", payment_intent: "pi" }, { amount_paid: 100, currency: "usd" }]) {
    assertEquals("invalid" in mapEvent(inv("invoice.payment_succeeded", obj)), true, JSON.stringify(obj));
  }
});

Deno.test("payment_intent may arrive expanded as an object", () => {
  const m = mapEvent(inv("invoice.payment_failed", { amount_due: 500, currency: "eur", payment_intent: { id: "pi_x" }, subscription: { id: "sub_x" } }));
  assertEquals("args" in m && [m.args.p_type, m.args.p_external_payment_id, m.args.p_external_subscription_id], ["payment_failed", "pi_x", "sub_x"]);
});

Deno.test("refunds: full reverses, partial is recorded as partial", () => {
  const full = mapEvent(inv("charge.refunded", { payment_intent: "pi_1", amount: 5000, amount_refunded: 5000, refunded: true }));
  const part = mapEvent(inv("charge.refunded", { payment_intent: "pi_1", amount: 5000, amount_refunded: 1000, refunded: false }));
  assertEquals("args" in full && [full.args.p_type, full.args.p_refund_minor], ["payment_reversed", 5000]);
  assertEquals("args" in part && [part.args.p_type, part.args.p_refund_minor], ["payment_refunded_partial", 1000]);
});

Deno.test("disputes: opened is not a refund; lost reverses; won clears", () => {
  const opened = mapEvent(inv("charge.dispute.created", { payment_intent: "pi_1", amount: 5000, status: "needs_response" }));
  const lost = mapEvent(inv("charge.dispute.closed", { payment_intent: "pi_1", amount: 5000, status: "lost" }));
  const won = mapEvent(inv("charge.dispute.closed", { payment_intent: "pi_1", amount: 5000, status: "won" }));
  assertEquals("args" in opened && opened.args.p_type, "payment_disputed");
  assertEquals("args" in lost && lost.args.p_type, "payment_reversed");
  assertEquals("args" in won && won.args.p_type, "dispute_won");
});

Deno.test("subscription events; unknown events ignored", () => {
  assertEquals(mapEvent(inv("customer.subscription.deleted", { id: "sub_1" })), { args: { p_event_created: "2027-01-15T08:00:00.000Z", p_type: "subscription_cancelled", p_external_subscription_id: "sub_1" } });
  assertEquals("ignore" in mapEvent(inv("customer.subscription.updated", { id: "sub_1", status: "past_due" })), true);
  assertEquals("ignore" in mapEvent(inv("customer.created", {})), true);
});

Deno.test("HTTP answers: waiting is 200 (Zella Voice retries itself), failure is 500 (provider retries)", () => {
  assertEquals([httpStatusFor("processed"), httpStatusFor("pending"), httpStatusFor("duplicate"), httpStatusFor("ignored"), httpStatusFor("failed"), httpStatusFor("??")],
    [200, 200, 200, 200, 500, 500]);
});

Deno.test("subscription RPC args require a subscription id", () => {
  for (const type of ["customer.subscription.deleted", "customer.subscription.updated"]) {
    assertEquals("invalid" in mapEvent(inv(type, { status: "active" })), true);
  }
});
