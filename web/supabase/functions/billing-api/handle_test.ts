// billing-api, checkout_start and checkout_return for Stripe's card fields in our page (owner, 27 Nov 2026), locally: the
// database answers come from a stand in (the owner function's own checks are proven in tests/stripe_checkout), and
// Stripe is the in-memory fake (tests/stripe_fake). Nothing reaches Supabase or Stripe.
// Run: deno test --no-lock --allow-net=127.0.0.1 --allow-env web/supabase/functions/billing-api/handle_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { startFakeStripe } from "../../../../tests/stripe_fake/fake_stripe.ts";
import { stripeClient } from "../_shared/stripe.ts";

const BACKEND = "http://supabase.test.local";
const BIZ = "11111111-1111-4111-8111-111111111111", CHECKOUT = "22222222-2222-4222-8222-222222222222";
const fake = startFakeStripe();
const stripe = stripeClient({ secretKey: "sk_test_handle", baseUrl: fake.url });
const env = { SUPABASE_URL: BACKEND, SUPABASE_ANON_KEY: "anon-test", ZELLA_SERVER_SECRET_KEY: "server-test", STRIPE_SECRET_KEY: "sk_test_handle",
  STRIPE_API_BASE: fake.url, STRIPE_PUBLISHABLE_KEY: "pk_test_handle0001" };
for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
const { handle, resetApplyThrottle } = await import("./index.ts");

// the database stand in: what the owner functions and the server functions answer
type Answer = Record<string, unknown> | Error | null;
type Db = { checkout: Record<string, unknown> | null; payment: Record<string, unknown>; start?: Record<string, unknown> | Error;
  invoice?: Answer; invoiceStart?: Answer; refs?: Answer; packAct?: Answer; pack?: Answer; prefill?: unknown; autopay?: AutoPay;
  limited?: boolean; noMigration?: boolean; reopened?: Record<string, unknown>[]; checkoutAutopay?: unknown[]; hosted?: string[]; expired?: string[] };
// Auto pay's database stand in: the owner's choice (versioned), our record of Stripe's value (changed ONLY by an applied
// customer.subscription.updated), the outbox rows, and the Stripe events not yet applied
type AutoPay = { owner: boolean; card: boolean; sub: string; on: boolean; desired: boolean | null; version: number; keys: Set<string>;
  outbox: { id: string; idempotency_key: string; method: "POST"; path: string; body: Record<string, unknown>; attempts: number; status: string }[]; applied: Set<string>; hold?: boolean };
