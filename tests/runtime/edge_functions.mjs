// Every edge function served by the Supabase edge runtime (public.ecr.aws/supabase/edge-runtime, the runtime the hosted
// platform uses), called over HTTP through the local Supabase stand-in (tests/browser/local-backend.mjs), so sign-in,
// row security, grants and RPCs are the real ones. Synthetic data in the local database only; nothing is sent.
// Covers: google-lead, website-lead, reschedule-appointment, staff-invite, continue-plan, billing-webhook, voice-rules.
// record-files: tests/browser/record-files-e2e.mjs. owner-provision-business: tests/browser/wizard-journey.cjs.
// Usage: node tests/runtime/edge_functions.mjs    (stack: start-runtime-stack, see tests/runtime/README.md)
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const API = process.env.API ?? "http://localhost:54321";
const ANON = "sb_publishable_local_test_only", SERVER = "sb_secret_local_test_only", JWT_SECRET = "zella-local-test-secret-not-for-production";
const STRIPE = "whsec_local_test_only";
const sql = (q) => execFileSync("psql", ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-h", "/var/lib/postgresql/zella-sec", "-p", "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zella_ui"], { input: q }).toString().trim();
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const jwt = (sub) => { const h = b64({ alg: "HS256", typ: "JWT" }), b = b64({ sub, role: "authenticated", aal: "aal1", exp: Math.floor(Date.now() / 1000) + 3600 });
  return `${h}.${b}.${crypto.createHmac("sha256", JWT_SECRET).update(`${h}.${b}`).digest("base64url")}`; };
let fails = 0; const ok = (fn, what, cond, detail = "") => { console.log(`${cond ? "ok  " : "FAIL"} ${fn}: ${what}${cond ? "" : ` - ${String(detail).slice(0, 200)}`}`); if (!cond) fails++; };
async function call(fn, { method = "POST", body, raw, headers = {}, who } = {}) {
  const h = { apikey: ANON, ...(who ? { Authorization: `Bearer ${who === "server" ? SERVER : jwt(who)}` } : {}), ...headers };
  if (body !== undefined || raw !== undefined) h["content-type"] = "application/json";
  const r = await fetch(`${API}/functions/v1/${fn}`, { method, headers: h, body: raw ?? (body === undefined ? undefined : JSON.stringify(body)) });
  const text = await r.text(); let json = null; try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: r.status, text, json };
}
const BIZ = "c0000000-0000-0000-0000-000000000004", OWNER = "a0000000-0000-0000-0000-000000000002", VIEWER = "a0000000-0000-0000-0000-000000000004";

// ---------- google-lead ----------
const key = sql(`select set_config('request.jwt.claims', '{"sub":"${OWNER}","role":"authenticated"}', false) \\g /dev/null
select public.zella_google_lead_key_create('${BIZ}') ->> 'key'`).split("\n").pop();
const lead = (id, k = key) => ({ google_key: k, lead_id: id, user_column_data: [{ column_id: "FULL_NAME", string_value: "Runtime Test" }, { column_id: "PHONE_NUMBER", string_value: "+15125557001" }] });
let r = await call("google-lead", { body: lead(`rt-${Date.now()}`) });
ok("google-lead", "a lead with the business's key is stored (200)", r.status === 200 && r.json?.ok === true, r.text);
const dupId = `rt-dup-${Date.now()}`;
await call("google-lead", { body: lead(dupId) });
r = await call("google-lead", { body: lead(dupId) });
ok("google-lead", "Google's retry of the same lead: 200 duplicate, stored once", r.status === 200 && r.json?.duplicate === true
  && sql(`select count(*) from public.google_lead_events where lead_id = '${dupId}'`) === "1", r.text);
ok("google-lead", "wrong key: 401", (await call("google-lead", { body: lead("x", "zg_wrong") })).status === 401);
ok("google-lead", "not JSON: 400", (await call("google-lead", { raw: "{nope" })).status === 400);
ok("google-lead", "too large: 413", (await call("google-lead", { raw: JSON.stringify({ google_key: key, pad: "x".repeat(70000) }) })).status === 413);
ok("google-lead", "GET: 405", (await call("google-lead", { method: "GET" })).status === 405);

