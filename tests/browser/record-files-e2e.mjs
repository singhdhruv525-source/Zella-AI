// Files on records end to end against the local stand-in (tests/browser/local-backend.mjs) and the record-files function
// running in Deno (run-function.ts): upload → content check → open, signed-link expiry, direct storage access, a PDF with
// JavaScript refused, access after a staff member is removed, cleanup. Synthetic data in the local database only.
// Usage: node tests/browser/record-files-e2e.mjs   (stack running: start-stack.sh with record-files on)
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { PSQL_ENV, requireIsolated } from "./isolated-db.cjs";
import zlib from "node:zlib";
const API = process.env.API ?? "http://localhost:54321", ANON = "sb_publishable_local_test_only", SERVER = "sb_secret_local_test_only";
const SECRET = "zella-local-test-secret-not-for-production";
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const jwt = (sub) => { const h = b64({ alg: "HS256", typ: "JWT" }), b = b64({ sub, role: "authenticated", aal: "aal1", exp: Math.floor(Date.now() / 1000) + 3600 });
  return `${h}.${b}.${crypto.createHmac("sha256", SECRET).update(`${h}.${b}`).digest("base64url")}`; };
requireIsolated("/var/lib/postgresql/zella-sec", "55433", process.env.ZDB ?? "zella_ui");
const sql = (q) => execFileSync("psql", ["-X", "-At", "-v", "ON_ERROR_STOP=1", "-h", "/var/lib/postgresql/zella-sec", "-p", "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zella_ui", "-c", q], { env: PSQL_ENV }).toString().trim();
let fails = 0; const ok = (cond, what) => { console.log(`${cond ? "ok  " : "FAIL"} ${what}`); if (!cond) fails++; };
const BIZ = "c0000000-0000-0000-0000-000000000004", OTHER_OWNER = "a0000000-0000-0000-0000-000000000002";
const STAFF = "e2e00000-0000-0000-0000-0000000000f1", OUTSIDER = "e2e00000-0000-0000-0000-0000000000f2";
sql(`insert into auth.users (id, email, email_confirmed_at) values ('${STAFF}', 'files-staff@e2e.test', now()), ('${OUTSIDER}', 'files-out@e2e.test', now()) on conflict do nothing;
     insert into public.business_members (business_id, user_id, role, status) values ('${BIZ}', '${STAFF}', 'staff', 'active') on conflict do nothing;`);
const REC = sql(`select id from public.crm_records where business_id = '${BIZ}' and archived_at is null order by created_at limit 1`);
const as = (who) => who === "server" ? { apikey: SERVER, Authorization: `Bearer ${SERVER}` } : who === "anon" ? { apikey: ANON } : { apikey: ANON, Authorization: `Bearer ${jwt(who)}` };
const rpc = async (who, fn, args) => { const r = await fetch(`${API}/rest/v1/rpc/${fn}`, { method: "POST", headers: { "content-type": "application/json", ...as(who) }, body: JSON.stringify(args) }); return { status: r.status, body: await r.json().catch(() => null) }; };
const fnCall = async (who, body) => { const r = await fetch(`${API}/functions/v1/record-files`, { method: "POST", headers: { "content-type": "application/json", ...as(who) }, body: JSON.stringify(body) }); return { status: r.status, body: await r.json().catch(() => null) }; };
const get = (who, path) => fetch(`${API}/storage/v1/object/record-files/${path}`, { headers: as(who) });
async function add(name, mime, bytes) {
  const b = await rpc(STAFF, "zella_begin_record_file", { p_record_id: REC, p_file_name: name, p_mime_type: mime, p_size_bytes: bytes.length });
  const up = await fetch(`${API}/storage/v1/object/record-files/${b.body.path}`, { method: "POST", headers: { "content-type": mime, ...as(STAFF) }, body: bytes });
  return { id: b.body.id, path: b.body.path, upload: up.status, check: await fnCall(STAFF, { action: "check", file_id: b.body.id }) };
}

const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from("IHDR synthetic")]);
const good = await add("before.png", "image/png", png);
ok(good.upload === 200 && good.check.status === 200 && good.check.body.status === "ready", `real PNG: uploaded, checked by the function, ready (${good.check.status})`);
ok(sql(`select sha256 is not null and check_result = 'ok' from crm_record_files where id = '${good.id}'`) === "t", "verdict and SHA-256 recorded");

