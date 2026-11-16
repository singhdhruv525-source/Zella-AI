// The whole Stripe journey end to end, locally, through the fake Stripe (never Stripe, never production):
//   tests/stripe_pipeline/flow.sh tests/stripe_e2e/journey_test.ts zella_owner_onboarding zella_stripe_checkout \
//     zella_stripe_renewals zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices \
//     zella_stripe_disputes zella_stripe_emails zella_stripe_reconcile
// plan saved -> Checkout (billing-api, the owner's own token) -> signed webhook -> payment confirmed -> go live gate
// passes; then a renewal, a failed payment and the 5 day pause, recovery, a pack on the saved card, a refund approved by
// the Zella Voice owner, invoice rows, billing emails held in the outbox, and a reconciliation with no differences.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { startFakeStripe } from "../stripe_fake/fake_stripe.ts";
import { stripeClient } from "../../web/supabase/functions/_shared/stripe.ts";
import { rpcClient, runWorkerOnce } from "../../web/supabase/functions/_shared/billingWorker.ts";
import { ANON_KEY, atPaymentStep, BACKEND, newBusiness, savePlan, SERVER_KEY, sql, tokenFor } from "../stripe_pipeline/helpers.ts";

const SECRET = "whsec_journey_test_only";
const fake = startFakeStripe();
for (const [k, v] of Object.entries({ STRIPE_WEBHOOK_SECRET: SECRET, STRIPE_SECRET_KEY: "sk_test_journey", ZELLA_SERVER_SECRET_KEY: SERVER_KEY,
  SUPABASE_URL: BACKEND, SUPABASE_ANON_KEY: ANON_KEY, STRIPE_API_BASE: fake.url })) Deno.env.set(k, v);
