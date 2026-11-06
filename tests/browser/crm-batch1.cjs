// Batch 1: CRM lead creation and record-file recovery in a real browser against a STUBBED backend (canned answers; no
// database, nothing sent). Same build as admin-permissions.cjs:  node tests/browser/crm-batch1.cjs
const { chromium } = require("playwright");
const BASE = process.env.APP_URL ?? "http://localhost:5199";
const B1 = "20000000-0000-0000-0000-000000000001";
const user = { id: "30000000-0000-0000-0000-000000000001", email: "staff@glow.test", aud: "authenticated", role: "authenticated", factors: [] };
const ws = { id: B1, name: "Glow Salon", industry: "Plumbing", role: "staff", timezone: "UTC", is_active: true, onboarding_status: "active",
  terminology: {}, modules: ["calendar", "calls"], receptionist: { name: "Ava", status: "active" }, phone_connected: true, voice_connected: true };
const NAV = { role: "staff", configured: true, industry: { slug: "plumbing", name: "Plumbing" }, operations_label: "Operations",
  modules: ["calendar", "calls"].map((slug) => ({ slug, available: true, enabled: true })) };
const TYPE = { id: "t1", business_id: B1, key: "jobs", singular: "Job", plural: "Jobs", position: 1, enabled: true, statuses: [{ key: "open", label: "Open" }], fields: [], columns: [], closed_statuses: [], link_person: false };
const RECORD = { id: "50000000-0000-0000-0000-000000000001", business_id: B1, type_key: "jobs", title: "Leaky tap", status: "open", data: {}, created_at: new Date().toISOString(), updated_at: new Date().toISOString(), customers: null };
const WAITING = { id: "60000000-0000-0000-0000-000000000001", path: `${B1}/${RECORD.id}/60000000-0000-0000-0000-000000000001.jpg`, file_name: "sink.jpg", mime_type: "image/jpeg",
  kind: "photo", caption: null, private: false, uploaded_by: user.id, created_at: new Date().toISOString(), status: "checking" };

let pass = 0, fail = 0;
const check = (ok, name) => { if (ok) { pass++; console.log("PASS " + name); } else { fail++; console.log("FAIL " + name); } };

async function open(b, { lead = () => ({ json: { result: "created", customer_id: "c1" } }), leadDelay = 0, files = () => [WAITING], check: fileCheck = () => ({ status: 200, json: { ok: true, status: "ready" } }) } = {}) {
  const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } });
  await ctx.addInitScript((u) => {
    const enc = (o) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
    const exp = Math.floor(Date.now() / 1000) + 3600;
    localStorage.setItem("sb-example-auth-token", JSON.stringify({ access_token: `${enc({ alg: "HS256" })}.${enc({ sub: u.id, aal: "aal2", exp, role: "authenticated" })}.sig`, refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp, user: u }));
  }, user);
  const p = await ctx.newPage(); p.setDefaultTimeout(8000);
  const log = { errors: [], lead: 0, customerWrites: 0, checks: 0, removes: 0, storageDeletes: 0 };
  p.on("pageerror", (e) => log.errors.push(e.message.slice(0, 200)));
  await p.route("**/auth/v1/**", (r) => r.fulfill({ json: { currentLevel: "aal2", nextLevel: "aal2" } }));
  await p.route("**/auth/v1/user**", (r) => r.fulfill({ json: { ...user, user_metadata: {} } }));
  await p.route("**/storage/v1/**", (r) => { if (r.request().method() === "DELETE") log.storageDeletes++; return r.fulfill({ json: [] }); });
  await p.route("**/rest/v1/**", async (r) => {
    const req = r.request(); const u = decodeURIComponent(req.url());
    const fn = u.includes("/rpc/") ? u.split("/rpc/")[1].split("?")[0] : null;
    if (u.includes("/rest/v1/customers") && ["POST", "PATCH", "PUT", "DELETE"].includes(req.method())) log.customerWrites++;
    if (fn === "zella_my_workspaces") return r.fulfill({ json: [ws] });
    if (fn === "zella_workspace_navigation") return r.fulfill({ json: NAV });
    if (fn === "zella_staff_add_lead") { log.lead++; if (leadDelay) await new Promise((res) => setTimeout(res, leadDelay)); const a = lead(); return r.fulfill({ status: a.status ?? 200, json: a.json }); }
    if (fn === "zella_remove_record_file") { log.removes++; return r.fulfill({ json: { id: WAITING.id, path: WAITING.path, status: "removed" } }); }
    // Batch 3: the records list is paged by the server
    if (fn === "zella_records_page") return r.fulfill({ json: { rows: [RECORD], total: 1, next: null } });
    if (u.includes("/rest/v1/crm_record_types")) return r.fulfill({ json: [TYPE] });
    if (u.includes("/rest/v1/crm_record_files")) return r.fulfill({ json: files(log) });
    if (u.includes("/rest/v1/crm_records")) return r.fulfill({ json: [RECORD], headers: { "content-range": "0-0/1" } });
    return r.fulfill({ json: fn ? null : [] });
  });
  await p.route("**/functions/v1/record-files", (r) => { log.checks++; const a = fileCheck(log); return r.fulfill({ status: a.status, json: a.json }); });
  await p.route("**/functions/v1/**", (r) => r.request().url().includes("record-files") ? r.fallback() : r.fulfill({ json: {} }));
  return { ctx, p, log };
}