let db: Db;
const calls: { fn: string; args: Record<string, unknown>; as: string }[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: Request | URL | string, init?: RequestInit) => {
  const url = String(input instanceof Request ? input.url : input);
  if (!url.startsWith(BACKEND)) return realFetch(input, init);
  const fn = url.split("/rpc/")[1];
  const args = JSON.parse(String(init?.body ?? "{}"));
  const auth = new Headers(init?.headers).get("authorization") ?? "";
  calls.push({ fn, args, as: auth.endsWith("server-test") ? "server" : "owner" });
  const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status, headers: { "Content-Type": "application/json" } });
  if (fn === "zella_owner_billing_checkout_start") return db.start instanceof Error ? json({ message: db.start.message }, 400) : json(db.start ?? { checkout_id: CHECKOUT, status: db.checkout?.status });
  if (fn === "zella_billing_checkout_session") return db.noMigration ? json({ code: "PGRST202", message: "Could not find the function public.zella_billing_checkout_session" }, 404) : json(db.checkout);
  const answer = (a: Answer | undefined) => a instanceof Error ? json({ message: a.message }, 400) : json(a ?? null);
  if (fn === "zella_owner_invoice_pay_status") return answer(db.invoice);
  if (fn === "zella_owner_invoice_pay_start") return answer(db.invoiceStart);
  if (fn === "zella_billing_stripe_refs") return answer(db.refs);
  if (fn === "zella_rate_limit") return json(!db.limited);
  if (fn === "zella_billing_pack_reopen") { (db.reopened ??= []).push(args); return json({ purchase_id: args.p_purchase_id }); }
  if (fn === "zella_billing_pack_reopen_expire") { (db.expired ??= []).push(args.p_purchase_id); return json("expired"); }
  if (fn === "zella_billing_checkout_autopay") { (db.checkoutAutopay ??= []).push(args); return json(null); }
  if (fn === "zella_billing_checkout_use_hosted") { (db.hosted ??= []).push(args.p_checkout_id); return json(true); }
  if (fn === "zella_billing_address_prefill") return json(db.prefill ?? null);
  if (fn === "zella_owner_billing_access") return json({ business_id: BIZ, payments_live: true, app_base_url: "https://app.example.test" });
  if (fn === "zella_owner_pack_act_start") return answer(db.packAct);
  if (fn === "zella_owner_pack_status") return answer(db.pack);
  if (fn === "zella_owner_onboarding_payment_status") return json(db.payment);
  const ap = db.autopay;
  if (ap && fn === "zella_owner_autopay_status") return ap.owner ? json({ on: ap.on, desired: ap.desired ?? ap.on, pending: ap.desired !== null && ap.desired !== ap.on }) : json({ message: "NOT_ALLOWED" }, 400);
  if (ap && fn === "zella_owner_autopay_set") {
    if (!ap.owner) return json({ message: "NOT_ALLOWED" }, 400);
    if (ap.keys.has(args.p_idempotency_key) || (ap.desired ?? ap.on) === args.p_on) return json({});
    if (args.p_on && !ap.card) return json({ message: "NO_SAVED_CARD" }, 400);
    ap.keys.add(args.p_idempotency_key); ap.desired = args.p_on; ap.version++;
    ap.outbox.push({ id: crypto.randomUUID(), idempotency_key: `autopay:${ap.sub}:${ap.version}:1`, method: "POST", path: `/v1/subscriptions/${ap.sub}`,
      body: args.p_on ? { collection_method: "charge_automatically" } : { collection_method: "send_invoice", days_until_due: 3 }, attempts: 1, status: "pending" });
    return json({});
  }
  if (ap && fn === "zella_billing_autopay_next_command") return json(ap.outbox.find((o) => o.status === "pending")?.id ?? null);
  if (ap && fn === "zella_billing_outbox_claim") { const o = ap.outbox.find((x) => x.id === args.p_id && x.status === "pending"); if (o) o.status = "sending"; return json(o ? [o] : []); }
  if (ap && fn === "zella_billing_outbox_result") { const o = ap.outbox.find((x) => x.id === args.p_id)!; o.status = args.p_ok ? "sent" : "held"; return json(o.status); }
  if (ap && fn === "zella_stripe_claim_events") {
    if (ap.hold) return json([]);
    const rows = fake.events.filter((e) => e.type === "customer.subscription.updated" && e.data.object.id === ap.sub && !ap.applied.has(e.id))
      .map((e) => ({ id: e.id, type: e.type, object_type: "subscription", object_id: e.data.object.id, livemode: false, payload: null }));
    return json(rows);
  }
  if (ap && fn === "zella_stripe_apply_event") { ap.applied.add(args.p_event_id); ap.on = args.p_object.collection_method !== "send_invoice"; return json("applied"); }
  if (fn === "zella_billing_events_claim" || fn.startsWith("zella_billing_")) return json(null);
  if (fn === "zella_platform_alert") return json(null);
  return json(null);
};

async function newSession(extra: Record<string, unknown> = {}) {
  const cus = await stripe.post("/v1/customers", { metadata: { business_id: BIZ } }, `customer:${crypto.randomUUID()}`);
  const prod = await stripe.post("/v1/products", { name: "Zella Voice plan" }, `product:${crypto.randomUUID()}`);
  const price = await stripe.post("/v1/prices", { product: prod.id, currency: "usd", unit_amount: 29900, recurring: { interval: "month" } }, `price:${crypto.randomUUID()}`);
  return await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, client_reference_id: CHECKOUT, ui_mode: "custom",
    return_url: "https://app.example.test/welcome/setup?checkout=return&session_id={CHECKOUT_SESSION_ID}",
    line_items: [{ price: price.id, quantity: 1 }], metadata: { business_id: BIZ, checkout_id: CHECKOUT }, ...extra }, `checkout:${crypto.randomUUID()}`);
}
const openRow = (sid: string, status = "open") => ({ checkout_id: CHECKOUT, status, stripe_session_id: sid, mode: "pay", amount_minor: 29900, currency: "usd", expires_at: "2026-11-28T10:00:00Z" });
const post = async (body: Record<string, unknown>) => {
  const r = await handle(new Request("http://fn", { method: "POST", headers: { Authorization: "Bearer owner-jwt", "Content-Type": "application/json" }, body: JSON.stringify(body) }));
  return { status: r.status, body: await r.json() };
};
const start = () => post({ action: "checkout_start", business_id: BIZ, idempotency_key: "owner-key-0001", amount_minor: 1 });

