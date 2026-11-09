// Batch 2: admin dashboard data states (B2-01 … B2-08) in a real browser against a STUBBED backend (canned answers;
// no database, nothing sent). Same build as admin-permissions.cjs:
//   cd web && VITE_SUPABASE_URL=https://example.supabase.co VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_stub npx vite build --outDir /tmp/zella-b1
//   npx vite preview --outDir /tmp/zella-b1 --port 5199 &        then:  node tests/browser/admin-batch2.cjs
const { chromium } = require("playwright");
const BASE = process.env.APP_URL ?? "http://localhost:5199";
const OWNER = { id: "30000000-0000-0000-0000-0000000000a1", email: "admin@zella.test" };
const OTHER = { id: "30000000-0000-0000-0000-0000000000a3", email: "owner2@zella.test" };
const ALL = ["businesses.view", "businesses.manage", "billing.view", "security.view", "security.manage", "platform.configure", "audit.view", "support.manage", "analytics.view"];
const ME = { role: "zella_owner", roleLabel: "Zella Voice owner", permissions: ALL, mfa: true, aal: "aal2" };

const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const token = (u) => { const exp = Math.floor(Date.now() / 1000) + 3600;
  return { access_token: `${enc({ alg: "HS256" })}.${enc({ sub: u.id, aal: "aal2", exp, role: "authenticated" })}.sig`, refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp,
    user: { id: u.id, email: u.email, aud: "authenticated", role: "authenticated", factors: [] } }; };
const subOf = (req) => { try { return JSON.parse(Buffer.from((req.headers().authorization ?? "").split(".")[1], "base64url").toString()).sub; } catch { return null; } };

let pass = 0, fail = 0;
const check = (ok, name) => { if (ok) { pass++; console.log("PASS " + name); } else { fail++; console.log("FAIL " + name); } };
const FAIL500 = { status: 500, json: { error: "Something went wrong" } };

// handlers: { action: (body, n, sub) => ({ json } | { status, json } | { delay, json }) }; n counts calls per action
async function open(b, handlers, { user = OWNER, width = 1366 } = {}) {
  const ctx = await b.newContext({ viewport: { width, height: 900 } });
  await ctx.addInitScript((t) => { if (!sessionStorage.getItem("b2-seeded")) { localStorage.setItem("sb-example-auth-token", JSON.stringify(t)); sessionStorage.setItem("b2-seeded", "1"); } }, token(user));
  const p = await ctx.newPage(); p.setDefaultTimeout(8000);
  const log = { errors: [], actions: [], n: {}, foreign: [] };
  p.on("pageerror", (e) => log.errors.push(e.message.slice(0, 200)));
  p.on("request", (req) => { const u = req.url(); if (!u.startsWith(BASE) && !u.includes("example.supabase.co") && !/fonts\.(googleapis|gstatic)\.com/.test(u)) log.foreign.push(u); });
  await p.route("**/auth/v1/**", (r) => r.fulfill({ json: { currentLevel: "aal2", nextLevel: "aal2" } }));
  await p.route("**/auth/v1/user**", (r) => { const sub = subOf(r.request()); const u = [OWNER, OTHER].find((x) => x.id === sub) ?? OWNER;
    return r.fulfill({ json: { id: u.id, email: u.email, aud: "authenticated", role: "authenticated", factors: [], user_metadata: {} } }); });
  await p.route("**/rest/v1/**", (r) => { const u = decodeURIComponent(r.request().url()); const fn = u.includes("/rpc/") ? u.split("/rpc/")[1].split("?")[0] : null;
    if (fn === "zella_admin_role") return r.fulfill({ json: "zella_owner" });
    return r.fulfill({ json: fn ? null : [] }); });
  await p.route("**/functions/v1/**", async (r) => {
    const body = JSON.parse(r.request().postData() || "{}"); const a = body.action;
    log.actions.push(a); log.n[a] = (log.n[a] ?? 0) + 1;
    if (a === "me_admin") return r.fulfill({ json: ME });
    const h = handlers[a]; const out = h ? h(body, log.n[a], subOf(r.request())) : { json: {} };
    if (out.delay) await new Promise((res) => setTimeout(res, out.delay));
    return r.fulfill({ status: out.status ?? 200, json: out.json });
  });
  return { ctx, p, log };
}
const txt = (p, sel = ".owner-content") => p.textContent(sel);
const statValues = (p) => p.$$eval(".owner-stat-card .owner-stat-value", (els) => els.map((e) => e.innerText.trim()));
const refresh = (p) => p.click(".owner-page-heading button:has-text('Refresh'), .owner-page-heading button:has-text('Run check')");