// ---------- website-lead ----------
const form = sql(`insert into public.website_forms (business_id, name, public_key, allowed_origins, enabled) values ('${BIZ}', 'Runtime form', 'wf_rt_${Date.now()}', array['https://example.test'], true) returning public_key`);
r = await call("website-lead", { body: { key: form, kind: "contact_form", name: "Web Runtime", phone: "+15125557002", message: "Hello" }, headers: { origin: "https://example.test" } });
ok("website-lead", "an enquiry from the business's site is stored (200)", r.status === 200 && r.json?.ok === true, r.text);
r = await call("website-lead", { body: { key: form, name: "X", phone: "+15125557003" }, headers: { origin: "https://evil.test" } });
ok("website-lead", "from a site that isn't allowed: 403", r.status === 403, r.text);
ok("website-lead", "unknown form: 400", (await call("website-lead", { body: { key: "wf_nope", name: "X", phone: "+15125557004" } })).status === 400);
ok("website-lead", "too large: 413", (await call("website-lead", { raw: JSON.stringify({ key: form, message: "x".repeat(13000) }) })).status === 413);
ok("website-lead", "browser pre-flight answered", (await call("website-lead", { method: "OPTIONS", headers: { origin: "https://example.test" } })).status === 204);

// ---------- reschedule-appointment ----------
const token = crypto.randomBytes(32).toString("hex");
const appt = sql(`insert into public.appointments (business_id, customer_id, title, start_time, end_time)
  values ('${BIZ}', (select id from public.customers where business_id = '${BIZ}' limit 1), 'Runtime visit', now() + interval '3 days', now() + interval '3 days 1 hour') returning id`).split("\n").pop();
sql(`insert into public.appointment_reschedule_links (appointment_id, business_id, token_hash, purpose, expires_at)
     values ('${appt}', '${BIZ}', encode(sha256(convert_to('${token}', 'utf8')), 'hex'), 'reschedule', now() + interval '7 days')`);
r = await call("reschedule-appointment", { body: { token } });
ok("reschedule-appointment", "the customer's private link opens their booking", r.status === 200 && r.json?.ok !== false && /Runtime visit|appointment|start/i.test(r.text), r.text);
r = await call("reschedule-appointment", { body: { token: "0".repeat(64) } });
ok("reschedule-appointment", "a made-up link is refused", r.json?.ok === false, r.text);
ok("reschedule-appointment", "a malformed link is refused", (await call("reschedule-appointment", { body: { token: "abc" } })).json?.reason === "invalid");

// ---------- staff-invite ----------
const inv = sql(`select set_config('request.jwt.claims', '{"sub":"${OWNER}","role":"authenticated"}', false) \\g /dev/null
select (public.zella_invite_staff('${BIZ}', 'runtime-invitee-${Date.now()}@example.test', 'Runtime Invitee', 'staff'))`).split("\n").pop();
r = await call("staff-invite", { body: { invitationId: inv }, who: VIEWER });
ok("staff-invite", "a view-only member can't send invitations", r.status === 403 || r.status === 401, `${r.status} ${r.text}`);
r = await call("staff-invite", { body: { invitationId: inv } });
ok("staff-invite", "not signed in: refused", r.status === 401, `${r.status} ${r.text}`);
r = await call("staff-invite", { body: { invitationId: inv }, who: OWNER });
ok("staff-invite", "the owner sends it (invitation email through Auth; nothing really sent locally)", r.status === 200, `${r.status} ${r.text}`);
ok("staff-invite", "a bad request: 400", (await call("staff-invite", { body: { invitationId: "nope" }, who: OWNER })).status === 400);