// every console line during a test, so we can prove the client secret is never logged
const logged: string[] = [];
for (const k of ["log", "error", "warn", "info"] as const) { const orig = console[k]; console[k] = (...a: unknown[]) => { logged.push(a.map(String).join(" ")); void orig; }; }

Deno.test("checkout_start returns the in page (custom) session's client secret, the publishable key and the database's amount", async () => {
  const s = await newSession();
  db = { checkout: openRow(s.id), payment: { status: "waiting" } };
  const r = await start();
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals([r.body.status, r.body.client_secret, r.body.publishable_key, r.body.livemode], ["open", s.client_secret, "pk_test_handle0001", false]);
  assertEquals(r.body.billing_prefill, {}, "no address on file: Stripe's fields start empty (United States)");
  assertEquals([r.body.amount_minor, r.body.currency, r.body.mode], [29900, "usd", "pay"]);   // never the 1 the browser sent
  assert(!("url" in r.body), "no hosted page link");
  assert(logged.every((l) => !l.includes(String(s.client_secret))), "the client secret is never logged");
});

Deno.test("no publishable key: payments stay closed; a key in the other mode alerts and never starts a checkout", async () => {
  db = { checkout: null, payment: { status: "waiting" } };
  Deno.env.delete("STRIPE_PUBLISHABLE_KEY");
  assertEquals((await start()).body.code, "PAYMENTS_NOT_LIVE");
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", "pk_live_handle0001");
  calls.length = 0;
  const r = await start();
  assertEquals([r.status, r.body.code], [503, "PAYMENTS_MISCONFIGURED"]);
  // the owner check runs first (review 7), then the key check closes everything: nothing is prepared or sent
  assert(calls.some((c) => c.fn === "zella_platform_alert" && c.args.p_kind === "stripe_key_mode_mismatch"));
  assert(!calls.some((c) => c.fn === "zella_billing_checkout_continue"), "nothing is prepared at Stripe")
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", "not-a-key");
  assertEquals((await start()).body.code, "PAYMENTS_NOT_LIVE");
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", env.STRIPE_PUBLISHABLE_KEY);
});

Deno.test("a session that isn't ours (another checkout or business) never hands out its secret", async () => {
  const other = await newSession({ client_reference_id: "33333333-3333-4333-8333-333333333333" });
  db = { checkout: openRow(other.id), payment: { status: "waiting" } };
  const r = await start();
  assertEquals(r.status, 500);
  assert(!JSON.stringify(r.body).includes("secret"));
  const foreign = await newSession({ metadata: { business_id: "44444444-4444-4444-8444-444444444444", checkout_id: CHECKOUT } });
  db = { checkout: openRow(foreign.id), payment: { status: "waiting" } };
  assertEquals((await start()).status, 500);
});

Deno.test("paid at Stripe: processing, no form; expired at Stripe: start again; not ready yet: try again", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  db = { checkout: openRow(s.id), payment: { status: "waiting" } };
  assertEquals((await start()).body, { status: "processing" });
  db = { checkout: openRow(s.id, "completed"), payment: { status: "waiting" } };
  assertEquals((await start()).body, { status: "processing" });
  const e = await newSession();
  await stripe.post(`/v1/checkout/sessions/${e.id}/expire`, {}, `expire:${e.id}`);
  db = { checkout: openRow(e.id), payment: { status: "waiting" } };
  const x = await start();
  assertEquals([x.status, x.body.code], [409, "CHECKOUT_EXPIRED"]);
  db = { checkout: { ...openRow(""), stripe_session_id: null, status: "preparing" }, payment: { status: "waiting" } };
  assertEquals((await start()).body.code, "CHECKOUT_NOT_READY");
});

