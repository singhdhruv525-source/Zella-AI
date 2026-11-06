// Batch 1 unit tests for the pure logic behind the admin permission states, lead creation and record-file checks.
//   cd web && node --test tests/batch1_unit.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { ACCESS, accessFrom, hasPermission } from "../src/adminPermissions.js";
import { addLead, leadError } from "../src/leadCreate.js";
import { checkOutcome } from "../src/recordFileCheck.js";

// ---------- admin permissions ----------
const owner = { role: "zella_owner", roleLabel: "Zella owner", permissions: ["businesses.view", "businesses.manage", "security.view", "platform.configure"] };
const readOnly = { role: "read_only_admin", roleLabel: "Read-only admin", permissions: ["businesses.view", "security.view"] };

test("authorized owner: allowed pages and actions", () => {
  const a = accessFrom(owner, null);
  assert.equal(a.state, ACCESS.AUTHORIZED);
  for (const p of owner.permissions) assert.equal(hasPermission(a, p), true);
  assert.equal(hasPermission(a, null), true, "pages needing no permission open for an authorized admin");
  assert.equal(hasPermission(a, "audit.view"), false, "a permission not listed is not granted, even to the owner list given");
});

test("restricted admin: only listed permissions", () => {
  const a = accessFrom(readOnly, null);
  assert.equal(hasPermission(a, "security.view"), true);
  for (const p of ["security.manage", "platform.configure", "businesses.manage", "billing.view", "audit.view"]) assert.equal(hasPermission(a, p), false, p);
});

test("loading grants nothing", () => {
  const a = { state: ACCESS.LOADING, me: null, reason: null };
  for (const p of [null, "businesses.view", "security.view"]) assert.equal(hasPermission(a, p), false);
});

test("failed lookup grants nothing (network, 500, malformed answer)", () => {
  for (const [result, error] of [[null, Object.assign(new Error("Failed to fetch"), {})], [null, Object.assign(new Error("boom"), { status: 500 })],
    [{ role: "x" }, null], [null, null], ["nope", null], [{ permissions: "businesses.view" }, null]]) {
    const a = accessFrom(result, error);
    assert.equal(a.state, ACCESS.FAILED, JSON.stringify(result));
    for (const p of [null, "businesses.view", "security.manage"]) assert.equal(hasPermission(a, p), false);
  }
});

test("refusals are unauthorized, not failed", () => {
  assert.equal(accessFrom(null, Object.assign(new Error("Platform admin access required"), { status: 403 })).state, ACCESS.UNAUTHORIZED);
  assert.equal(accessFrom(null, Object.assign(new Error("x"), { status: 401 })).state, ACCESS.UNAUTHORIZED);
  const mfa = accessFrom(null, Object.assign(new Error("Enter the code"), { status: 403, code: "MFA_REQUIRED" }));
  assert.equal(mfa.state, ACCESS.UNAUTHORIZED); assert.equal(mfa.reason, "MFA_REQUIRED");
  assert.equal(hasPermission(mfa, null), false);
});

test("non-string permission entries are dropped", () => {
  const a = accessFrom({ permissions: ["businesses.view", null, 3, { x: 1 }] }, null);
  assert.deepEqual(a.me.permissions, ["businesses.view"]);
});

// ---------- leads ----------
const values = { first_name: "Jamie", last_name: "Rivera", phone: "+15125550123", email: "Jamie@X.test", source: "manual", notes: "" };

test("lead: only the pipeline RPC is called, with normalised arguments", async () => {
  const calls = [];
  const rpc = async (fn, args) => { calls.push([fn, args]); return { data: { result: "created" }, error: null }; };
  const r = await addLead(rpc, "biz-1", values);
  assert.deepEqual(r, { ok: true, message: "Jamie Rivera was added." });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "zella_staff_add_lead");
  assert.equal(calls[0][1].p_email, "jamie@x.test");
  assert.equal(calls[0][1].p_business_id, "biz-1");
});

test("lead: duplicate outcomes keep their messages", async () => {
  const m = async (result) => (await addLead(async () => ({ data: { result }, error: null }), "b", values)).message;
  assert.match(await m("matched"), /already in your list/);
  assert.match(await m("needs_review"), /possible duplicate/);
});

test("lead: a missing RPC never falls back, and says so plainly", async () => {
  for (const message of ["Could not find the function public.zella_staff_add_lead in the schema cache", "function zella_staff_add_lead does not exist"]) {
    const r = await addLead(async () => ({ data: null, error: { message, code: "PGRST202" } }), "b", values);
    assert.equal(r.ok, false); assert.match(r.error, /isn't available/); assert.doesNotMatch(r.error, /schema cache|PGRST|function/);
  }
});

test("lead: server refusals and network failures are explained without database wording", async () => {
  const cases = [["NOT_ALLOWED", /permission/], ["NO_CONTACT", /phone number or email/], ["BAD_EMAIL", /email/], ["NAME_REQUIRED", /name/],
    ["BUSINESS_NOT_AVAILABLE", /paused/], ["MFA_REQUIRED", /authenticator/], ["JWT expired", /sign-in has expired/],
    ['duplicate key value violates unique constraint "customers_pkey"', /couldn't be added/]];
  for (const [message, want] of cases) {
    const r = await addLead(async () => ({ data: null, error: { message } }), "b", values);
    assert.equal(r.ok, false); assert.match(r.error, want, message); assert.doesNotMatch(r.error, /constraint|pkey|relation/);
  }
  const thrown = await addLead(async () => { throw new TypeError("Failed to fetch"); }, "b", values);
  assert.match(thrown.error, /Couldn't reach Zella/);
  assert.match(leadError(null), /couldn't be added/);
});

// ---------- record-file check ----------
const fail = (status, body) => ({ data: null, error: { context: { status, json: async () => body } } });

test("file check: ready, rejected, waiting and refused", async () => {
  assert.equal((await checkOutcome({ data: { ok: true, status: "ready" }, error: null }, "a.jpg")).state, "ready");
  const rej = await checkOutcome(fail(422, { ok: false, status: "rejected", reason: "not a real JPEG" }), "a.jpg");
  assert.equal(rej.state, "rejected"); assert.match(rej.message, /not a real JPEG/);
  assert.equal((await checkOutcome(fail(503, { ok: false, error: "try_again" }), "a.jpg")).state, "waiting", "server busy: keep it, offer Check again");
  assert.equal((await checkOutcome({ data: null, error: { context: { json: async () => { throw new Error("not json"); } } } }, "a.jpg")).state, "waiting", "timeout / no answer");
  assert.equal((await checkOutcome(fail(400, { ok: false, error: "UPLOAD_MISSING" }), "a.jpg")).state, "waiting");
  assert.equal((await checkOutcome(fail(400, { ok: false, error: "BAD_FILE_TYPE" }), "a.jpg")).state, "failed", "refused outright: discarded");
  assert.equal((await checkOutcome(fail(403, { ok: false, error: "NOT_ALLOWED" }), "a.jpg")).state, "failed");
  assert.equal((await checkOutcome({ data: { ok: false, status: "checking" }, error: null }, "a.jpg")).state, "waiting");
});