const OVERVIEW_ZERO = { stats: { totalBusinesses: 0, live: 0, setupsInProgress: 0, setupComplete: 0, pendingInvitations: 0, acceptedInvitations: 0, receptionistsLive: 0,
  callsLast30Days: 0, aiCallsLast30Days: 0, openTickets: 0, suspended: 0, cancelling: 0, cancelled: 0 }, attention: [], funnel: [], inProgress: [], activity: [], recentBusinesses: [] };
const OVERVIEW_SOME = { ...OVERVIEW_ZERO, stats: { ...OVERVIEW_ZERO.stats, totalBusinesses: 12, live: 4 }, recentBusinesses: [{ id: "40000000-0000-0000-0000-000000000001", name: "Fresh Fixtures Co", industry: "Plumbing", status: "active", createdAt: new Date().toISOString() }] };
const CONFIG = (over = {}) => [
  { key: "ZELLA_APP_URL", label: "App URL", set: true, required: true }, { key: "ZELLA_SERVER_SECRET_KEY", label: "Server key", set: true, required: true },
  { key: "N8N_WEBHOOK_URL", label: "n8n (automations and emails)", set: false, required: false }, { key: "VAPI_API_KEY", label: "Vapi", set: false, required: false },
].map((c) => ({ ...c, ...(over[c.key] ?? {}) }));
const HEALTH0 = { businesses: 2, failedSetups: 0, failedInvites: 0, brokenIntegrations: 0, urgentTickets: 0, auditLast24h: 0, callsLast24h: 0, activeIndustries: 28 };
const status = (health = HEALTH0, config = CONFIG()) => ({ json: { health, configuration: config, checkedAt: new Date().toISOString(), me: {} } });
const AUTO = (dispatchEnabled) => ({ json: { workflows: [], deadLetters: 0, dispatch: [], failures: [], n8n: { url: false, dispatchEnabled, baseUrlSet: false } } });