Deno.test("a hosted session is never passed off as an in page one: Stripe's own page, no client secret", async () => {
  const cus = await stripe.post("/v1/customers", {}, `customer:${crypto.randomUUID()}`);
  const prod = await stripe.post("/v1/products", { name: "x" }, `product:${crypto.randomUUID()}`);
  const price = await stripe.post("/v1/prices", { product: prod.id, currency: "usd", unit_amount: 29900, recurring: { interval: "month" } }, `price:${crypto.randomUUID()}`);
  const h = await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, client_reference_id: CHECKOUT, success_url: "https://app.example.test/ok",
    line_items: [{ price: price.id, quantity: 1 }], metadata: { business_id: BIZ } }, `checkout:${crypto.randomUUID()}`);
  db = { checkout: openRow(h.id), payment: { status: "waiting" } };
  const r = await start();
  assertEquals([r.body.status, "client_secret" in r.body, String(r.body.url).startsWith("https://checkout.stripe.com/")], ["redirect", false, true]);
});

Deno.test("the owner's own refusals pass through in words (the database decides who may pay)", async () => {
  db = { checkout: null, payment: { status: "waiting" }, start: new Error("NOT_ALLOWED") };
  const r = await start();
  assertEquals([r.status, r.body.code], [400, "NOT_ALLOWED"]);
});

Deno.test("checkout_return: card brand and last 4 only once the server confirmed the payment, and only as Stripe returns them", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  db = { checkout: openRow(s.id, "completed"), payment: { status: "waiting", reason: "processing" } };
  const waiting = await post({ action: "checkout_return", business_id: BIZ });
  assertEquals(waiting.body, { payment: { status: "waiting", reason: "processing" } });   // no card before it is confirmed
  db = { checkout: openRow(s.id, "paid"), payment: { status: "confirmed" } };
  const done = await post({ action: "checkout_return", business_id: BIZ });
  assertEquals(done.body.card, { brand: "visa", last4: "4242", issuer: "Test Bank" });
  const req = fake.requests.findLast((x) => x.method === "GET" && x.path.endsWith(s.id));
  assertEquals(req?.body.expand, ["subscription.default_payment_method"]);
  assert(!JSON.stringify(done.body).match(/exp_|cvc|number/i), "nothing but brand and last 4");
});

// ---- paying from inside the CRM: Pay now, the saved card, Update card, finishing a pack ----
const INVOICE = "55555555-5555-4555-8555-555555555555", PURCHASE = "66666666-6666-4666-8666-666666666666";
const act = (body: Record<string, unknown>) => { resetApplyThrottle(); return post(body); };
// a business that paid its first invoice through Checkout, then a renewal its saved card couldn't pay: open, past due
async function pastDue() {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sess = fake.objects.get(s.id)!, sub = fake.objects.get(sess.subscription)!;
  fake.setCard(sub.customer, "decline");
  const draft = fake.renew(sub.id);
  const inv = fake.finalizeAndPay(draft.id);
  return { customer: sub.customer as string, sub: sub.id as string, inv };
}
const invRow = (inv: Record<string, any>, extra: Record<string, unknown> = {}) => ({ invoice_id: INVOICE, business_id: BIZ, stripe_invoice_id: inv.id, number: inv.number,
  amount_due_minor: inv.amount_due, currency: "usd", hosted_invoice_url: inv.hosted_invoice_url, livemode: false, ...extra });

Deno.test("Pay now: the open invoice's own PaymentIntent for Stripe's form; a double start gives the same intent and creates nothing", async () => {
  const { customer, sub, inv } = await pastDue();
  assertEquals(inv.status, "open");
  // the business's own address prefills Stripe's billing address fields; only plain strings pass, any country
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub },
    prefill: { line1: "100 King St W", city: "Toronto", state: "ON", postal_code: "M5H 3T4", country: "CA", extra: "<b>x</b>", line2: 5 } };
  const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals(r.body.billing_prefill, { line1: "100 King St W", city: "Toronto", state: "ON", postal_code: "M5H 3T4", country: "CA" });
  assertEquals([r.body.status, r.body.amount_minor, r.body.publishable_key, r.body.livemode], ["open", inv.amount_due, "pk_test_handle0001", false]);
  const pi = fake.objects.get(String(r.body.client_secret).split("_secret_")[0])!;
  assertEquals(pi.metadata.invoice, inv.id, "the invoice's own intent");
  const posts = fake.requests.filter((x) => x.method === "POST").length;
  const again = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  assertEquals(again.body.client_secret, r.body.client_secret, "a double start: the same intent");
  assertEquals(fake.requests.filter((x) => x.method === "POST").length, posts, "nothing was created at Stripe");
  assert(logged.every((l) => !l.includes(String(r.body.client_secret))), "never logged");
  // the customer pays in Stripe's form: Stripe has it, so a later start says processing (our record follows invoice.paid)
  fake.confirmIntent(pi.id);
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body, { status: "processing" });
});