async function openLead(p) {
  await p.goto(BASE + "/app"); await p.waitForSelector("button[title='Add lead']"); await p.click("button[title='Add lead']");
  await p.waitForSelector("#ba-add-lead");
  await p.fill("#ba-add-lead input >> nth=0", "Jamie");
  await p.fill("#ba-add-lead input[type=email], #ba-add-lead input[inputmode=email]", "jamie@example.test").catch(async () => p.fill("#ba-add-lead input >> nth=3", "jamie@example.test"));
}

(async () => {
  const b = await chromium.launch();

  // a slow save: clicking twice and pressing Enter sends one request; only the pipeline is used
  { const { ctx, p, log } = await open(b, { leadDelay: 1500 });
    await openLead(p);
    await p.click("button[form=ba-add-lead]"); await p.click("button[form=ba-add-lead]", { force: true }).catch(() => {});
    await p.press("#ba-add-lead input >> nth=0", "Enter").catch(() => {});
    await p.waitForSelector("text=Jamie was added", { timeout: 6000 }).catch(() => {});
    check(log.lead === 1, `lead: one request for a double submission (got ${log.lead})`);
    check(log.customerWrites === 0, "lead: nothing written to the customers table directly");
    check(await p.isVisible("text=Jamie was added"), "lead: success message shown");
    check(log.errors.length === 0, `lead: no page errors ${log.errors.join(" | ")}`);
    await ctx.close(); }

  // the pipeline isn't there: a clear error, no direct insert
  { const { ctx, p, log } = await open(b, { lead: () => ({ status: 404, json: { code: "PGRST202", message: "Could not find the function public.zella_staff_add_lead(...) in the schema cache" } }) });
    await openLead(p); await p.click("button[form=ba-add-lead]");
    await p.waitForSelector("#ba-add-lead .ba-error");
    const msg = await p.textContent("#ba-add-lead .ba-error");
    check(/isn't available/.test(msg) && !/schema cache|PGRST/.test(msg), `lead: missing pipeline explained plainly ("${msg.trim()}")`);
    check(log.customerWrites === 0, "lead: missing pipeline does not fall back to a direct insert");
    await ctx.close(); }

  // refused (viewer / other business): the server's refusal is shown, nothing else is tried
  { const { ctx, p, log } = await open(b, { lead: () => ({ status: 400, json: { code: "P0001", message: "NOT_ALLOWED" } }) });
    await openLead(p); await p.click("button[form=ba-add-lead]");
    await p.waitForSelector("#ba-add-lead .ba-error");
    check(/permission/.test(await p.textContent("#ba-add-lead .ba-error")) && log.customerWrites === 0 && log.lead === 1, "lead: a refusal is explained and nothing else is tried");
    await ctx.close(); }

  // a file whose check never answered: shown to its uploader as waiting; Check again makes it ready
  { let ready = false;
    const { ctx, p, log } = await open(b, { files: () => (ready ? [{ ...WAITING, status: "ready" }] : [WAITING]), check: () => { ready = true; return { status: 200, json: { ok: true, status: "ready" } }; } });
    await p.goto(BASE + "/app/records/jobs"); await p.waitForSelector("text=Leaky tap"); await p.click("text=Leaky tap");
    await p.waitForSelector(".ba-files-waiting");
    check(await p.isVisible(".ba-files-waiting >> text=Waiting for the file check"), "files: an unchecked upload is shown to its uploader as waiting");
    await p.click(".ba-files-waiting >> text=Check again");
    await p.waitForSelector(".ba-files-waiting", { state: "detached" });
    check(log.checks === 1 && !(await p.isVisible(".ba-files-waiting")), "files: Check again re-runs the check without uploading again, and the file becomes ready");
    await ctx.close(); }

  // the check is still unavailable: it stays waiting with an explanation; Discard removes it and its stored copy
  { let gone = false;
    const { ctx, p, log } = await open(b, { files: () => (gone ? [] : [WAITING]), check: () => ({ status: 503, json: { ok: false, error: "try_again" } }) });
    await p.goto(BASE + "/app/records/jobs"); await p.waitForSelector("text=Leaky tap"); await p.click("text=Leaky tap");
    await p.waitForSelector(".ba-files-waiting");
    await p.click(".ba-files-waiting >> text=Check again"); await p.waitForTimeout(500);
    const err = await p.textContent(".ba-error").catch(() => "");
    check(/hidden from your team|Check again/.test(err) && log.removes === 0, `files: a check that still fails keeps the file waiting, explained ("${err.trim().slice(0, 80)}")`);
    gone = true;
    await p.click(".ba-files-waiting >> text=Discard");
    await p.waitForSelector(".ba-files-waiting", { state: "detached" });
    check(log.removes === 1 && log.storageDeletes === 1, "files: Discard removes the waiting file and its stored copy");
    check(log.errors.length === 0, `files: no page errors ${log.errors.join(" | ")}`);
    await ctx.close(); }

  // a file the check refuses outright (wrong type on arrival) is discarded at once
  { const { ctx, p, log } = await open(b, { check: () => ({ status: 400, json: { ok: false, error: "BAD_FILE_TYPE" } }) });
    await p.goto(BASE + "/app/records/jobs"); await p.waitForSelector("text=Leaky tap"); await p.click("text=Leaky tap");
    await p.waitForSelector(".ba-files-waiting");
    await p.click(".ba-files-waiting >> text=Check again"); await p.waitForTimeout(600);
    check(log.removes === 1 && /Only photos/.test(await p.textContent(".ba-error").catch(() => "")), "files: a refused file is discarded with a clear reason");
    await ctx.close(); }

  await b.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
