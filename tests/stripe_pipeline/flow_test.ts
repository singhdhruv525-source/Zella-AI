// The event pipeline end to end, locally (run by flow.sh): signature -> stored once -> claimed in order -> object
// fetched from the fake Stripe -> applied or quarantined. Nothing reaches Stripe.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { startFakeStripe } from "../stripe_fake/fake_stripe.ts";
import { stripeClient } from "../../web/supabase/functions/_shared/stripe.ts";
import { rpcClient, runWorkerOnce } from "../../web/supabase/functions/_shared/billingWorker.ts";
import { BACKEND, newBusiness, SERVER_KEY, sql } from "./helpers.ts";

const SECRET = "whsec_flow_test_only";
Deno.env.set("STRIPE_WEBHOOK_SECRET", SECRET);
Deno.env.set("STRIPE_SECRET_KEY", "sk_test_flow");
Deno.env.set("ZELLA_SERVER_SECRET_KEY", SERVER_KEY);
Deno.env.set("SUPABASE_URL", BACKEND);
const { handle } = await import("../../web/supabase/functions/billing-webhook/index.ts");

Deno.test("signed events are stored once, fetched, applied in order, and unbound money is quarantined", async () => {
  const fake = startFakeStripe();
  const hook = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen() {} }, handle);
  const hookUrl = `http://127.0.0.1:${(hook.addr as Deno.NetAddr).port}/`;
  try {
    const stripe = stripeClient({ secretKey: "sk_test_flow", baseUrl: fake.url });
    const rpc = rpcClient(BACKEND, SERVER_KEY);
    const { business } = await newBusiness("Flow One");
    await sql("update public.platform_settings set value = 'true' where key = 'payments_live'");
    const cus = await stripe.post("/v1/customers", { metadata: { business_id: business } }, `customer:${business}`);
    await rpc("zella_stripe_link_add", { p_stripe_id: cus.id, p_kind: "customer", p_business_id: business, p_livemode: false });
    const prod = await stripe.post("/v1/products", { name: "Plan" }, "product:flow");
    const price = await stripe.post("/v1/prices", { product: prod.id, unit_amount: 29900, currency: "usd", recurring: { interval: "month" } }, "price:flow");
    const cs = await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, line_items: [{ price: price.id, quantity: 1 }] }, "checkout:flow");
    await sql(`insert into public.subscriptions (business_id, status, billing_interval, provider) values ('${business}', 'pending_payment', 'monthly', 'stripe')`);
    fake.completeCheckout(cs.id);

    // tampered and stale deliveries are refused before anything is stored
    const first = fake.events[0];
    assertEquals(await fake.deliver(hookUrl, SECRET, { only: [first], tamper: true }), [400]);
    assertEquals(await fake.deliver(hookUrl, SECRET, { only: [first], at: Math.floor(Date.now() / 1000) - 600 }), [400]);
    assertEquals(await fake.deliver(hookUrl, "whsec_wrong", { only: [first] }), [400]);
    assertEquals(await sql("select count(*) from public.billing_events"), "0");
    // delivered in reverse (Stripe doesn't promise order), then every event again (a redelivery)
    assert((await fake.deliver(hookUrl, SECRET, { only: [...fake.events].reverse() })).every((s) => s === 200));
    const stored = await sql("select count(*) from public.billing_events where pipeline = 'stripe_v2'");
    assert((await fake.deliver(hookUrl, SECRET, { only: fake.events })).every((s) => s === 200));
    assertEquals(await sql("select count(*) from public.billing_events where pipeline = 'stripe_v2'"), stored);

    // the subscription is not linked to the business yet: its events wait, nothing is granted
    await runWorkerOnce(rpc, stripe);
    assertEquals(await sql("select count(*) from public.payments"), "0");
    assert(Number(await sql("select count(*) from public.billing_events where status = 'received' and error like 'WAITING:%'")) >= 1);
    // linked (what checkout.session.completed does from our own stored session): applied, oldest first
    const sub = fake.events.find((e) => e.type === "customer.subscription.created")!.data.object.id;
    await rpc("zella_stripe_link_add", { p_stripe_id: sub, p_kind: "subscription", p_business_id: business, p_livemode: false });
    for (let i = 0; i < 6; i++) { await sql("update public.billing_events set next_attempt_at = now() where status = 'received'"); await runWorkerOnce(rpc, stripe); }
    assertEquals(await sql("select status from public.billing_events where type = 'customer.subscription.created'"), "processed");
    // this migration grants nothing for a first payment yet: the paid invoice is quarantined, not guessed
    assertEquals(await sql("select reason from public.billing_quarantine q join public.billing_events e on e.id = q.event_id where e.type = 'invoice.paid'"), "billing reason subscription_create is not handled");
    assertEquals(await sql("select count(*) from public.payments"), "0");
    assertEquals(await sql("select status from public.subscriptions where business_id = '" + business + "'"), "pending_payment");
    // every object was fetched from the fake with our key before it was applied
    assert(fake.requests.some((r) => r.method === "GET" && r.path.startsWith("/v1/invoices/")));
  } finally { await hook.shutdown(); await fake.stop(); }
});