Deno.test("Pay now refusals: another business's invoice, a paid one, a void one, payments off, keys in other modes", async () => {
  for (const code of ["NOT_FOUND", "ALREADY_PAID", "NOT_PAYABLE", "PAYMENTS_NOT_LIVE", "MFA_REQUIRED"]) {
    db = { checkout: null, payment: {}, invoiceStart: new Error(code) };
    const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
    assertEquals([r.status, r.body.code], [400, code], code);
    assert(!("client_secret" in r.body));
  }
  db = { checkout: null, payment: {}, invoice: new Error("NOT_FOUND") };
  assertEquals((await act({ action: "invoice_pay_status", invoice_id: INVOICE })).body.code, "NOT_FOUND");
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: "not-a-uuid" })).body.code, "INVALID_INPUT");
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", "pk_live_handle0001");
  db = { checkout: null, payment: {}, invoiceStart: { invoice_id: INVOICE } };
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body.code, "PAYMENTS_MISCONFIGURED");
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", env.STRIPE_PUBLISHABLE_KEY);
});

Deno.test("Pay now binding: another customer's invoice, a mode change, or a different amount never hands out a secret", async () => {
  const a = await pastDue(), other = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(other.inv), refs: { customer: a.customer, subscription: a.sub } };
  const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  assertEquals(r.status, 500);
  assert(!JSON.stringify(r.body).includes("secret"));
  db = { checkout: null, payment: {}, invoiceStart: invRow(a.inv, { livemode: true }), refs: { customer: a.customer, subscription: a.sub } };
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body.code, "NOT_PAYABLE");
  calls.length = 0;
  db = { checkout: null, payment: {}, invoiceStart: invRow(a.inv, { amount_due_minor: 1 }), refs: { customer: a.customer, subscription: a.sub } };
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body.code, "CHECKOUT_NOT_READY");
  assert(calls.some((c) => c.fn === "zella_platform_alert" && c.args.p_kind === "billing_invoice_amount"));
});

Deno.test("Pay now return: paid only from our records after the events are applied", async () => {
  db = { checkout: null, payment: {}, invoice: { invoice_id: INVOICE, status: "open", payable: true } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body, { invoice: { invoice_id: INVOICE, status: "open", payable: true } });
  db = { checkout: null, payment: {}, invoice: { invoice_id: INVOICE, status: "paid", payable: false } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body.invoice.status, "paid");
  // paid in Stripe's form: the card it used, brand, last 4 and the issuer as Stripe gives it
  const { customer, sub, inv } = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub } };
  const start = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  fake.confirmIntent(String(start.body.client_secret).split("_secret_")[0]);
  db = { ...db, invoice: { invoice_id: INVOICE, business_id: BIZ, stripe_invoice_id: inv.id, status: "paid" } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body.card, { brand: "visa", last4: "4242", issuer: "Test Bank" });
  db = { ...db, refs: { customer: "cus_someone_else", subscription: sub } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body.card, undefined, "another customer's invoice: no card");
});

Deno.test("the saved card: brand and last 4 from Stripe, or nothing", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sub = fake.objects.get(fake.objects.get(s.id)!.subscription)!;
  db = { checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id } };
  assertEquals((await act({ action: "card_summary", business_id: BIZ })).body, { card: { brand: "visa", last4: "4242", issuer: "Test Bank" } });
  db = { checkout: null, payment: {}, refs: { customer: "cus_someone_else", subscription: sub.id } };
  assertEquals((await act({ action: "card_summary", business_id: BIZ })).body, { card: null }, "another customer's subscription shows nothing");
  db = { checkout: null, payment: {}, refs: { customer: null, subscription: null } };
  assertEquals((await act({ action: "card_summary", business_id: BIZ })).body, { card: null });
});

Deno.test("Update card: Stripe's Customer Portal, card update only, back to the Payments page; none before a first payment", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sub = fake.objects.get(fake.objects.get(s.id)!.subscription)!;
  db = { checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id } };
  const r = await act({ action: "card_update_start", business_id: BIZ, idempotency_key: "card-key-0001" });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assert(String(r.body.url).startsWith("https://"));
  const req = fake.requests.findLast((x) => x.path === "/v1/billing_portal/sessions")!;
  assertEquals([req.key, req.body.customer, req.body.flow_data.type, req.body.return_url], ["portal:" + BIZ + ":card-key-0001", sub.customer, "payment_method_update",
    "https://app.example.test/app/settings/billing/invoices?card=updated"]);
  assertEquals((await act({ action: "card_update_start", business_id: BIZ, idempotency_key: "bad key" })).body.code, "INVALID_INPUT");
  db = { checkout: null, payment: {}, refs: { customer: null, subscription: null } };
  assertEquals((await act({ action: "card_update_start", business_id: BIZ, idempotency_key: "card-key-0002" })).body.code, "NO_CUSTOMER");
});