const webhook = (await import("../../web/supabase/functions/billing-webhook/index.ts")).handle;
const billingApi = (await import("../../web/supabase/functions/billing-api/index.ts")).handle;
const stripe = stripeClient({ secretKey: "sk_test_journey", baseUrl: fake.url });
const rpc = rpcClient(BACKEND, SERVER_KEY);
const hook = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen() {} }, webhook);
const hookUrl = `http://127.0.0.1:${(hook.addr as Deno.NetAddr).port}/`;
const api = async (token: string, body: Record<string, unknown>) => {
  const r = await billingApi(new Request("http://fn", { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(body) }));
  return { status: r.status, body: await r.json() };
};
const asUser = async (token: string, fn: string, args: Record<string, unknown>) => {
  const r = await fetch(`${BACKEND}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  return { status: r.status, body: await r.json() };
};
// Stripe sends events; the worker runs (it would every minute); repeat a few times so waiting events catch up
async function settle() {
  const s = await fake.deliver(hookUrl, SECRET);
  assert(s.every((x) => x === 200), `webhook answered ${s}`);
  for (let i = 0; i < 3; i++) { await sql("update public.billing_events set next_attempt_at = now() where status = 'received'"); await runWorkerOnce(rpc, stripe); }
}

Deno.test("the whole journey through the fake Stripe", async () => {
  const { business, owner } = await newBusiness("Journey Salon");
  await savePlan(business, 29900, 59900);
  await atPaymentStep(business);
  await sql(`insert into public.platform_settings (key, value) values ('app_base_url', '"https://app.example.test"') on conflict (key) do update set value = excluded.value;
             update public.platform_settings set value = 'true' where key = 'payments_live'`);
  const token = await tokenFor(owner);

  // 1. Checkout -> signed webhook -> payment confirmed -> the go live gate's payment check passes
  const start = await api(token, { action: "checkout_start", business_id: business, idempotency_key: "journey-key-0001" });
  assertEquals(start.status, 200, JSON.stringify(start.body));
  fake.completeCheckout(await sql(`select stripe_session_id from public.billing_checkouts where business_id = '${business}'`));
  await settle();
  assertEquals((await api(token, { action: "checkout_return", business_id: business })).body.payment.status, "confirmed");
  assertEquals(await sql(`select (x ->> 'ok') from jsonb_array_elements(public.zella_activation_checks('${business}') -> 'checks') x where x ->> 'key' = 'payment'`), "true");
  const sub = await sql(`select external_subscription_id from public.subscriptions where business_id = '${business}'`);
  const customer = await sql(`select stripe_id from public.billing_stripe_links where business_id = '${business}' and kind = 'customer'`);
  assertEquals(await sql(`select kind || ' ' || status || ' ' || amount_paid_minor from public.billing_invoices where business_id = '${business}'`), "first paid 89800");

  // 2. A renewal: the draft is recorded, then paid; the period moves on
  const firstEnd = await sql(`select current_period_end from public.subscriptions where business_id = '${business}'`);
  const renewal = fake.renew(sub);
  await settle();
  assertEquals(await sql(`select status from public.billing_invoices where stripe_invoice_id = '${renewal.id}'`), "draft");
  fake.finalizeAndPay(renewal.id);
  await settle();
  assertEquals(await sql(`select status || ' ' || (current_period_start = '${firstEnd}'::timestamptz) from public.subscriptions where business_id = '${business}'`), "active true");
  assertEquals(await sql(`select status from public.billing_invoices where stripe_invoice_id = '${renewal.id}'`), "paid");

  // 3. A failed payment: past due, then 5 days later paused (calls would go to the fallback number), then paid: back on
  fake.setCard(customer, "decline");
  const failing = fake.renew(sub);
  fake.finalizeAndPay(failing.id);
  await settle();
  assertEquals(await sql(`select status from public.subscriptions where business_id = '${business}'`), "past_due");
  await sql(`update public.subscriptions set past_due_since = now() - interval '6 days' where business_id = '${business}'`);
  await runWorkerOnce(rpc, stripe);
  assertEquals(await sql(`select status from public.subscriptions where business_id = '${business}'`), "paused_nonpayment");
  assertEquals(await sql(`select public.zella_call_entitlement_check('${business}') ->> 'status'`), "inactive");
  fake.setCard(customer, "ok");
  fake.finalizeAndPay(failing.id);
  await settle();
  assertEquals(await sql(`select status from public.subscriptions where business_id = '${business}'`), "active");

  // 4. A pack on the saved card
  const pack = await api(token, { action: "pack_buy", business_id: business, pack_code: "minutes_100", idempotency_key: "journey-pack-0001", amount: 1 });
  assertEquals(pack.status, 200, JSON.stringify(pack.body));
  await settle();
  assertEquals(await sql(`select status from public.pack_purchases where id = '${pack.body.purchase_id}'`), "granted");
  assertEquals(await sql(`select granted::int from public.allowance_buckets where pack_purchase_id = '${pack.body.purchase_id}'`), "100");

  // 5. A refund: the owner asks (30 day guarantee), the Zella Voice owner approves, Stripe refunds, it is recorded
  const opts = await api(token, { action: "refund_options", business_id: business });
  const guarantee = opts.body.options.find((o: Record<string, unknown>) => o.kind === "guarantee");
  assertEquals([guarantee.eligible, guarantee.amount_minor], [true, 29900]);
  const asked = await api(token, { action: "refund_request", business_id: business, kind: "guarantee", payment_id: guarantee.payment_id, idempotency_key: "journey-refund-01" });
  assertEquals(asked.status, 200, JSON.stringify(asked.body));
  const admin = "f9000000-0000-0000-0000-000000000001";
  await sql(`insert into auth.users (id, email) values ('${admin}', 'owner@journey.test'); insert into public.platform_admins (user_id, role) values ('${admin}', 'zella_owner');
             insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status) values (gen_random_uuid(), '${admin}', 'Test', 'totp', 'verified')`);
  const decided = await asUser(await tokenFor(admin), "zella_admin_refund_decide", { p_refund_id: asked.body.refund_id, p_approve: true, p_reason: "Asked within the guarantee" });
  assertEquals(decided.body.status, "sending", JSON.stringify(decided.body));
  await runWorkerOnce(rpc, stripe);   // sends the refund to Stripe
  await settle();                     // refund.created comes back
  assertEquals(await sql(`select status from public.billing_refunds where id = '${asked.body.refund_id}'`), "processed");

  // 6. Invoices, emails held, nothing quarantined, the ledger balances, reconciliation finds no difference
  assert(Number(await sql(`select count(*) from public.billing_invoices where business_id = '${business}'`)) >= 3);
  assertEquals(await sql(`select count(*) from public.billing_quarantine`), "0");
  assertEquals(await sql(`select coalesce(sum(amount_minor), 0) from public.money_ledger`), "0");
  // billing emails: the welcome receipt is queued; notices missing a fact (the card's last 4 digits, an owner decision)
  // are held, never filled with a made up value
  assertEquals(await sql(`select count(*) from public.platform_emails where business_id = '${business}' and code = 'A1'`), "1");
  assert(Number(await sql(`select count(*) from public.billing_email_intents where status = 'held' and error like 'MISSING_FIELD:%:card'`)) >= 1);
  assertEquals(await sql(`select count(*) from public.platform_emails where status = 'sent'`), "0");
  await sql(`delete from public.billing_reconcile_runs`);
  await runWorkerOnce(rpc, stripe);
  assertEquals(await sql(`select coalesce(sum(jsonb_array_length(mismatches)), 0) from public.billing_reconcile_runs`), "0");
  assertEquals(await sql(`select count(*) from public.billing_reconcile_runs where kind = 'objects'`), "1");
  // every Stripe call was to the fake, with a key on every POST
  assert(fake.requests.every((r) => r.method === "GET" || !!r.key));
});

Deno.test("cleanup", async () => { await hook.shutdown(); await fake.stop(); });