const z = zlib.deflateSync(Buffer.from("<< /S /JavaScript /JS (app.alert('x')) >>"));
const evil = Buffer.concat([Buffer.from(`%PDF-1.7\n1 0 obj << /Filter /FlateDecode /Length ${z.length} >>\nstream\n`), z, Buffer.from("\nendstream\nendobj\n%%EOF")]);
const bad = await add("estimate.pdf", "application/pdf", evil);
ok(bad.check.status === 422 && bad.check.body.status === "rejected", `PDF with JavaScript in a compressed stream: rejected (${JSON.stringify(bad.check.body)})`);
ok((await get("server", bad.path)).status !== 200, "its stored copy was deleted");
ok(sql(`select status from crm_record_files where id = '${bad.id}'`) === "rejected", "recorded as rejected");
const fake = await add("photo.png", "image/png", Buffer.from("<html><script>alert(1)</script></html>"));
ok(fake.check.status === 422, "HTML renamed .png: rejected");
const sneaky = await add("photo2.png", "image/png", png);
ok(sneaky.check.body?.status === "ready", "(control) another real PNG passes");

// direct storage access
ok((await get(STAFF, good.path)).status === 200, "staff member of the business: direct download with their sign-in works");
ok((await get(OUTSIDER, good.path)).status !== 200, "someone from outside the business: refused");
ok((await get("anon", good.path)).status !== 200, "no sign-in: refused");
ok((await fnCall(OUTSIDER, { action: "check", file_id: good.id })).status === 403, "outsider can't run the check on someone's file");

// signed links expire
const sign = async (who, path, secs) => (await (await fetch(`${API}/storage/v1/object/sign/record-files/${path}`, { method: "POST", headers: { "content-type": "application/json", ...as(who) }, body: JSON.stringify({ expiresIn: secs }) })).json());
const link = await sign(STAFF, good.path, 2);
ok((await fetch(`${API}/storage/v1${link.signedURL}`)).status === 200, "signed link works while valid");
await new Promise((r) => setTimeout(r, 2500));
ok((await fetch(`${API}/storage/v1${link.signedURL}`)).status === 400, "signed link refused after it expires");
ok(!(await sign(OUTSIDER, good.path, 60)).signedURL, "outsider can't get a signed link");

// staff removed from the business
const before = await sign(STAFF, good.path, 60);
sql(`delete from public.business_members where business_id = '${BIZ}' and user_id = '${STAFF}'`);
ok((await get(STAFF, good.path)).status !== 200, "after removal: direct download refused");
ok(!(await sign(STAFF, good.path, 60)).signedURL, "after removal: no new signed links");
ok((await fetch(`${API}/storage/v1${before.signedURL}`)).status === 200, "LIMITATION: a link issued before removal still works until it expires (5 minutes in the app)");
ok((await rpc(STAFF, "zella_begin_record_file", { p_record_id: REC, p_file_name: "x.png", p_mime_type: "image/png", p_size_bytes: 10 })).status >= 400, "after removal: can't add files");

// cleanup
ok((await fnCall(OWNER_OF(), { action: "cleanup" })).status === 403, "cleanup refused to a signed-in member");
sql(`insert into storage.objects (bucket_id, name, metadata, created_at) values ('record-files', '${BIZ}/${REC}/orphan-e2e.png', '{}', now() - interval '2 days') on conflict do nothing`);
const c = await fnCall("server", { action: "cleanup" });
ok(c.status === 200 && c.body.deleted >= 1, `cleanup with the server key deleted ${c.body?.deleted} object(s)`);
ok(sql(`select count(*) from storage.objects where name = '${BIZ}/${REC}/orphan-e2e.png'`) === "0", "orphan object gone");
ok(sql(`select count(*) from audit_logs where action = 'record_files_purged' and created_at > now() - interval '1 minute'`) !== "0", "purge audited");
ok(sql(`select count(*) from storage.objects where name = '${good.path}'`) === "1", "ready files untouched");

// tidy the local database
sql(`delete from public.crm_record_files where path like '${BIZ}/${REC}/%'; delete from storage.objects where name like '${BIZ}/${REC}/%';
     delete from public.crm_record_events where record_id = '${REC}' and kind in ('file_added', 'file_rejected');
     delete from auth.users where id in ('${STAFF}', '${OUTSIDER}');`);
function OWNER_OF() { return OTHER_OWNER; }
console.log(fails ? `${fails} FAILED` : "ALL PASSED"); process.exit(fails ? 1 : 0);