Deno.test("a pack the bank wants confirmed: the same PaymentIntent for Stripe's form; another purchase's intent is refused", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sub = fake.objects.get(fake.objects.get(s.id)!.subscription)!;
  fake.setCard(sub.customer, "auth");
  const failed = await stripe.post("/v1/payment_intents", { customer: sub.customer, amount: 2900, currency: "usd", off_session: true, confirm: true, metadata: { purchase_id: PURCHASE } }, `pack:${PURCHASE}`).catch((e) => e);
  const piId = failed.paymentIntent as string;
  assertEquals(fake.objects.get(piId)!.status, "requires_action");
  db = { checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id }, packAct: { purchase_id: PURCHASE, payment_intent: piId, price_cents: 2900 } };
  const r = await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE });
  assertEquals([r.status, r.body.status, r.body.amount_minor, r.body.client_secret], [200, "open", 2900, fake.objects.get(piId)!.client_secret]);
  const again = await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE });
  assertEquals(again.body.client_secret, r.body.client_secret, "the same intent: never a second charge");
  // B1: only after Stripe's checks is the purchase reopened, on THIS intent, in the key's mode (so it gets its link)
  assertEquals(db.reopened?.map((x) => [x.p_purchase_id, x.p_payment_intent, x.p_livemode]), [[PURCHASE, piId, false], [PURCHASE, piId, false]]);
  const reopenedBefore = db.reopened!.length;
  db = { ...db, packAct: { purchase_id: "77777777-7777-4777-8777-777777777777", payment_intent: piId, price_cents: 2900 } };
  assertEquals((await act({ action: "pack_act_start", business_id: BIZ, purchase_id: "77777777-7777-4777-8777-777777777777" })).status, 500, "another purchase's intent");
  db = { ...db, packAct: { purchase_id: PURCHASE, payment_intent: piId, price_cents: 9900 } };
  assertEquals((await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE })).status, 500, "a different amount");
  assertEquals(db.reopened!.length, reopenedBefore, "a binding failure reopens nothing (review 3)");
  fake.confirmIntent(piId);
  db = { ...db, packAct: { purchase_id: PURCHASE, payment_intent: piId, price_cents: 2900 } };
  assertEquals((await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE })).body, { status: "processing" });
  db = { ...db, pack: { purchase_id: PURCHASE, status: "granted", payment_intent: piId } };
  const granted = await act({ action: "pack_status", business_id: BIZ, purchase_id: PURCHASE });
  assertEquals([granted.body.purchase.status, granted.body.card], ["granted", { brand: "visa", last4: "4242", issuer: "Test Bank" }]);
  db = { ...db, pack: { purchase_id: PURCHASE, status: "pending", payment_intent: piId } };
  assertEquals((await act({ action: "pack_status", business_id: BIZ, purchase_id: PURCHASE })).body.card, undefined, "no card before it is granted");
});

// the fake was started at module load, before any test: stopping it is not a leak of this step

// Auto pay (owner decision, 27 Nov 2026: "Auto pay switch, on by default")
async function subscribed() {
  const s0 = await newSession();
  fake.completeCheckout(s0.id);
  const sub = fake.objects.get(fake.objects.get(s0.id)!.subscription)!;
  return sub;
}
const autopayDb = (sub: Record<string, any>, extra: Partial<AutoPay> = {}): Db => ({ checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id },
  autopay: { owner: true, card: true, sub: sub.id, on: true, desired: null, version: 0, keys: new Set(), outbox: [], applied: new Set(fake.events.map((e) => e.id)), ...extra } });

