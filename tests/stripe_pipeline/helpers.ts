// Shared by the lane F flow tests: psql on the ISOLATED test database only (zlf_ names, the local socket).
const DB = Deno.env.get("ZF_DB") ?? "";
if (!/^zlf_t_[a-z0-9_]+$/.test(DB)) throw new Error("REFUSED: the flow tests run only on a zlf_t_ test database");
export const BACKEND = Deno.env.get("ZF_BACKEND") ?? "http://127.0.0.1:54336";
export const SERVER_KEY = "sb_secret_local_test_only";   // tests/browser/local-backend.mjs's test key
export async function sql(text: string): Promise<string> {
  const out = await new Deno.Command("psql", { args: ["-h", "/var/lib/postgresql/zella-sec", "-p", "55433", "-U", "postgres", "-d", DB, "-qtAX", "-v", "ON_ERROR_STOP=1", "-c", text] }).output();
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
  return new TextDecoder().decode(out.stdout).trim();
}
export async function newBusiness(name: string): Promise<{ business: string; owner: string }> {
  const r = await sql(`with b as (insert into public.businesses (name) values ('${name}') returning id),
    u as (insert into auth.users (id, email, aud, role, raw_app_meta_data, raw_user_meta_data) values (gen_random_uuid(), '${name.toLowerCase().replace(/\W/g, "")}' || substr(md5(random()::text),1,6) || '@example.test', 'authenticated', 'authenticated', '{}', '{}') returning id),
    m as (insert into public.business_members (business_id, user_id, role, status) select b.id, u.id, 'owner', 'active' from b, u returning business_id, user_id)
    select business_id || ' ' || user_id from m`);
  const [business, owner] = r.split(" ");
  return { business, owner };
}
export async function savePlan(business: string, price: number, setup: number, opts: { interval?: string; trial?: boolean; version?: number } = {}): Promise<string> {
  return sql(`insert into public.business_plans (business_id, version, tier, billing_interval, price_cents, setup_fee_cents, currency, minutes, texts, emails, team_seats, phone_numbers, locations, languages, trial_enabled, overage_cents_per_minute, contact_limits, estimate, acknowledged_warnings, effective_from, idempotency_key, values_hash)
    values ('${business}', ${opts.version ?? 1}, 'base', '${opts.interval ?? "monthly"}', ${price}, ${setup}, 'USD', 500, 200, 200, 3, 1, 1, array['en'], ${opts.trial ?? false}, 20, '{}', '{}', '[]', now() - interval '1 day', 'plan-key-' || substr(md5(random()::text),1,10), md5(random()::text)) returning id`);
}
// a sign in token for tests/browser/local-backend.mjs (its local test secret; HS256, like Supabase Auth)
const LOCAL_SECRET = "zella-local-test-secret-not-for-production";
const b64u = (b: Uint8Array | string) => btoa(typeof b === "string" ? b : String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export async function tokenFor(user: string, aal = "aal2"): Promise<string> {
  const head = b64u(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64u(JSON.stringify({ sub: user, role: "authenticated", aal, exp: Math.floor(Date.now() / 1000) + 3600 }));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(LOCAL_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return `${head}.${body}.${b64u(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${head}.${body}`))))}`;
}
export const ANON_KEY = "sb_publishable_local_test_only";
// puts a business's owner onboarding on step 6 (identity done, plan accepted)
export async function atPaymentStep(business: string) {
  await sql(`insert into public.owner_onboarding (business_id, current_step, plan_accepted_version, plan_accepted_at) values ('${business}', 'payment', (select max(version) from public.business_plans where business_id = '${business}'), now());
    insert into public.owner_onboarding_steps (business_id, step, reached_at, completed_at) select '${business}', k, now(), now() from unnest(array['welcome','security','details','identity','plan']) k;
    insert into public.owner_onboarding_steps (business_id, step, reached_at) values ('${business}', 'payment', now())`);
}
