// Upgrade and downgrade end to end through the fake Stripe (never Stripe):
//   tests/stripe_pipeline/flow.sh tests/stripe_plan_change/flow_test.ts zella_owner_onboarding zella_stripe_checkout zella_stripe_renewals \
//     zella_stripe_packs zella_stripe_refunds zella_stripe_cancel zella_stripe_invoices zella_stripe_disputes zella_stripe_emails \
//     zella_stripe_reconcile zella_stripe_plan_change
import { assert, assertEquals } from "jsr:@std/assert@1";
import { startFakeStripe } from "../stripe_fake/fake_stripe.ts";
import { stripeClient } from "../../web/supabase/functions/_shared/stripe.ts";
import { rpcClient, runWorkerOnce } from "../../web/supabase/functions/_shared/billingWorker.ts";
import { ANON_KEY, atPaymentStep, BACKEND, newBusiness, savePlan, SERVER_KEY, sql, tokenFor } from "../stripe_pipeline/helpers.ts";

const SECRET = "whsec_plan_change_test_only";
const fake = startFakeStripe();
for (const [k, v] of Object.entries({ STRIPE_WEBHOOK_SECRET: SECRET, STRIPE_SECRET_KEY: "sk_test_change", ZELLA_SERVER_SECRET_KEY: SERVER_KEY,
  SUPABASE_URL: BACKEND, SUPABASE_ANON_KEY: ANON_KEY, STRIPE_API_BASE: fake.url })) Deno.env.set(k, v);
