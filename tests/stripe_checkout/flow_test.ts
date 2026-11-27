// End to end, locally (tests/stripe_pipeline/flow.sh tests/stripe_checkout/flow_test.ts zella_owner_onboarding zella_stripe_checkout
// zella_stripe_embedded_checkout):
// plan saved -> the owner starts the in page checkout (ui_mode custom) through billing-api -> the fake Stripe completes it -> signed events ->
// billing-webhook stores them -> the worker fetches and binds -> payment confirmed -> the go live gate's payment check
// passes. Nothing reaches Stripe; the owner's calls run with the owner's own token against the isolated database.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { startFakeStripe } from "../stripe_fake/fake_stripe.ts";
import { stripeClient } from "../../web/supabase/functions/_shared/stripe.ts";
import { rpcClient, runWorkerOnce } from "../../web/supabase/functions/_shared/billingWorker.ts";
import { ANON_KEY, atPaymentStep, BACKEND, newBusiness, savePlan, SERVER_KEY, sql, tokenFor } from "../stripe_pipeline/helpers.ts";

const SECRET = "whsec_flow_test_only";
const fake = startFakeStripe();
for (const [k, v] of Object.entries({ STRIPE_WEBHOOK_SECRET: SECRET, STRIPE_SECRET_KEY: "sk_test_flow", ZELLA_SERVER_SECRET_KEY: SERVER_KEY,
  SUPABASE_URL: BACKEND, SUPABASE_ANON_KEY: ANON_KEY, STRIPE_API_BASE: fake.url, STRIPE_PUBLISHABLE_KEY: "pk_test_flow0001" })) Deno.env.set(k, v);
const webhook = (await import("../../web/supabase/functions/billing-webhook/index.ts")).handle;
const billingApi = (await import("../../web/supabase/functions/billing-api/index.ts")).handle;
const stripe = stripeClient({ secretKey: "sk_test_flow", baseUrl: fake.url });
const rpc = rpcClient(BACKEND, SERVER_KEY);
const hook = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen() {} }, webhook);
const hookUrl = `http://127.0.0.1:${(hook.addr as Deno.NetAddr).port}/`;
const api = async (token: string, body: Record<string, unknown>) => {
  const r = await billingApi(new Request("http://fn", { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(body) }));
  return { status: r.status, body: await r.json() };
};
export const ctx = { fake, stripe, rpc, hookUrl, api, SECRET };

Deno.test("plan saved -> Checkout -> signed webhook -> payment confirmed -> go live gate passes", async () => {
  const { business, owner } = await newBusiness("Journey One");
  await savePlan(business, 29900, 59900);
  await atPaymentStep(business);
  await sql(`insert into public.platform_settings (key, value) values ('app_base_url', '"https://app.example.test"') on conflict (key) do update set value = excluded.value;
             update public.platform_settings set value = 'true' where key = 'payments_live'`);
  const token = await tokenFor(owner);
  const other = await newBusiness("Journey Other");
  assertEquals((await api(await tokenFor(other.owner), { action: "checkout_start", business_id: business, idempotency_key: "journey-key-1" })).body.code, "NOT_ALLOWED");
  assertEquals((await api(await tokenFor(owner, "aal1"), { action: "checkout_start", business_id: business, idempotency_key: "journey-key-1" })).body.code, "MFA_REQUIRED");
  assertEquals((await api(ANON_KEY, { action: "checkout_start", business_id: business, idempotency_key: "journey-key-1" })).status, 401);

  const start = await api(token, { action: "checkout_start", business_id: business, idempotency_key: "journey-key-1", amount_minor: 1 });
  assertEquals(start.status, 200, JSON.stringify(start.body));
  assertEquals([start.body.status, start.body.publishable_key, "url" in start.body], ["open", "pk_test_flow0001", false]);   // Stripe's card fields in our page: no hosted page
  assert(/^cs_[A-Za-z0-9_]+_secret_/.test(String(start.body.client_secret)));
  assertEquals(start.body.amount_minor, 89800);   // the amount the browser sent (1) is ignored: it comes from the plan
  const posts = fake.requests.filter((r) => r.method === "POST").map((r) => r.key!.split(":")[0]);
  assertEquals(posts, ["customer", "product", "price", "price", "checkout"]);
  const sent = fake.requests.find((r) => r.method === "POST" && r.path === "/v1/checkout/sessions")!.body;
  assertEquals([sent.ui_mode, "redirect_on_completion" in sent, "success_url" in sent, "cancel_url" in sent], ["custom", false, false, false]);
  assertEquals(await sql(`select count(*) from public.billing_outbox where response::text like '%_secret_%'`), "0");   // never stored
  assertEquals((await api(token, { action: "checkout_start", business_id: business, idempotency_key: "journey-key-1" })).body.client_secret, start.body.client_secret);   // double click
  assertEquals((await api(token, { action: "checkout_start", business_id: business, idempotency_key: "journey-key-2" })).body.client_secret, start.body.client_secret);   // second tab
  assertEquals(fake.requests.filter((r) => r.method === "POST" && r.path === "/v1/checkout/sessions").length, 1);   // one session, never a second

  const session = await sql(`select stripe_session_id from public.billing_checkouts where business_id = '${business}'`);
  fake.completeCheckout(session);
  assert((await fake.deliver(hookUrl, SECRET)).every((s) => s === 200));
  const back = await api(token, { action: "checkout_return", business_id: business });
  assertEquals(back.body.payment.status, "confirmed", JSON.stringify(back.body));
  assertEquals(back.body.card, { brand: "visa", last4: "4242", issuer: "Test Bank" });   // only what Stripe returns about the saved card
  assertEquals(await sql(`select status from public.subscriptions where business_id = '${business}'`), "active");
  assertEquals(await sql(`select (x ->> 'ok') from jsonb_array_elements(public.zella_activation_checks('${business}') -> 'checks') x where x ->> 'key' = 'payment'`), "true");
  assertEquals(await sql(`select amount_minor || ' ' || (metadata ->> 'bound') from public.payments where business_id = '${business}'`), "89800 true");
  assertEquals(await sql(`select count(*) from public.billing_quarantine`), "0");
  // a redelivery of every event is answered 200 (Stripe would resend anything else) and changes nothing
  assert((await fake.deliver(hookUrl, SECRET, { only: fake.events })).every((s) => s === 200));
  await runWorkerOnce(rpc, stripe);
  assertEquals(await sql(`select count(*) || ' ' || sum(amount_minor) from public.payments where business_id = '${business}'`), "1 89800");
});

Deno.test("cleanup", async () => { await hook.shutdown(); await fake.stop(); });