Deno.test("Auto pay off: the database records the choice, Stripe's subscription is updated with the stored body, and our record follows Stripe's event", async () => {
  const sub = await subscribed();
  db = autopayDb(sub);
  const r = await act({ action: "autopay_set", business_id: BIZ, on: false, idempotency_key: "autopay-key-0001" });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  const req = fake.requests.findLast((x) => x.path === `/v1/subscriptions/${sub.id}` && x.method === "POST")!;
  assertEquals([req.key, req.body.collection_method, req.body.days_until_due], [`autopay:${sub.id}:1:1`, "send_invoice", "3"]);
  assertEquals([fake.objects.get(sub.id)!.collection_method, fake.objects.get(sub.id)!.days_until_due], ["send_invoice", 3]);
  assertEquals(db.autopay!.on, false, "off only once customer.subscription.updated was applied");
  assertEquals(r.body.autopay, { on: false, desired: false, pending: false });
  // a double submit: the same key changes nothing at Stripe
  const posts = fake.requests.filter((x) => x.method === "POST").length;
  const again = await act({ action: "autopay_set", business_id: BIZ, on: false, idempotency_key: "autopay-key-0001" });
  assertEquals([again.status, fake.requests.filter((x) => x.method === "POST").length], [200, posts]);
});

Deno.test("Auto pay: our record never changes from the browser or our own command; until Stripe's event is applied it stays as it was", async () => {
  const sub = await subscribed();
  db = autopayDb(sub, { hold: true });
  const r = await act({ action: "autopay_set", business_id: BIZ, on: false, idempotency_key: "autopay-key-0002" });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals(fake.objects.get(sub.id)!.collection_method, "send_invoice", "Stripe has it");
  assertEquals(r.body.autopay, { on: true, desired: false, pending: true }, "still on in our record, the change pending");
});

Deno.test("Auto pay: another business's owner is refused, nothing reaches Stripe", async () => {
  const sub = await subscribed();
  db = autopayDb(sub, { owner: false });
  const posts = fake.requests.filter((x) => x.method === "POST").length;
  const r = await act({ action: "autopay_set", business_id: BIZ, on: false, idempotency_key: "autopay-key-0003" });
  assertEquals([r.status, r.body.code], [400, "NOT_ALLOWED"]);
  assertEquals(fake.requests.filter((x) => x.method === "POST").length, posts);
});

Deno.test("Auto pay on: refused with no usable saved card (checked with Stripe), and with bad input", async () => {
  const sub = await subscribed();
  db = autopayDb(sub, { on: false });
  fake.objects.get(sub.id)!.default_payment_method = null;
  const r = await act({ action: "autopay_set", business_id: BIZ, on: true, idempotency_key: "autopay-key-0004" });
  assertEquals([r.status, r.body.code], [409, "NO_SAVED_CARD"]);
  assertEquals(db.autopay!.outbox.length, 0, "nothing queued");
  assertEquals((await act({ action: "autopay_set", business_id: BIZ, on: "yes", idempotency_key: "autopay-key-0005" })).body.code, "INVALID_INPUT");
  assertEquals((await act({ action: "autopay_set", business_id: BIZ, on: true, idempotency_key: "bad key" })).body.code, "INVALID_INPUT");
});

Deno.test("Auto pay: an expired card isn't a usable card", async () => {
  const { usableCard } = await import("./index.ts");
  const now = new Date("2026-11-27T00:00:00Z");
  assertEquals(usableCard({ card: { exp_month: 11, exp_year: 2026 } }, now), true);
  assertEquals(usableCard({ card: { exp_month: 10, exp_year: 2026 } }, now), false);
  assertEquals(usableCard({ id: "pm_1" }, now), false);
  assertEquals(usableCard(null, now), false);
});

// ---- double payment protections (owner priority, 27 Nov 2026) ----
Deno.test("cases 3 and 11: Auto pay charges the invoice while the owner's tab confirms it: one success, one charge; the page then shows processing, never Pay", async () => {
  const { customer, sub, inv } = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub }, invoice: invRow(inv, { status: "open", payable: true }) };
  const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  const piId = String(r.body.client_secret).split("_secret_")[0];
  fake.setCard(customer, "ok");
  await stripe.post(`/v1/invoices/${inv.id}/pay`, {}, `retry:${inv.id}`);   // Stripe's retry with the saved card (Auto pay)
  fake.confirmIntent(piId);                                                // the owner's tab confirms the same intent
  assertEquals(fake.requests.length > 0, true);
  const charges = [...fake.objects.values()].filter((o) => o.object === "charge" && o.payment_intent === piId);
  assertEquals(charges.length, 1, "the invoice's one PaymentIntent succeeds once: one charge");
  const status = await act({ action: "invoice_pay_status", invoice_id: INVOICE });
  assertEquals(status.body.invoice.processing, true, "Stripe has it: the page confirms, no Pay");
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body, { status: "processing" });
});