const webhook = (await import("../../web/supabase/functions/billing-webhook/index.ts")).handle;
const billingApi = (await import("../../web/supabase/functions/billing-api/index.ts")).handle;
const stripe = stripeClient({ secretKey: "sk_test_change", baseUrl: fake.url });
const rpc = rpcClient(BACKEND, SERVER_KEY);
const hook = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen() {} }, webhook);
const hookUrl = `http://127.0.0.1:${(hook.addr as Deno.NetAddr).port}/`;
const asUser = async (token: string, fn: string, args: Record<string, unknown>) => {
  const r = await fetch(`${BACKEND}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  return { status: r.status, body: await r.json() };
};
async function settle() {
  assert((await fake.deliver(hookUrl, SECRET)).every((x) => x === 200));
  for (let i = 0; i < 3; i++) { await sql("update public.billing_events set next_attempt_at = now() where status = 'received'"); await runWorkerOnce(rpc, stripe); }
}

Deno.test("upgrade: Stripe's preview, the owner confirms, paid at the preview, extra allowance; downgrade: scheduled for the period end", async () => {
  const { business, owner } = await newBusiness("Change Salon");
  await savePlan(business, 29900, 0);
  await atPaymentStep(business);
  await sql(`insert into public.platform_settings (key, value) values ('app_base_url', '"https://app.example.test"') on conflict (key) do update set value = excluded.value;
             update public.platform_settings set value = 'true' where key = 'payments_live'`);
  const token = await tokenFor(owner);
  const r = await billingApi(new Request("http://fn", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ action: "checkout_start", business_id: business, idempotency_key: "change-key-0001" }) }));
  assertEquals(r.status, 200);
  fake.completeCheckout(await sql(`select stripe_session_id from public.billing_checkouts where business_id = '${business}'`));
  await settle();
  assertEquals(await sql(`select status || ' ' || (metadata ->> 'stripe_item' is not null) from public.subscriptions where business_id = '${business}'`), "active true");

  const admin = "f9100000-0000-0000-0000-000000000001", billing = "f9100000-0000-0000-0000-000000000002";
  await sql(`insert into auth.users (id, email) values ('${admin}', 'owner@change.test'), ('${billing}', 'ro@change.test');
             insert into public.platform_admins (user_id, role) values ('${admin}', 'zella_owner'), ('${billing}', 'read_only_admin');
             insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status) select gen_random_uuid(), id, 'Test', 'totp', 'verified' from auth.users where id in ('${admin}', '${billing}')`);
  const v2 = await savePlan(business, 59900, 0, { version: 2, minutes: 1000 });
  assertEquals((await asUser(await tokenFor(billing), "zella_admin_plan_change_start", { p_business_id: business, p_plan_id: v2, p_reason: "More minutes needed" })).body.message, "NOT_ALLOWED");
  const started = await asUser(await tokenFor(admin), "zella_admin_plan_change_start", { p_business_id: business, p_plan_id: v2, p_reason: "More minutes needed" });
  assertEquals(started.body.direction, "up", JSON.stringify(started.body));
  await runWorkerOnce(rpc, stripe);   // the new Price, then Stripe's preview
  const seen = (await asUser(token, "zella_owner_plan_change", { p_business_id: business })).body;
  assertEquals(seen.status, "previewed", JSON.stringify(seen));
  assert(seen.amount_today_minor > 0 && seen.amount_today_minor <= 30000, `prorated ${seen.amount_today_minor}`);
  const other = await newBusiness("Change Other");
  assertEquals((await asUser(await tokenFor(other.owner), "zella_owner_plan_change_confirm", { p_business_id: business, p_change_id: started.body.change_id })).body.message, "NOT_ALLOWED");
  assertEquals((await asUser(token, "zella_owner_plan_change_confirm", { p_business_id: business, p_change_id: started.body.change_id })).body.status, "confirmed");
  const before = Number(await sql(`select granted from public.allowance_buckets k join public.billing_periods p on p.id = k.period_id where k.business_id = '${business}' and k.resource = 'minutes' and k.kind = 'plan' order by p.period_start desc limit 1`));
  await runWorkerOnce(rpc, stripe);   // the subscription update with the same proration time
  const update = fake.requests.find((x) => x.method === "POST" && x.key === `upgrade:${started.body.change_id}`)!;
  const preview = fake.requests.find((x) => x.path === "/v1/invoices/create_preview")!;
  assertEquals(update.body.proration_date, preview.body.subscription_details.proration_date);
  assertEquals(update.body.payment_behavior, "pending_if_incomplete");
  await settle();                     // invoice.paid, billing_reason subscription_update
  assertEquals(await sql(`select status from public.billing_plan_changes where id = '${started.body.change_id}'`), "applied");
  assertEquals(await sql(`select amount_paid_minor = ${seen.amount_today_minor} from public.billing_invoices where kind = 'upgrade' and business_id = '${business}'`), "t");
  const after = Number(await sql(`select granted from public.allowance_buckets k join public.billing_periods p on p.id = k.period_id where k.business_id = '${business}' and k.resource = 'minutes' and k.kind = 'plan' order by p.period_start desc limit 1`));
  assert(after > before && after - before <= 500, `extra minutes ${after - before}`);

  // downgrade: a schedule, the lower Price from the period end, nothing charged now
  const v3 = await savePlan(business, 19900, 0, { version: 3 });
  const down = await asUser(await tokenFor(admin), "zella_admin_plan_change_start", { p_business_id: business, p_plan_id: v3, p_reason: "Fewer calls now" });
  assertEquals(down.body.direction, "down", JSON.stringify(down.body));
  await runWorkerOnce(rpc, stripe); await runWorkerOnce(rpc, stripe);
  assertEquals(await sql(`select status from public.billing_plan_changes where id = '${down.body.change_id}'`), "scheduled");
  const sched = [...fake.objects.values()].find((o) => o.object === "subscription_schedule")!;
  assertEquals(sched.phases.length, 2);
  assertEquals(await sql(`select count(*) from public.billing_quarantine`), "0");
  assertEquals(await sql(`select coalesce(sum(amount_minor), 0) from public.money_ledger`), "0");
});

Deno.test("cleanup", async () => { await hook.shutdown(); await fake.stop(); });