(async () => {
  const b = await chromium.launch();

  // ---------------- B2-01 Overview ----------------
  { const { ctx, p, log } = await open(b, { overview_data: () => ({ json: OVERVIEW_ZERO }) });
    await p.goto(BASE + "/"); await p.waitForSelector("text=Nothing needs attention right now.");
    const v = await statValues(p);
    check(v.slice(0, 7).every((x) => x === "0") && v[7] === "0 / 0", `B2-01 valid zeros render 0 (${v.join(",")})`);
    check(await p.isVisible("text=Create your first business"), "B2-01 a real empty answer offers 'Create your first business'");
    check(log.errors.length === 0, "B2-01 no page errors");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { overview_data: () => ({ json: { stats: {}, attention: null } }) });
    await p.goto(BASE + "/"); await p.waitForSelector("[data-load-updated]");
    const v = await statValues(p);
    check(!v.some((x) => /^0$|^0 \//.test(x)) && v.every((x) => x.includes("—")), `B2-01 missing values don't render 0 (${v.join(",")})`);
    check(!(await p.isVisible("text=Nothing needs attention right now.")) && !(await p.isVisible("text=Create your first business")), "B2-01 a missing list isn't shown as 'nothing'");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { overview_data: () => FAIL500 });
    await p.goto(BASE + "/"); await p.waitForSelector("[data-load=failed]");
    const v = await statValues(p); const t = await txt(p);
    check(v.every((x) => x.includes("—")), `B2-01 initial failure: no metric values (${v.join(",")})`);
    check(!/Nothing needs attention|No setups in progress|No activity recorded|No businesses yet/.test(t) && !(await p.isVisible("text=Create your first business")), "B2-01 initial failure: no empty-state success messages");
    check(await p.isVisible("[data-load=failed] >> text=Retry"), "B2-01 initial failure shows an error with Retry");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { overview_data: (_b, n) => (n === 2 ? FAIL500 : { json: OVERVIEW_SOME }) });
    await p.goto(BASE + "/"); await p.waitForSelector("text=Fresh Fixtures Co");
    await refresh(p); await p.waitForSelector("[data-load=stale]");
    check((await statValues(p))[0] === "12" && await p.isVisible("text=Fresh Fixtures Co"), "B2-01 failed refresh keeps the last result");
    check(/may be out of date/.test(await txt(p, "[data-load=stale]")) && await p.isVisible("text=Last updated"), "B2-01 failed refresh marks the data stale with its time");
    await p.click("[data-load=stale] >> text=Retry"); await p.waitForSelector("[data-load=stale]", { state: "detached" });
    check(!(await p.isVisible("[data-load]")), "B2-01 successful retry clears the warning");
    await ctx.close(); }

  // ---------------- B2-02 Platform operations ----------------
  { const { ctx, p } = await open(b, { platform_status: () => status(), automation_overview: () => AUTO(true) });
    await p.goto(BASE + "/operations"); await p.waitForSelector("[data-health]");
    const t = await txt(p, ".po-banner");
    check(await p.getAttribute(".po-banner", "data-health") === "clear" && /No issues found in the checks below/.test(t) && /doesn't test whether/.test(t), `B2-02 zero problems: scoped wording ("${t.slice(0, 60)}…")`);
    check(!/All systems normal/.test(await txt(p)), "B2-02 never says 'All systems normal'");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { platform_status: () => status(HEALTH0, CONFIG({ ZELLA_APP_URL: { set: false } })), automation_overview: () => AUTO(true) });
    await p.goto(BASE + "/operations"); await p.waitForSelector("[data-health]");
    check(await p.getAttribute(".po-banner", "data-health") === "issues" && /required setting/.test(await txt(p, ".po-banner")), "B2-02 missing required configuration is an issue in the banner");
    check(await p.getAttribute("[data-service=ZELLA_APP_URL]", "data-service-state") === "missing_required" && await p.isVisible("[data-service=ZELLA_APP_URL] >> text=Missing (required)"), "B2-02 missing configuration is visible on its line");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { platform_status: () => status({ businesses: 2 }), automation_overview: () => AUTO(true) });
    await p.goto(BASE + "/operations"); await p.waitForSelector("[data-health]");
    check(await p.getAttribute(".po-banner", "data-health") === "incomplete", "B2-02 missing counts make the check incomplete, not clean");
    check((await p.$$eval(".po-count .op-pill", (els) => els.map((e) => e.innerText))).every((x) => x === "Unknown"), "B2-02 unknown counts show 'Unknown', not 'None'");
    check((await statValues(p))[3] === "—", "B2-02 'Open problems' isn't 0 when counts are missing");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { platform_status: () => FAIL500, automation_overview: () => AUTO(true) });
    await p.goto(BASE + "/operations"); await p.waitForSelector("[data-health=failed]");
    const t = await txt(p);
    check(!/None found|No issues found/.test(t) && (await statValues(p)).every((x) => x === "—"), "B2-02 failed request: no zero problems, no metrics");
    check(await p.isVisible("[data-load=failed] >> text=Retry"), "B2-02 failed request: error with Retry");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { platform_status: () => status(), automation_overview: () => AUTO(false) });
    await p.goto(BASE + "/operations"); await p.waitForSelector("[data-service=N8N_WEBHOOK_URL]");
    await p.waitForFunction(() => document.querySelector("[data-service=N8N_WEBHOOK_URL]")?.getAttribute("data-service-state") === "disabled").catch(() => {});
    check(await p.getAttribute("[data-service=N8N_WEBHOOK_URL]", "data-service-state") === "disabled" && await p.isVisible("text=Turned off on purpose"), "B2-02 inactive development automation: 'Turned off on purpose'");
    check(await p.getAttribute(".po-banner", "data-health") === "clear", "B2-02 switched-off automation isn't counted as broken");
    await ctx.close(); }
  { const { ctx, p, log } = await open(b, { platform_status: () => status(), automation_overview: () => FAIL500 });
    await p.goto(BASE + "/operations"); await p.waitForFunction(() => document.querySelector("[data-service=N8N_WEBHOOK_URL]")?.getAttribute("data-service-state") === "unknown").catch(() => {});
    check(await p.getAttribute("[data-service=N8N_WEBHOOK_URL]", "data-service-state") === "unknown" && await p.getAttribute(".po-banner", "data-health") === "incomplete", "B2-02 unknown automation status isn't shown as healthy");
    check(log.actions.includes("failed_events_list"), "B2-02 Platform monitoring still loads (failed events)");
    await ctx.close(); }

  // ---------------- B2-03 Integrations ----------------
  { const { ctx, p, log } = await open(b, { integrations_overview: () => ({ json: { connections: [], requests: [] } }) });
    await p.goto(BASE + "/integrations"); await p.waitForSelector("text=Nothing connected yet");
    check((await statValues(p)).every((x) => x === "0") && await p.isVisible("text=No business has completed"), "B2-03 no connections + success: valid empty state and 0");
    check(log.foreign.length === 0 && log.actions.every((a) => ["me_admin", "integrations_overview", "alerts_list"].includes(a)), `B2-03 no provider requests or connection actions (${[...new Set(log.actions)].join(",")}${log.foreign.length ? "; " + log.foreign[0] : ""})`);
    await ctx.close(); }
  { const CONN = { id: "c1", business_id: "b1", business_name: "Pipes Ltd", provider: "telnyx", integration_type: "phone", status: "active", last_synced_at: null, error_message: null };
    const { ctx, p } = await open(b, { integrations_overview: (_b, n) => (n === 1 ? FAIL500 : n === 2 ? { json: { connections: [CONN], requests: [] } } : n === 3 ? FAIL500 : { json: { connections: [CONN, { ...CONN, id: "c2", status: "error" }], requests: [] } }) });
    await p.goto(BASE + "/integrations"); await p.waitForSelector("[data-load=failed]");
    check((await statValues(p)).every((x) => x === "—") && !(await p.isVisible("text=Nothing connected yet")) && /Not available/.test(await txt(p)), "B2-03 API failure: error state, not zero connections");
    await p.click("[data-load=failed] >> text=Retry"); await p.waitForSelector("text=Pipes Ltd");
    check((await statValues(p))[0] === "1", "B2-03 retry after failure loads the data");
    await refresh(p); await p.waitForSelector("[data-load=stale]");
    check(await p.isVisible("text=Pipes Ltd") && await p.isVisible("text=Last updated"), "B2-03 failed refresh: stale warning, previous rows kept, last refresh time shown");
    await p.click("[data-load=stale] >> text=Retry"); await p.waitForSelector("[data-load=stale]", { state: "detached" });
    check((await statValues(p))[0] === "2" && (await statValues(p))[2] === "1", "B2-03 successful retry restores current data");
    await ctx.close(); }

  // ---------------- B2-04 AI receptionists ----------------
  const agent = (over) => ({ agentId: "a" + Math.random(), businessId: "b1", businessName: "Alpha Plumbing", industry: "Plumbing", stage: "active", name: "Ava", services: 1, faqs: 1,
    status: "active", checks: { knowledge: true, hours: true, greeting: true, phone: false, voice: false }, ready: 3, aiCallsLast30Days: 0, lastCallAt: null, ...over });
  { const { ctx, p } = await open(b, { agents_list: () => FAIL500 });
    await p.goto(BASE + "/agents"); await p.waitForSelector("[data-load=failed]");
    check((await statValues(p))[1] === "—" && !/No AI receptionists yet/.test(await txt(p)), "B2-04 failed request: no live count, never 'no agents'");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { agents_list: () => ({ json: { agents: [agent({}), agent({ businessName: "Beta Salon", status: "paused" })], stats: { total: 2, readyToConnect: 1, missingKnowledge: 0 } } }) });
    await p.goto(BASE + "/agents"); await p.waitForSelector("text=Beta Salon");
    const v = await statValues(p);
    check(v[1] === "0", `B2-04 a real zero live count shows 0 (${v.join(",")})`);
    const pill = (await p.textContent("tr:has-text('Alpha Plumbing') .op-pill")).trim();
    check(pill === "Not connected", `B2-04 'active' without phone and voice isn't labelled Live (pill: "${pill}")`);
    await p.fill(".ag-search", "beta"); check(await p.isVisible("text=Beta Salon") && !(await p.isVisible("text=Alpha Plumbing")), "B2-04 search still works");
    await p.fill(".ag-search", ""); await p.click(".ag-filters >> text=Live");
    check(await p.isVisible("text=No receptionists match this filter."), "B2-04 Live filter matches the Live label");
    await p.getByRole("tab", { name: "Not live", exact: true }).click();
    check(await p.isVisible("text=Alpha Plumbing") && await p.isVisible("text=Beta Salon"), "B2-04 Not live includes disconnected and paused agents");
    await p.click(".ag-filters >> text=All"); check(await p.isVisible("text=Alpha Plumbing") && await p.isVisible("text=Beta Salon"), "B2-04 filters still work");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { agents_list: () => ({ json: { agents: [agent({ checks: { knowledge: true, hours: true, greeting: true, phone: true, voice: true } })], stats: { total: 1 } } }) });
    await p.goto(BASE + "/agents"); await p.waitForSelector("text=Alpha Plumbing");
    check((await statValues(p))[1] === "1" && await p.isVisible("tr:has-text('Alpha Plumbing') >> .op-pill:has-text('Live')"), "B2-04 active with phone and voice connected is Live");
    check((await statValues(p))[2] === "—", "B2-04 a statistic missing from the answer shows —");
    await ctx.close(); }

  // ---------------- B2-05 Modules ----------------
  { const { ctx, p } = await open(b, { modules_overview: (_b, n) => (n === 1 ? FAIL500 : { json: { modules: [{ slug: "calls", name: "Calls", description: "", offeredIn: ["Plumbing"], hiddenIn: [], requires: [], businesses: 3 }], industries: 28 } }) });
    await p.goto(BASE + "/modules"); await p.waitForSelector("[data-load=failed]");
    check(!(await p.isVisible("text=No modules configured yet.")) && /Not available/.test(await txt(p)), "B2-05 API failure isn't shown as an empty catalog");
    const loads = await p.evaluate(() => performance.getEntriesByType("navigation").length);
    await p.click("[data-load=failed] >> text=Retry"); await p.waitForSelector("text=Calls");
    check(await p.evaluate(() => performance.getEntriesByType("navigation").length) === loads && !(await p.isVisible("[data-load]")), "B2-05 Retry succeeds without a page reload");
    check(await p.isVisible("text=Edit in Industry configuration"), "B2-05 link to Industry configuration kept");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { modules_overview: () => ({ json: { modules: [], industries: 28 } }) });
    await p.goto(BASE + "/modules"); await p.waitForSelector("text=No modules configured yet.");
    check(true, "B2-05 valid empty response shows the empty state");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { modules_overview: (_b, n) => (n === 2 ? FAIL500 : { json: { modules: [{ slug: "calls", name: "Calls", description: "", offeredIn: [], hiddenIn: [], requires: [], businesses: 3 }], industries: 28 } }) });
    await p.goto(BASE + "/modules"); await p.waitForSelector("text=Calls"); await refresh(p); await p.waitForSelector("[data-load=stale]");
    check(await p.isVisible("text=Calls"), "B2-05 failed refresh keeps the catalog, marked stale");
    await ctx.close(); }

  // ---------------- B2-06 Verification ----------------
  const DOC = { id: "d1", business_id: "b1", business_name: "Alpha Plumbing", business_status: "owner_setup", kind: "business_registration", file_name: "registration.pdf", size_bytes: 20480, created_at: new Date().toISOString(), status: "pending_review" };
  { let reviewed = false;
    const { ctx, p, log } = await open(b, { documents_queue: () => ({ json: { available: true, documents: reviewed ? [] : [DOC], totals: { pending_review: reviewed ? 0 : 1 } } }),
      document_review: () => { reviewed = true; return { delay: 800, json: { ok: true } }; } });
    await p.goto(BASE + "/verification"); await p.waitForSelector("text=registration.pdf");
    await p.click("tr:has-text('registration.pdf') >> button:has-text('Verify')");
    await p.waitForSelector("[data-dialog=verify]");
    await p.keyboard.press("Shift+Tab");
    check(await p.evaluate(() => document.activeElement?.textContent) === "Confirm: mark verified", "B2-06 Verify Shift+Tab wraps to Confirm");
    await p.keyboard.press("Tab");
    check(await p.evaluate(() => document.activeElement?.textContent) === "Cancel", "B2-06 Verify Tab wraps to Cancel");
    const d = await txt(p, "[data-dialog=verify]");
    check(/Alpha Plumbing/.test(d) && /Business registration/.test(d) && /registration\.pdf/.test(d) && /Mark as verified/.test(d), "B2-06 Verify opens a confirmation with business, document, file and action");
    check(await p.evaluate(() => document.activeElement?.innerText) === "Cancel", "B2-06 focus starts on Cancel");
    await p.click("[data-dialog=verify] >> text=Cancel");
    check(!(await p.isVisible("[data-dialog=verify]")) && !log.actions.includes("document_review"), "B2-06 Cancel makes no review request");
    await p.waitForTimeout(150);
    check(await p.evaluate(() => document.activeElement?.innerText) === "Verify", "B2-06 focus returns to the Verify button");
    await p.click("tr:has-text('registration.pdf') >> button:has-text('Verify')"); await p.waitForSelector("[data-dialog=verify]");
    await p.keyboard.press("Escape");
    check(!(await p.isVisible("[data-dialog=verify]")) && !log.actions.includes("document_review"), "B2-06 Escape closes without a request");
    const before = log.n.documents_queue;
    await p.click("tr:has-text('registration.pdf') >> button:has-text('Verify')"); await p.waitForSelector("[data-dialog=verify]");
    await p.locator('[data-dialog=verify] button:has-text("Confirm")').evaluate((button) => {
      button.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      button.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await p.waitForSelector("[data-dialog=verify]", { state: "detached" });
    check(log.n.document_review === 1, `B2-06 Confirm sends exactly one review request (got ${log.n.document_review})`);
    await p.waitForSelector("text=Nothing waiting for review.");
    check(log.n.documents_queue > before && await p.isVisible("text=marked verified"), "B2-06 successful review refreshes the queue");
    check(await p.evaluate(() => document.activeElement?.tagName === "H1" && document.activeElement.textContent === "Verification"), "B2-06 successful Verify focuses persistent heading");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { documents_queue: () => ({ json: { available: true, documents: [DOC], totals: { pending_review: 1 } } }), document_review: () => ({ status: 403, json: { error: "Your admin role doesn't allow this." } }) });
    await p.goto(BASE + "/verification"); await p.waitForSelector("text=registration.pdf");
    await p.click("tr:has-text('registration.pdf') >> button:has-text('Verify')"); await p.click("[data-dialog=verify] >> button:has-text('Confirm')");
    await p.waitForSelector("[data-dialog=verify] [role=alert]");
    check(/doesn't allow/.test(await txt(p, "[data-dialog=verify] [role=alert]")) && await p.isVisible("tr:has-text('registration.pdf') >> text=Waiting for review") && !(await p.isVisible("text=marked verified")), "B2-06 failure shows the error and the document isn't shown as verified");
    await ctx.close(); }
  { const { ctx, p, log } = await open(b, { documents_queue: () => ({ json: { available: true, documents: log?.n?.document_review ? [] : [DOC], totals: { pending_review: 1 } } }), document_review: () => ({ json: { ok: true } }) });
    await p.goto(BASE + "/verification"); await p.waitForSelector("text=registration.pdf");
    await p.click("tr:has-text('registration.pdf') >> button:has-text('Reject')");
    await p.fill(".owner-modal input", "Name doesn't match");
    await p.keyboard.press("Shift+Tab");
    check(await p.evaluate(() => document.activeElement?.textContent) === "Reject document", "B2-06 Reject Shift+Tab wraps to submit");
    await p.keyboard.press("Tab");
    check(await p.evaluate(() => document.activeElement?.tagName) === "INPUT", "B2-06 Reject Tab wraps to reason");
    await p.keyboard.press("Escape");
    await p.waitForFunction(() => document.activeElement?.textContent === "Reject");
    check(!log.n.document_review, "B2-06 Reject Escape restores focus without reviewing");
    await p.click("tr:has-text('registration.pdf') >> button:has-text('Reject')");
    await p.fill(".owner-modal input", "Name doesn't match"); await p.click(".owner-modal >> button:has-text('Reject document')");
    await p.waitForSelector(".owner-modal", { state: "detached" });
    check(log.n.document_review === 1, "B2-06 rejection with a reason still works");
    await p.waitForSelector("text=Nothing waiting for review.");
    await p.waitForFunction(() => document.activeElement?.tagName === "H1");
    check(await p.evaluate(() => document.activeElement?.textContent) === "Verification", "B2-06 successful Reject focuses persistent heading");
    await ctx.close(); }

  // ---------------- B2-07 Users & access ----------------
  { const ROLES = { catalog: [["businesses.view", "See businesses, setup status and platform health"], ["support.manage", "Support tickets and platform alerts"]],
      roles: [{ key: "support_admin", permissions: ["businesses.view", "support.manage"] }, { key: "read_only_admin", permissions: [] }] };
    const { ctx, p, log } = await open(b, { admins_list: () => ({ json: { me: { role: "zella_owner" }, admins: [] } }), roles_get: () => ({ json: ROLES }),
      admin_invite: (body) => ({ json: { invited: true, email: body.email } }) });
    await p.goto(BASE + "/users"); await p.click("text=Add admin"); await p.waitForSelector("[data-role-explanation]");
    const ex = () => txt(p, "[data-role-explanation]");
    check(!/full access to every client business\. If/.test(await txt(p, ".wiz-section")), "B2-07 the blanket 'full access' sentence is gone");
    check(/except adding or removing admins/.test(await ex()), "B2-07 super admin: accurate explanation");
    await p.selectOption(".wiz-section select", "zella_owner");
    check(/add, change and remove platform admins/.test(await ex()), "B2-07 owner: accurate explanation; switching updates it");
    await p.selectOption(".wiz-section select", "support_admin");
    const s = await ex();
    check(/Only: See businesses.*Support tickets/.test(s) && !/Full access/.test(s), `B2-07 restricted role: its real permissions ("${s.slice(0, 70)}…")`);
    await p.selectOption(".wiz-section select", "read_only_admin");
    check(/No permissions yet/.test(await ex()), "B2-07 restricted role with no permissions says so");
    await p.fill(".wiz-section input[type=email], .wiz-section input", "new@zella.test"); await p.click(".wiz-section button[type=submit]");
    await p.waitForSelector(".ic-notice");
    check(log.n.admin_invite === 1 && /as Read-only admin/.test(await txt(p, ".ic-notice")), "B2-07 invitation unchanged (one request) and confirmation names the role");
    await ctx.close(); }

  { const { ctx, p } = await open(b, {
      admins_list: () => ({ json: { me: { role: "zella_owner" }, admins: [{ user_id: "a2", email: "existing@zella.test", role: "super_admin", is_active: true }] } }),
      roles_get: () => ({ delay: 2500, json: { catalog: [["support.manage", "Support tickets"]], roles: [{ key: "support_admin", permissions: ["support.manage"] }] } }),
      admin_invite: (body) => ({ json: { invited: true, resent: true, email: body.email } }),
    });
    await p.goto(BASE + "/users");
    await p.selectOption(".us-role", "support_admin");
    check(/couldn't be loaded/.test(await txt(p, ".ic-warning")), "B2-07 confirmation initially explains unavailable definitions");
    await p.waitForFunction(() => document.querySelector(".ic-warning")?.textContent.includes("Only: Support tickets"));
    check(!/couldn't be loaded/.test(await txt(p, ".ic-warning")), "B2-07 open confirmation updates when definitions arrive");
    await p.click(".ic-warning button:has-text('Cancel')");
    await p.click("text=Add admin");
    await p.fill(".wiz-section input", "existing@zella.test");
    await p.click(".wiz-section button[type=submit]");
    await p.waitForSelector(".ic-notice");
    const notice = await txt(p, ".ic-notice");
    check(/re-emailed/.test(notice) && /existing role was not changed/.test(notice) && !/as Super admin/.test(notice), "B2-07 resend notice preserves existing role");
    await ctx.close(); }

  // ---------------- B2-08 Businesses ----------------
  const BIZ = (name) => ({ businesses: [{ id: "40000000-0000-0000-0000-0000000000b1", name, industry_id: "i1", onboarding_status: "active", is_active: true, invitations: [], created_at: new Date().toISOString() }],
    industries: [{ id: "i1", name: "Plumbing" }], stats: { totalBusinesses: 1, activeWorkspaces: 1, pendingInvitations: 0, provisioningIssues: 0 } });
  { const { ctx, p } = await open(b, { dashboard_data: () => FAIL500 });
    await p.goto(BASE + "/businesses"); await p.waitForSelector("text=Unable to load businesses");
    check((await statValues(p)).every((x) => x === "—"), "B2-08 initial failure: no statistics");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { dashboard_data: (_b, n) => (n === 2 ? FAIL500 : n === 1 ? { json: BIZ("Old Name Plumbing") } : { json: BIZ("New Name Plumbing") }) });
    await p.goto(BASE + "/businesses"); await p.waitForSelector("text=Old Name Plumbing");
    await p.click(".owner-panel-heading button:has-text('Refresh')"); await p.waitForSelector("[data-load=stale]");
    check(await p.isVisible("text=Old Name Plumbing") && /may be out of date/.test(await txt(p, "[data-load=stale]")) && (await statValues(p))[0] === "1", "B2-08 failed refresh keeps the list, labelled stale");
    await p.click("[data-load=stale] >> text=Retry"); await p.waitForSelector("text=New Name Plumbing");
    check(!(await p.isVisible("[data-load=stale]")), "B2-08 Retry updates the list and clears the warning");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { dashboard_data: (_b, _n, sub) => (sub === OTHER.id ? { delay: 2500, json: BIZ("Second Account Biz") } : { json: BIZ("First Account Biz") }) });
    await p.goto(BASE + "/businesses"); await p.waitForSelector("text=First Account Biz");
    const other = await ctx.newPage(); await other.goto(BASE + "/status").catch(() => {});
    await other.evaluate((t) => { localStorage.setItem("sb-example-auth-token", JSON.stringify(t)); new BroadcastChannel("sb-example-auth-token").postMessage({ event: "SIGNED_IN", session: t }); }, token(OTHER));
    await p.waitForFunction(() => !document.body.innerText.includes("First Account Biz"), null, { timeout: 4000 }).catch(() => {});
    check(!(await p.isVisible("text=First Account Biz")), "B2-08 account switch: the first account's businesses disappear before the second's load");
    await p.waitForSelector("text=Second Account Biz", { timeout: 8000 }).catch(() => {});
    check(await p.isVisible("text=Second Account Biz") && !(await p.isVisible("text=First Account Biz")), "B2-08 account switch: only the second account's businesses are shown");
    await ctx.close(); }
  { const { ctx, p } = await open(b, { dashboard_data: () => ({ json: BIZ("Signed Out Biz") }) });
    await p.goto(BASE + "/businesses"); await p.waitForSelector("text=Signed Out Biz");
    await p.click(".owner-signout"); await p.waitForTimeout(600);
    check(!(await p.isVisible("text=Signed Out Biz")) && (await p.$$(".owner-nav-item")).length === 0, "B2-08 sign-out clears the business list");
    await ctx.close(); }

  for (const olderFails of [false, true]) {
    const { ctx, p, log } = await open(b, { dashboard_data: (_b, n) => n === 1 ? { json: BIZ("Initial Biz") } : n === 2
      ? { delay: 1200, ...(olderFails ? FAIL500 : { json: BIZ("Obsolete Biz") }) }
      : { delay: 2200, json: BIZ("Latest Biz") } });
    await p.goto(BASE + "/businesses"); await p.waitForSelector("text=Initial Biz");
    await p.click(".owner-panel-heading button:has-text('Refresh')");
    await p.waitForFunction(() => document.querySelector(".owner-panel-heading")?.textContent.includes("Loading..."));
    await p.click(".owner-nav-item:has-text('Overview')");
    await p.click(".owner-nav-item:has-text('Businesses')");
    await p.waitForTimeout(1500);
    check(log.n.dashboard_data === 3 && await p.isVisible("text=Initial Biz") && !(await p.isVisible("text=Obsolete Biz")) && !(await p.isVisible("[data-load=stale]")) && await p.isDisabled(".owner-panel-heading button:has-text('Loading')"), `B2-08 older ${olderFails ? "error" : "success"} cannot apply state or end newer loading`);
    await p.waitForSelector("text=Latest Biz");
    check(!(await p.isVisible("[data-load=stale]")), "B2-08 latest overlapping request wins");
    await ctx.close();
  }

  await b.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