Deno.test("case 10: two invoices in two tabs: each its own PaymentIntent and its own exact amount", async () => {
  const a = await pastDue(), b = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(a.inv), refs: { customer: a.customer, subscription: a.sub } };
  const ra = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  db = { checkout: null, payment: {}, invoiceStart: invRow(b.inv), refs: { customer: b.customer, subscription: b.sub } };
  const rb = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  const pa = fake.objects.get(String(ra.body.client_secret).split("_secret_")[0])!, pb = fake.objects.get(String(rb.body.client_secret).split("_secret_")[0])!;
  assert(pa.id !== pb.id);
  assertEquals([pa.metadata.invoice, pb.metadata.invoice, ra.body.amount_minor, rb.body.amount_minor], [a.inv.id, b.inv.id, a.inv.amount_due, b.inv.amount_due]);
});

// ---- review fixes (27 Nov 2026) ----
Deno.test("rate limited per person: over the limit answers 429 before anything else", async () => {
  db = { checkout: null, payment: {}, limited: true };
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "rate-key-0001" });
  assertEquals([r.status, r.body.code], [429, "TOO_MANY"]);
  assert(!calls.some((c) => c.fn === "zella_owner_billing_checkout_start"), "the owner function never ran");
});

Deno.test("applied in order: without the checkout migration nothing starts, and Zella Voice is told", async () => {
  db = { checkout: null, payment: {}, noMigration: true };
  const posts = fake.requests.filter((x) => x.method === "POST").length;
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "order-key-0001" });
  assertEquals([r.status, r.body.code], [503, "PAYMENTS_MISCONFIGURED"]);
  assertEquals(fake.requests.filter((x) => x.method === "POST").length, posts, "no session at Stripe");
  assert(calls.some((c) => c.fn === "zella_platform_alert" && c.args.p_kind === "billing_migration_missing"));
});

Deno.test("checkout: a session whose amount differs from ours is never shown, and Zella Voice is told", async () => {
  const sess = await newSession();
  db = { checkout: { ...openRow(sess.id), amount_minor: 1000 }, payment: {} };
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "amount-key-0001" });
  assertEquals([r.status, r.body.code, "client_secret" in r.body], [502, "CHECKOUT_NOT_READY", false]);
  assert(calls.some((c) => c.fn === "zella_platform_alert" && c.args.p_kind === "billing_checkout_amount"));
});

Deno.test("checkout: the owner's Auto pay choice is kept with the checkout on the server (M2)", async () => {
  const sess = await newSession();
  db = { checkout: openRow(sess.id), payment: {} };
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "autopay-ck-0001", autopay: false });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals(db.checkoutAutopay, [{ p_business_id: BIZ, p_checkout_id: CHECKOUT, p_on: false }]);
});

Deno.test("hosted fallback: a hosted session answers Stripe's own page; asking for hosted over an open in page session expires it at Stripe first", async () => {
  const hosted = await newSession({ ui_mode: "hosted", return_url: undefined, success_url: "https://app.example.test/welcome/setup?checkout=return&session_id={CHECKOUT_SESSION_ID}", cancel_url: "https://app.example.test/welcome/setup?checkout=cancel" });
  db = { checkout: openRow(hosted.id), payment: {} };
  const h = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "hosted-key-0001" });
  assertEquals([h.status, h.body.status, String(h.body.url).startsWith("https://checkout.stripe.com/"), "client_secret" in h.body], [200, "redirect", true, false]);
  const custom = await newSession();
  db = { checkout: openRow(custom.id), payment: {} };
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "hosted-key-0002", hosted: true });
  assertEquals([r.status, r.body.code], [409, "CHECKOUT_EXPIRED"]);
  assertEquals(fake.objects.get(custom.id)!.status, "expired", "one session at a time: the in page one is expired before a hosted one is made");
  const req = fake.requests.findLast((x) => x.path === `/v1/checkout/sessions/${custom.id}/expire`)!;
  assertEquals(req.key, `expire:${custom.id}`);
});
Deno.test({ name: "cleanup", sanitizeResources: false, sanitizeOps: false, fn: async () => { globalThis.fetch = realFetch; await fake.stop(); } });
