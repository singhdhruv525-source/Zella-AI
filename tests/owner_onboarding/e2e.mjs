// End to end run of the owner onboarding journey through the real calls, in order, on the local stand in backend
// (tests/browser/local-backend.mjs) and the real edge function code under Deno, against an ISOLATED copy of the
// production schema. Test people and businesses only; nothing is sent (no email, text, call or provider request).
//
//   node tests/owner_onboarding/e2e.mjs        (env: ZPG_HOST, ZPG_PORT, TEMPLATE=zprod3; ports 54402 to 54406)
//
// The owner signs in, sets up the authenticator (the stand in's code is 123456), checks the four sections (asks for one
// change, which Zella Voice marks done), finishes later and comes back at the same step, uploads both identity
// documents through owner-onboarding (rejected twice by Zella Voice in Verification through owner-provision-business:
// try again, then manual review; then approved), accepts the plan the admin saved, waits at payment, and goes live
// only once a payment is confirmed. Another business's owner, a staff member and anonymous are refused throughout.
import { execFileSync, spawn } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { PSQL_ENV, requireIsolated } = require("../browser/isolated-db.cjs");
const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const HOST = process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", PGPORT = process.env.ZPG_PORT ?? "55433";
const DB = "zonb_e2e", TEMPLATE = process.env.TEMPLATE ?? "zprod3";
const PORTS = { backend: 54402, "owner-onboarding": 54403, "identity-webhook": 54404, "owner-provision-business": 54405 };
const BASE = `http://127.0.0.1:${PORTS.backend}`;
const ANON = "sb_publishable_local_test_only", SERVER = "sb_secret_local_test_only", PASSWORD = "Test-pass-1";

requireIsolated(HOST, PGPORT, DB);
const psql = (db, sql) => execFileSync("psql", ["-h", HOST, "-p", PGPORT, "-U", "postgres", "-d", db, "-qtAX", "-v", "ON_ERROR_STOP=1", "-c", sql], { env: PSQL_ENV }).toString().trim();
const psqlFile = (db, file) => execFileSync("psql", ["-h", HOST, "-p", PGPORT, "-U", "postgres", "-d", db, "-qtAX", "-v", "ON_ERROR_STOP=1", "-f", file], { env: PSQL_ENV, stdio: ["ignore", "ignore", "pipe"] });