// ---------- continue-plan ----------
r = await call("continue-plan", { body: { token: "forged.payload" } });
ok("continue-plan", "a forged link is refused (status invalid)", r.json?.status === "invalid", `${r.status} ${r.text}`);
const fakeSig = Buffer.from(JSON.stringify({ b: "c0000000-0000-0000-0000-000000000004", exp: Date.now() / 1000 + 3600 })).toString("base64url") + "." + "A".repeat(43);
ok("continue-plan", "a link signed with the wrong secret is refused", (await call("continue-plan", { body: { token: fakeSig } })).json?.status === "invalid");
ok("continue-plan", "no link: refused", (await call("continue-plan", { body: {} })).json?.status === "invalid" || (await call("continue-plan", { body: {} })).status >= 400);

// ---------- billing-webhook ----------
const signStripe = (raw, t = Math.floor(Date.now() / 1000)) => `t=${t},v1=${crypto.createHmac("sha256", STRIPE).update(`${t}.${raw}`).digest("hex")}`;
const evt = JSON.stringify({ id: `evt_rt_${Date.now()}`, type: "customer.created", data: { object: {} } });
r = await call("billing-webhook", { raw: evt, headers: { "stripe-signature": signStripe(evt) } });
ok("billing-webhook", "a correctly signed event Zella doesn't use: 200 ignored (nothing changed)", r.status === 200 && r.text === "ignored", `${r.status} ${r.text}`);
ok("billing-webhook", "a wrong signature: 400", (await call("billing-webhook", { raw: evt, headers: { "stripe-signature": signStripe(evt).replace(/v1=[0-9a-f]+/, "v1=" + "0".repeat(64)) } })).status === 400);
ok("billing-webhook", "an old (replayed) signature: 400", (await call("billing-webhook", { raw: evt, headers: { "stripe-signature": signStripe(evt, Math.floor(Date.now() / 1000) - 3600) } })).status === 400);
ok("billing-webhook", "no signature: 400", (await call("billing-webhook", { raw: evt })).status === 400);

// ---------- voice-rules ----------
const VAPI = "vapi-local-test-secret-0123456789";
sql(`delete from vault.decrypted_secrets where name = 'zella_vapi_hmac_secret'; insert into vault.decrypted_secrets (id, name, decrypted_secret) values (gen_random_uuid(), 'zella_vapi_hmac_secret', '${VAPI}')`);
const vapiMsg = JSON.stringify({ message: { type: "status-update", status: "in-progress", call: { id: `rt-call-${Date.now()}` } } });
const signVapi = (raw, ts = String(Date.now())) => ({ "x-timestamp": ts, "x-signature": crypto.createHmac("sha256", VAPI).update(`${ts}.${raw}`).digest("hex") });
const signed = signVapi(vapiMsg);
r = await call("voice-rules", { raw: vapiMsg, headers: signed });
ok("voice-rules", "a message signed with Vapi's secret is accepted", r.status === 200, `${r.status} ${r.text}`);
r = await call("voice-rules", { raw: vapiMsg, headers: signed });
ok("voice-rules", "the same signed message again (replay): 401", r.status === 401, `${r.status} ${r.text}`);
ok("voice-rules", "a wrong signature: 401", (await call("voice-rules", { raw: vapiMsg, headers: { ...signVapi(vapiMsg), "x-signature": "0".repeat(64) } })).status === 401);
ok("voice-rules", "an old timestamp: 401", (await call("voice-rules", { raw: vapiMsg, headers: signVapi(vapiMsg, String(Date.now() - 3600_000)) })).status === 401);
ok("voice-rules", "unsigned: 401", (await call("voice-rules", { raw: vapiMsg })).status === 401);

// tidy
sql(`delete from vault.decrypted_secrets where name = 'zella_vapi_hmac_secret'; delete from public.website_forms where name = 'Runtime form';
     delete from public.appointment_reschedule_links where appointment_id = '${appt}'; delete from public.appointments where id = '${appt}'`);
console.log(fails ? `\n${fails} FAILED` : "\nALL PASSED"); process.exit(fails ? 1 : 0);
