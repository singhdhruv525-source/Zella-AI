// billing-api, checkout_start and checkout_return for Stripe Embedded Checkout (owner, 27 Nov 2026), locally: the
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
const { handle } = await import("./index.ts");

// the database stand in: what the owner functions and the server functions answer
type Answer = Record<string, unknown> | Error | null;
type Db = { checkout: Record<string, unknown> | null; payment: Record<string, unknown>; start?: Record<string, unknown> | Error;
  invoice?: Answer; invoiceStart?: Answer; refs?: Answer; packAct?: Answer; pack?: Answer };
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
  if (fn === "zella_billing_checkout_session") return json(db.checkout);
  const answer = (a: Answer | undefined) => a instanceof Error ? json({ message: a.message }, 400) : json(a ?? null);
  if (fn === "zella_owner_invoice_pay_status") return answer(db.invoice);
  if (fn === "zella_owner_invoice_pay_start") return answer(db.invoiceStart);
  if (fn === "zella_billing_stripe_refs") return answer(db.refs);
  if (fn === "zella_owner_billing_access") return json({ business_id: BIZ, payments_live: true, app_base_url: "https://app.example.test" });
  if (fn === "zella_owner_pack_act_start") return answer(db.packAct);
  if (fn === "zella_owner_pack_status") return answer(db.pack);
  if (fn === "zella_owner_onboarding_payment_status") return json(db.payment);
  if (fn === "zella_billing_events_claim" || fn.startsWith("zella_billing_")) return json(null);
  if (fn === "zella_platform_alert") return json(null);
  return json(null);
};

async function newSession(extra: Record<string, unknown> = {}) {
  const cus = await stripe.post("/v1/customers", { metadata: { business_id: BIZ } }, `customer:${crypto.randomUUID()}`);
  const prod = await stripe.post("/v1/products", { name: "Zella Voice plan" }, `product:${crypto.randomUUID()}`);
  const price = await stripe.post("/v1/prices", { product: prod.id, currency: "usd", unit_amount: 29900, recurring: { interval: "month" } }, `price:${crypto.randomUUID()}`);
  return await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, client_reference_id: CHECKOUT, ui_mode: "embedded",
    return_url: "https://app.example.test/welcome/setup?checkout=return&session_id={CHECKOUT_SESSION_ID}", redirect_on_completion: "if_required",
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

Deno.test("checkout_start returns the embedded session's client secret, the publishable key and the database's amount", async () => {
  const s = await newSession();
  db = { checkout: openRow(s.id), payment: { status: "waiting" } };
  const r = await start();
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals([r.body.status, r.body.client_secret, r.body.publishable_key, r.body.livemode], ["open", s.client_secret, "pk_test_handle0001", false]);
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
  assertEquals(calls.map((c) => c.fn), ["zella_platform_alert"]);   // the owner's start was never called
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

Deno.test("a hosted session (made before this change) is not passed off as an embedded one", async () => {
  const cus = await stripe.post("/v1/customers", {}, `customer:${crypto.randomUUID()}`);
  const prod = await stripe.post("/v1/products", { name: "x" }, `product:${crypto.randomUUID()}`);
  const price = await stripe.post("/v1/prices", { product: prod.id, currency: "usd", unit_amount: 100, recurring: { interval: "month" } }, `price:${crypto.randomUUID()}`);
  const h = await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, client_reference_id: CHECKOUT, success_url: "https://app.example.test/ok",
    line_items: [{ price: price.id, quantity: 1 }], metadata: { business_id: BIZ } }, `checkout:${crypto.randomUUID()}`);
  db = { checkout: openRow(h.id), payment: { status: "waiting" } };
  assertEquals((await start()).body.code, "CHECKOUT_NOT_READY");
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
const act = (body: Record<string, unknown>) => post(body);
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
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub } };
  const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  assertEquals(r.status, 200, JSON.stringify(r.body));
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
    `https://app.example.test/pay?business=${BIZ}&card=updated`]);
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
  db = { ...db, packAct: { purchase_id: "77777777-7777-4777-8777-777777777777", payment_intent: piId, price_cents: 2900 } };
  assertEquals((await act({ action: "pack_act_start", business_id: BIZ, purchase_id: "77777777-7777-4777-8777-777777777777" })).status, 500, "another purchase's intent");
  db = { ...db, packAct: { purchase_id: PURCHASE, payment_intent: piId, price_cents: 9900 } };
  assertEquals((await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE })).status, 500, "a different amount");
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
Deno.test({ name: "cleanup", sanitizeResources: false, sanitizeOps: false, fn: async () => { globalThis.fetch = realFetch; await fake.stop(); } });