let fails = 0, passes = 0;
const ok = (name) => { passes++; console.log(`PASS ${name}`); };
const bad = (name, detail) => { fails++; console.log(`FAIL ${name}: ${detail}`); };
const canon = (v) => JSON.stringify(v, (_k, x) => (x && typeof x === "object" && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort()) : x));
const expect = (name, got, want) => (canon(got) === canon(want) ? ok(name) : bad(name, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`));

// ---- database and test data ----
psql("postgres", `drop database if exists ${DB}`);
psql("postgres", `create database ${DB} template ${TEMPLATE}`);
psqlFile(DB, path.join(REPO, "sql/zella_owner_onboarding.sql"));
const OWNER = "e2e00000-0000-4000-8000-000000000001", OWNER2 = "e2e00000-0000-4000-8000-000000000002", STAFF = "e2e00000-0000-4000-8000-000000000003";
const ADMIN = "e2e00000-0000-4000-8000-000000000009";
const BIZ = "e2e10000-0000-4000-8000-000000000001", BIZ2 = "e2e10000-0000-4000-8000-000000000002";
psql(DB, `
  insert into auth.users (id, email, email_confirmed_at, encrypted_password) values
    ('${OWNER}', 'owner@e2e-onboarding.test', now(), 'test-only'), ('${OWNER2}', 'owner2@e2e-onboarding.test', now(), 'test-only'),
    ('${STAFF}', 'staff@e2e-onboarding.test', now(), 'test-only'), ('${ADMIN}', 'admin@e2e-onboarding.test', now(), 'test-only');
  insert into public.businesses (id, name, industry_id, timezone, onboarding_status)
    select v.id::uuid, v.name, (select id from public.industries order by slug limit 1), 'America/Chicago', 'testing'
      from (values ('${BIZ}', 'E2E Test Studio'), ('${BIZ2}', 'E2E Other Shop')) v(id, name);
  insert into public.business_members (business_id, user_id, role, status) values
    ('${BIZ}', '${OWNER}', 'owner', 'active'), ('${BIZ2}', '${OWNER2}', 'owner', 'active'), ('${BIZ}', '${STAFF}', 'staff', 'active');
  insert into public.platform_admins (user_id, role, is_active) values ('${ADMIN}', 'zella_owner', true);
  insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at) values (gen_random_uuid(), '${ADMIN}', 'totp', 'verified', now(), now());
  insert into public.staff_members (business_id, name, title) values ('${BIZ}', 'Sam Test', 'Stylist');
  with ag as (insert into public.ai_agents (business_id, name, agent_type, is_default) values ('${BIZ}', 'Ava', 'receptionist', true) returning id)
  insert into public.ai_agent_configs (agent_id, business_id, system_prompt, escalation_rules)
    select id, '${BIZ}', 'You are the receptionist for a test studio.', '{"transfer_to": {"type": "owner"}}' from ag;
  insert into public.integrations (business_id, provider, integration_type, status) values ('${BIZ}', 'telnyx', 'phone', 'active'), ('${BIZ}', 'vapi', 'voice', 'active');
  insert into public.knowledge_items (business_id, title, answer, status) values ('${BIZ}', 'Parking', 'Free parking behind the studio.', 'ready');
  insert into public.automations (business_id, name, trigger_type, status) values ('${BIZ}', 'Missed call text', 'missed_call', 'paused');
  insert into public.activation_tests (business_id, ok) values ('${BIZ}', true);`);

// ---- the stand in and the functions ----
const children = [];
const start = (cmd, args, env, ready) => new Promise((resolve, reject) => {
  const p = spawn(cmd, args, { cwd: REPO, env: { ...PSQL_ENV, ...env }, stdio: ["ignore", "pipe", "pipe"] });
  children.push(p);
  let out = "";
  const t = setTimeout(() => reject(new Error(`${args.join(" ")} did not start: ${out.slice(-500)}`)), 90_000);
  const look = (d) => { out += d; if (out.includes(ready)) { clearTimeout(t); resolve(); } };
  p.stdout.on("data", look); p.stderr.on("data", (d) => { out += d; if (process.env.ZLOG) process.stderr.write(d); });
  p.on("exit", (c) => { clearTimeout(t); if (!out.includes(ready)) reject(new Error(`${args.join(" ")} exited ${c}: ${out.slice(-500)}`)); });
});
const stop = () => { for (const p of children) p.kill("SIGTERM"); };
process.on("exit", stop);

const fnEnv = { SUPABASE_URL: BASE, SUPABASE_ANON_KEY: ANON, ZELLA_SERVER_SECRET_KEY: SERVER, ZELLA_APP_URL: "http://localhost:5199" };
const fns = Object.fromEntries(Object.entries(PORTS).filter(([k]) => k !== "backend"));
try {
  await start("node", ["tests/browser/local-backend.mjs"], { PORT: String(PORTS.backend), ZDB: DB, ZPG_HOST: HOST, ZPG_PORT: PGPORT, ZFUNCTIONS: JSON.stringify(fns) }, "local Supabase stand-in");
  for (const [name, port] of Object.entries(fns)) {
    await start("deno", ["run", "-A", "--no-lock", "--config", `web/supabase/functions/${name}/deno.json`, "tests/browser/run-function.ts", name, String(port)], fnEnv, `${name} on ${port}`);
  }
} catch (e) { console.log(`FAIL could not start the local backend: ${e.message}`); stop(); process.exit(1); }

// ---- the calls the screens make ----
const call = async (method, url, token, body, headers = {}) => {
  const res = await fetch(`${BASE}${url}`, { method, headers: { apikey: ANON, ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...(body instanceof Uint8Array ? {} : { "Content-Type": "application/json" }), ...headers }, body: body === undefined ? undefined : body instanceof Uint8Array ? body : JSON.stringify(body) });
  const text = await res.text();
  let json = null; try { json = JSON.parse(text); } catch { json = text; }
  return { status: res.status, json };
};
const rpc = (fn, token, args = {}) => call("POST", `/rest/v1/rpc/${fn}`, token, args);
// the screens read the code from message (P0001 from a function; 42501 for MFA_REQUIRED from the request check)
const code = (r) => (r.status >= 400 ? (/^[A-Z_]{3,40}$/.test(r.json?.message ?? "") ? r.json.message : `${r.status}:${r.json?.code ?? r.json?.message}`) : "ok");
const signIn = async (email) => (await call("POST", "/auth/v1/token?grant_type=password", null, { email, password: PASSWORD })).json.access_token;
const verifyCode = async (token, factorId) => {
  await call("POST", `/auth/v1/factors/${factorId}/challenge`, token, {});
  return (await call("POST", `/auth/v1/factors/${factorId}/verify`, token, { code: "123456" })).json.access_token;
};
const adminFactor = psql(DB, `select id from auth.mfa_factors where user_id = '${ADMIN}'`);
const admin = await verifyCode(await signIn("admin@e2e-onboarding.test"), adminFactor);
const adminAction = (body) => call("POST", "/functions/v1/owner-provision-business", admin, body);
const fn = (token, body) => call("POST", "/functions/v1/owner-onboarding", token, body);

let owner = await signIn("owner@e2e-onboarding.test");
const other = await signIn("owner2@e2e-onboarding.test"), staff = await signIn("staff@e2e-onboarding.test");
const state = async () => (await rpc("zella_owner_onboarding_get", owner, { p_business_id: BIZ })).json;

// who may call
expect("list: the owner sees their business", (await rpc("zella_owner_onboarding_list", owner)).json.businesses.map((b) => b.business_name), ["E2E Test Studio"]);
expect("the owner of another business is refused", code(await rpc("zella_owner_onboarding_get", other, { p_business_id: BIZ })), "NOT_ALLOWED");
expect("a staff member is refused", code(await rpc("zella_owner_onboarding_get", staff, { p_business_id: BIZ })), "NOT_ALLOWED");
const anon = await rpc("zella_owner_onboarding_get", null, { p_business_id: BIZ });
expect("anonymous is refused", anon.status >= 400 && anon.status < 500, true);
expect("a Zella Voice admin can't act as the owner", code(await rpc("zella_owner_onboarding_complete_step", admin, { p_business_id: BIZ, p_step: "welcome" })), "NOT_ALLOWED");

// 1. welcome
expect("1. starts at welcome", (await state()).current_step, "welcome");
expect("1. welcome done", (await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "welcome" })).json.state.current_step, "security");

// 2. password and two step sign in
expect("2. not ready without an authenticator", (await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "security" })).json.message, "SECURITY_INCOMPLETE");
const factor = (await call("POST", "/auth/v1/factors", owner, { factor_type: "totp", friendly_name: "Phone" })).json.id;
expect("2. a wrong code is refused", (await call("POST", `/auth/v1/factors/${factor}/verify`, owner, { code: "000000" })).status, 422);
owner = await verifyCode(owner, factor);
const sec = await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "security" });
expect("2. done, checked from the auth records", [sec.json.state?.current_step, sec.json.state?.security?.ready], ["details", true]);

// 3. check your details
// Looks right sends the fingerprint of the details shown (data_hash), as the screens do
const seen = async (k) => (await state()).details.sections.find((x) => x.key === k).data_hash;
expect("3. Looks right without what was shown is refused", code(await rpc("zella_owner_onboarding_section", owner, { p_business_id: BIZ, p_section: "business", p_decision: "looks_right" })), "INVALID_INPUT");
expect("3. and with a null fingerprint", code(await rpc("zella_owner_onboarding_section", owner, { p_business_id: BIZ, p_section: "business", p_decision: "looks_right", p_seen_hash: null })), "INVALID_INPUT");
for (const s of ["business", "hours_services", "receptionist_phone"]) await rpc("zella_owner_onboarding_section", owner, { p_business_id: BIZ, p_section: s, p_decision: "looks_right", p_seen_hash: await seen(s) });
const change = await rpc("zella_owner_onboarding_section", owner, { p_business_id: BIZ, p_section: "team", p_decision: "change", p_note: "Add Maya, she started this week." });
expect("3. Change with a note", change.json.state.details.sections.find((x) => x.key === "team").status, "change_requested");
expect("3. staff can't answer for the owner", code(await rpc("zella_owner_onboarding_section", staff, { p_business_id: BIZ, p_section: "team", p_decision: "looks_right" })), "NOT_ALLOWED");
const overview = (await rpc("zella_admin_onboarding_overview", admin)).json.businesses.find((b) => b.business_id === BIZ);
expect("3. the admin sees the request and the step", [overview.change_requests, overview.current_step_number, overview.steps_total], [1, 3, 7]);
expect("3. the request is an admin alert", psql(DB, `select count(*) from public.platform_alerts where kind = 'onboarding_change_requested' and business_id = '${BIZ}' and status = 'open'`), "1");
psql(DB, `insert into public.staff_members (business_id, name, title) values ('${BIZ}', 'Maya Test', 'Stylist')`);
expect("3. the admin marks it done", (await rpc("zella_admin_onboarding_change_done", admin, { p_business_id: BIZ, p_section: "team", p_note: "Added Maya" })).json, { changed: true });
expect("3. the owner checks it again", (await state()).details.sections.find((x) => x.key === "team").status, "updated");
await rpc("zella_owner_onboarding_section", owner, { p_business_id: BIZ, p_section: "team", p_decision: "looks_right", p_seen_hash: await seen("team") });
expect("3. done", (await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "details" })).json.state.current_step, "identity");

// Finish later, sign in again, resume at the same step
expect("finish later", (await rpc("zella_owner_onboarding_finish_later", owner, { p_business_id: BIZ })).json.changed, true);
owner = await signIn("owner@e2e-onboarding.test");
expect("signed in again with a password only: the code is asked for first", code(await rpc("zella_owner_onboarding_get", owner, { p_business_id: BIZ })), "MFA_REQUIRED");
owner = await verifyCode(owner, factor);
const resumed = await rpc("zella_owner_onboarding_resume", owner, { p_business_id: BIZ });
expect("resume: back at the same step", [resumed.json.changed, resumed.json.state.current_step, resumed.json.state.paused_at], [true, "identity", null]);

// 4. verify your identity: manual upload through owner-onboarding, checked in Verification
const jpg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 5, 6]);
const uploadDoc = async (token, kind) => {
  const meta = { businessId: BIZ, kind, fileName: `${kind}.jpg`, mimeType: "image/jpeg", size: jpg.length };
  const link = await fn(token, { action: "identity_upload_url", ...meta });
  if (link.status !== 200) return link;
  const put = await call("PUT", `/storage/v1/object/upload/sign/business-documents/${link.json.path}?token=${link.json.token}`, null, jpg, { "Content-Type": "image/jpeg" });
  if (put.status !== 200) return put;
  return fn(token, { action: "identity_upload_confirm", ...meta, path: link.json.path });
};
expect("4. the other owner can't get an upload link", (await fn(other, { action: "identity_upload_url", businessId: BIZ, kind: "owner_identity", fileName: "x.jpg", mimeType: "image/jpeg", size: 10 })).json.code, "NOT_ALLOWED");
expect("4. staff can't either", (await fn(staff, { action: "identity_upload_url", businessId: BIZ, kind: "owner_identity", fileName: "x.jpg", mimeType: "image/jpeg", size: 10 })).json.code, "NOT_ALLOWED");
expect("4. nor anonymous", (await call("POST", "/functions/v1/owner-onboarding", null, { action: "identity_upload_url", businessId: BIZ })).status, 401);
expect("4. a link isn't a key to the bucket", (await call("POST", "/storage/v1/object/upload/sign/business-documents/" + BIZ + "/owner_identity/x.jpg", owner, {})).status, 403);
expect("4. the private bucket refuses an unsigned upload", (await call("PUT", `/storage/v1/object/business-documents/${BIZ}/owner_identity/x.jpg`, owner, jpg, { "Content-Type": "image/jpeg" })).status, 403);
expect("4. and an unsigned read", (await call("GET", `/storage/v1/object/business-documents/${BIZ}/owner_identity/x.jpg`, owner)).status, 400);
{
  const fake = new TextEncoder().encode("MZ this is not a photo");
  const meta = { businessId: BIZ, kind: "owner_identity", fileName: "fake.jpg", mimeType: "image/jpeg", size: fake.length };
  const link = await fn(owner, { action: "identity_upload_url", ...meta });
  await call("PUT", `/storage/v1/object/upload/sign/business-documents/${link.json.path}?token=${link.json.token}`, null, fake, { "Content-Type": "image/jpeg" });
  expect("4. a file that only says it is a photo is refused", (await fn(owner, { action: "identity_upload_confirm", ...meta, path: link.json.path })).json.code, "INVALID_INPUT");
}
expect("4. first document: still needed", (await uploadDoc(owner, "owner_identity")).json.identity?.status, "needed");
expect("4. both documents: checking", (await uploadDoc(owner, "business_registration")).json.identity?.status, "checking");
expect("4. a third upload while checking is refused", (await uploadDoc(owner, "owner_identity")).json.code, "UPLOAD_NOT_ALLOWED");
const docId = (kind) => psql(DB, `select id from public.business_verification_documents where business_id = '${BIZ}' and kind = '${kind}' and status <> 'replaced'`);
const review = (kind, status, note) => adminAction({ action: "document_review", documentId: docId(kind), status, note });
let rv = await review("owner_identity", "rejected", "The photo is blurred.");
expect("4. Zella Voice rejects it in Verification", rv.status, 200);
let id = (await rpc("zella_owner_onboarding_identity_status", owner, { p_business_id: BIZ })).json;
expect("4. try again", [id.status, id.attempts_used, id.upload_kinds], ["try_again", 1, ["owner_identity"]]);
expect("4. a new copy: checking", (await uploadDoc(owner, "owner_identity")).json.identity?.status, "checking");
await review("owner_identity", "rejected", "Still blurred.");
id = (await rpc("zella_owner_onboarding_identity_status", owner, { p_business_id: BIZ })).json;
expect("4. the second failure: manual review, no upload", [id.status, id.can_upload], ["in_review", false]);
expect("4. upload refused in review", (await uploadDoc(owner, "owner_identity")).json.code, "UPLOAD_NOT_ALLOWED");
expect("4. can't pass before it succeeds", (await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "identity" })).json.message, "IDENTITY_NOT_VERIFIED");
expect("4. payment checkout stays closed", (await rpc("zella_owner_onboarding_payment_status", owner, { p_business_id: BIZ })).json.status, "locked");
await review("business_registration", "verified");
rv = await review("owner_identity", "verified");
expect("4. an admin approves it in Verification: verified", (await rpc("zella_owner_onboarding_identity_status", owner, { p_business_id: BIZ })).json.status, "verified");
expect("4. done", (await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "identity" })).json.state.current_step, "plan");

// 5. your plan: saved by a Zella Voice admin, accepted by the owner
const values = { tier: "base", billing_interval: "monthly", price_cents: 9900, setup_fee_cents: 0, minutes: 300, texts: 200, emails: 200,
  team_seats: 3, phone_numbers: 1, locations: 1, languages: ["en"], trial_enabled: false };
const acks = { costs_not_configured: "Test database", price_zero: "Test plan", loss: "Test plan", below_target_margin: "Test plan", minutes_high: "Test plan" };
const saved = await rpc("zella_admin_plan_save", admin, { p_business_id: BIZ, p_values: values, p_acknowledgements: acks, p_idempotency_key: "e2e-onboarding-plan-1" });
expect("5. the admin saved a plan", saved.status, 200);
const plan = (await state()).plan;
expect("5. the owner sees it", [plan.available, plan.current?.price_cents, plan.current?.minutes, "estimate" in (plan.current ?? {})], [true, 9900, 300, false]);
expect("5. a wrong version is refused", code(await rpc("zella_owner_onboarding_plan_accept", owner, { p_business_id: BIZ, p_plan_version: plan.current.version + 1 })), "PLAN_CHANGED");
expect("5. accepted", (await rpc("zella_owner_onboarding_plan_accept", owner, { p_business_id: BIZ, p_plan_version: plan.current.version })).json.state.current_step, "payment");

// 6. pay or start a trial: waiting (Stripe is not built)
expect("6. waiting", (await rpc("zella_owner_onboarding_payment_status", owner, { p_business_id: BIZ })).json, { status: "waiting", reason: "payments_not_connected", checkout_available: false, confirmed_at: null });
expect("6. can't finish without a payment", code(await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "payment" })), "PAYMENT_NOT_CONFIRMED");
let live = await rpc("zella_request_activation", owner, { p_business_id: BIZ });
expect("go live refused without a confirmed payment", [live.json.ready, live.json.checks.filter((c) => !c.ok).map((c) => c.key)], [false, ["payment"]]);
// stands in for the payment webhook, which is not built: the server records a provider confirmed payment
psql(DB, `insert into public.payments (business_id, amount, currency, status, provider, external_payment_id, paid_at) values ('${BIZ}', 99, 'usd', 'succeeded', 'stripe', 'pi_e2e_test_only', now())`);
expect("6. confirmed", (await rpc("zella_owner_onboarding_payment_status", owner, { p_business_id: BIZ })).json.status, "confirmed");
expect("6. done", (await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "payment" })).json.state.current_step, "done");

// 7. you're all set
const done = (await rpc("zella_owner_onboarding_complete_step", owner, { p_business_id: BIZ, p_step: "done" })).json.state;
expect("7. every step done", done.steps.map((s) => s.state), Array(7).fill("done"));
expect("7. the go live checklist passes", done.go_live.ready, true);
expect("staff can't switch it live", code(await rpc("zella_request_activation", staff, { p_business_id: BIZ })), "NOT_ALLOWED");
live = await rpc("zella_request_activation", owner, { p_business_id: BIZ });
expect("the owner goes live", [live.json.ready, psql(DB, `select onboarding_status from public.businesses where id = '${BIZ}'`)], [true, "active"]);
const progress = (await rpc("zella_admin_onboarding_progress", admin, { p_business_id: BIZ })).json;
expect("the admin sees it finished", [progress.current_step, progress.completed_at !== null], ["done", true]);
expect("every owner write was audited with before and after", psql(DB, `select count(*) filter (where old_data is null or new_data is null) || ',' || count(*) from public.audit_logs where business_id = '${BIZ}' and action like 'onboarding.%'`), "0,18");

// the identity provider receiver is off by default
const hook = await fetch(`${BASE}/functions/v1/identity-webhook`, { method: "POST", body: "{}", headers: { "x-identity-signature": "t=1,v1=00" } });
expect("the identity webhook is off by default", [hook.status, await hook.text()], [503, "not_enabled"]);

stop();
console.log(`\n${passes} passed, ${fails} failed`);
console.log(fails === 0 ? "ALL PASSED" : `${fails} FAILED`);
process.exit(fails === 0 ? 0 : 1);
