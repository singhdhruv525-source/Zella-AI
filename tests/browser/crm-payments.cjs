// Paying from inside the CRM (owner decision, 27 Nov 2026: "auto charge plus Pay now") in a real browser, against the
// billing stand in (web/src/billing/fakeBillingApi.js), which mounts a static picture of Stripe's form and never loads
// Stripe.js. Inside the CRM shell (owner, 27 Nov 2026): Settings, Billing and subscription, Invoices and payments, and each
// payment's own page (/app/settings/billing/pay/<id>, /app/settings/billing/pack/<code>). The CRM's backend is a stub in
// this script (a signed in owner of the stand in business, canned answers); billing-api is never called, and every other
// request off this machine is refused and counted.
//
// In every Zella Voice look, at 1440x900, 390 and 320 wide:
//   list ............ the renewal line with the saved card, Update card, invoices with Pay now, packs with Buy
//   paying .......... Pay now: the glass checkout, Payment details with the picture of Stripe's form and our Pay button
//   processing ...... after paying: "Confirming your payment"
//   confirmed ....... only after the server's later look: "Payment received", the card with issuer, brand and last 4
//   already-paid .... the emailed link for a paid invoice: "This is paid", nothing to pay
//   update-card ..... back from Stripe's card page: the note, the card Stripe has
//   pack-confirm .... buying a pack: the confirm panel with the price and the card it is charged to
//   pack-action ..... the bank wants to confirm: "Confirm with your bank" (then the same intent in Stripe's form)
//   pack-added ...... only after the server grants it
//   no-card ......... no card saved: "There's no card to charge" with Update card
// Each shot: no horizontal scroll, AA contrast from rendered pixels, axe on the page card, no input of ours, and the card
// never shows the Zella Voice name or digits before a payment the server confirmed.
//
// Build and serve a LOCAL copy as in stripe-pay-screen.cjs, then:
//   APP_URL=http://localhost:5150 SHOTS=<folder> [VIDEO=<folder>] node tests/browser/crm-payments.cjs
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const { loadAxe } = require("./axe.cjs");
const { enforcePayPageCsp, watchCsp, cspViolations, LOOKS, contrast, axeCard, overflow, cardText, zellaOnCard, mockHasInputs, fillCard, waitFilled, onlyLast4AndExpiry, addressMock } = require("./pay-helpers.cjs");
const APP = process.env.APP_URL ?? "http://localhost:5150";
const SHOTS = process.env.SHOTS ?? path.join(process.cwd(), "crm-pay-shots");
if (!["localhost", "127.0.0.1"].includes(new URL(APP).hostname)) { console.error("APP_URL must be a local preview"); process.exit(2); }
fs.mkdirSync(SHOTS, { recursive: true });
let fails = 0, passes = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); if (ok) passes++; else fails++; };
const BIZ = "00000000-0000-4000-8000-0000000000b1", OPEN = "00000000-0000-4000-8000-0000000000e2";
const WIDTHS = [{ name: "1440", viewport: { width: 1440, height: 900 } }, { name: "390", viewport: { width: 390, height: 844 } }, { name: "320", viewport: { width: 320, height: 700 } }];

// the CRM's stubbed backend: a signed in owner (or a team member) of the stand in business
const USER = { id: "00000000-0000-4000-8000-0000000000a1", email: "owner@example.test" };
const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const token = () => { const exp = Math.floor(Date.now() / 1000) + 3600;
  return { access_token: `${enc({ alg: "HS256" })}.${enc({ sub: USER.id, aal: "aal2", exp, role: "authenticated" })}.sig`, refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp,
    user: { id: USER.id, email: USER.email, aud: "authenticated", role: "authenticated", factors: [] } }; };
const workspace = (role) => ({ id: BIZ, name: "Maple Street Salon", industry: "Salon", role, timezone: "UTC", is_active: true, onboarding_status: "active", terminology: {},
  modules: ["calendar", "calls"], receptionist: { name: "Ava", status: "active" }, phone_connected: true, voice_connected: true });
const NAV = (role) => ({ role, configured: true, industry: { slug: "salon", name: "Salon" }, operations_label: "Operations",
  modules: ["calendar", "calls"].map((slug) => ({ slug, available: true, enabled: true })) });

// the owner finished onboarding (the stand in's own record, so the CRM shows no "finish setting up" banner)
const seeds = new Map();
async function seedDone(scenario) {
  if (seeds.has(scenario)) return seeds.get(scenario);
  const { createFakeApi } = await import(path.join(__dirname, "../../web/src/onboarding/fakeApi.js"));
  const mem = new Map(); const storage = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) };
  const api = createFakeApi({ scenario, storage, delay: 0 });
  const id = (await api.listBusinesses()).businesses[0].business_id;
  await api.completeStep(id, "welcome"); await api.setPassword("A good pass 1!"); await api.finishMfa("x", "123456"); await api.completeStep(id, "security");
  const shown = await api.getState(id);
  for (const k of ["business", "hours_services", "team", "receptionist_phone"]) await api.answerSection(id, k, "looks_right", null, shown.details.sections.find((x) => x.key === k).data_hash);
  await api.completeStep(id, "details"); api.approveIdentity(); await api.completeStep(id, "identity");
  const st = await api.getState(id); await api.acceptPlan(id, st.plan.current.version);
  await api.completeStep(id, "payment"); await api.completeStep(id, "done");
  seeds.set(scenario, [...mem.entries()]);
  return seeds.get(scenario);
}

async function open(browser, look, viewport, url, { video = null, role = "owner" } = {}) {
  const seeded = await seedDone(new URL(url, "http://x").searchParams.get("scenario") ?? "");
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1, ...(video ? { recordVideo: { dir: video, size: viewport } } : {}) });
  const hits = [];
  await ctx.route((u) => ["http:", "https:"].includes(u.protocol), async (route) => {
    const req = route.request(), u = new URL(req.url());
    if (["localhost", "127.0.0.1"].includes(u.hostname)) return enforcePayPageCsp(ctx, route);
    if (["fonts.googleapis.com", "fonts.gstatic.com"].includes(u.hostname)) return route.continue();
    if (u.hostname === "zlocal.supabase.co" && !u.pathname.startsWith("/functions/")) {   // the CRM's stub (never billing-api)
      if (u.pathname.startsWith("/auth/v1/user")) return route.fulfill({ json: { id: USER.id, email: USER.email, aud: "authenticated", role: "authenticated", user_metadata: {}, factors: [] } });
      if (u.pathname.startsWith("/auth/v1/")) return route.fulfill({ json: { currentLevel: "aal2", nextLevel: "aal2", all: [], totp: [] } });
      const fn = u.pathname.includes("/rpc/") ? u.pathname.split("/rpc/")[1] : null;
      if (fn === "zella_my_workspaces") return route.fulfill({ json: [workspace(role)] });
      if (fn === "zella_workspace_navigation") return route.fulfill({ json: NAV(role) });
      return route.fulfill({ json: fn ? null : [], headers: { "content-range": "*/0" } });
    }
    hits.push(`${req.method()} ${u.hostname}${u.pathname}`);
    return route.fulfill({ status: 503, contentType: "application/json", body: "{}" });
  });
  await watchCsp(ctx);
  await ctx.addInitScript(([pref, tok, entries]) => {
    localStorage.setItem("sb-zlocal-auth-token", tok);
    for (const [k, v] of entries) localStorage.setItem(k, v);
    if (pref && !sessionStorage.getItem("look")) { localStorage.setItem("zella.appearance.crm", JSON.stringify({ user: null, pref })); sessionStorage.setItem("look", "1"); }
  }, [look.pref, JSON.stringify(token()), seeded]);
  const page = await ctx.newPage();
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`${APP}${url}`);
  await page.waitForSelector(".ba-content", { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(500);
  return { ctx, page, hits, errors };
}

async function shot(page, look, width, state, axeSource) {
  const file = path.join(SHOTS, `crm-${look.name}-${state}-${width.name}.png`);
  // a dialog is fixed to the window: the window is what the person sees (a full page capture re-lays it out)
  const dialog = await page.evaluate(() => [...document.querySelectorAll("[role=dialog][aria-modal=true]")].some((d) => ((r) => r.width > 0 && r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight)(d.getBoundingClientRect()) && getComputedStyle(d).visibility === "visible"));
  // inside the CRM shell the top bar and the sidebar stay put, so a full page capture would draw them over the page:
  // the window is captured, from the top (the shell, the title and the payment), as a person first sees it
  if (!dialog) { await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(200); }
  await page.screenshot({ path: file });
  const tag = `${look.name} ${width.name} ${state}`;
  check(`${tag}: no horizontal scroll`, !(await overflow(page)));
  const c = await contrast(page);
  check(`${tag}: AA contrast for all ${c.n} texts`, c.n > 0 && c.bad.length === 0, c.bad.slice(0, 4).join("; "));
  const ax = await axeCard(page, axeSource);
  check(`${tag}: axe finds no serious problem`, ax.length === 0, ax.slice(0, 3).join("; "));
  check(`${tag}: no input of ours, none in the picture of Stripe's form`, (await mockHasInputs(page)) === 0);
  check(`${tag}: the card never shows the Zella Voice name`, !(await zellaOnCard(page)));
}

(async () => {
  const axeSource = loadAxe();
  const browser = await chromium.launch();
  for (const look of LOOKS) {
    for (const width of WIDTHS) {
      const tag = `${look.name} ${width.name}`;
      // ---- the list, then Pay now on the open invoice ----
      const a = await open(browser, look, width.viewport, `/app/settings/billing/invoices?scenario=`);
      await a.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      check(`${tag}: auto charge: the renewal date and the saved card from Stripe`, (await a.page.locator(".zpay-lead").innerText()).includes("We'll charge your Visa •••• 4242"));
      check(`${tag}: Auto pay: a switch, on, for the owner`, (await a.page.getAttribute(".zpay-autopay [role=switch]", "aria-checked")) === "true");
      check(`${tag}: the open invoice offers Pay now, the paid one doesn't`, (await a.page.locator(".zpay-row[data-invoice='ZV-0042'] button:has-text('Pay now')").count()) === 1
        && (await a.page.locator(".zpay-row[data-invoice='ZV-0031'] button:has-text('Pay now')").count()) === 0);
      check(`${tag}: no link to Stripe's hosted invoice page in the list (owner, 27 Nov 2026)`, (await a.page.locator(".zpay-row a").count()) === 0
        && (await a.page.locator("text=On Stripe").count()) === 0);
      check(`${tag}: the list shows the period, amount and status, never an invoice number`, !/ZV-\d/.test(await a.page.locator(".ba-content").innerText())
        && (await a.page.locator(".zpay-row[data-invoice='ZV-0042'] strong").innerText()) === "Nov 20, 2026 to Nov 30, 2026");
      await shot(a.page, look, width, "list", axeSource);
      await a.page.click(".zpay-row[data-invoice='ZV-0042'] button:has-text('Pay now')");
      await a.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
      await a.page.waitForSelector("#zpay-route-title:has-text('Pay for your plan')", { timeout: 5000 }).catch(() => {});
      check(`${tag}: Pay now opens its own page in the CRM: the address, the shell kept, a way back, the title`,
        new URL(a.page.url()).pathname === `/app/settings/billing/pay/${OPEN}` && await a.page.isVisible(".ba-content") && (await a.page.locator(".ba-topbar, header, #ba-sidebar").count()) > 0
        && await a.page.isVisible(".zpay-route-crumbs a:has-text('Billing and subscription')") && (await a.page.locator("#zpay-route-title").innerText()) === "Pay for your plan");
      await a.page.waitForSelector(".zgc-summary:has-text('Your Pro plan')", { timeout: 5000 }).catch(() => {});
      check(`${tag}: no invoice number is shown on the pay page (it stays in the PDF); the summary says the plan and what it covers`,
        !/ZV-\d/.test(await a.page.locator(".ba-content").innerText()) && (await a.page.locator(".zgc-receipt, .zgc-summary").first().innerText().catch(() => "")).includes("Your Pro plan")
        && (await a.page.locator(".ba-content").innerText()).includes("Monthly plan, Nov 20 to Nov 30"));
      check(`${tag}: the glass checkout for the invoice, the amount from the server`, (await a.page.locator(".zgc-total strong").innerText()) === "$249");
      check(`${tag}: Stripe's hosted page isn't offered while the checkout works, and no PDF for an open invoice without one`,
        (await a.page.locator("a:has-text(\"Stripe's secure page\"), a:has-text(\"Stripe's invoice page\")").count()) === 0 && (await a.page.locator("a:has-text('Download PDF')").count()) === 0);
      check(`${tag}: Pay now: "Pay automatically each renewal", on by default, with what it means`, (await a.page.getAttribute(".zgc-autopay [role=switch]", "aria-checked")) === "true"
        && (await a.page.locator(".zgc-autopay-note").innerText()) === "Stripe charges your saved card on each renewal date.");
      await a.page.click(".zgc-pay button:has-text('Pay now')");
      await a.page.waitForSelector(".zgc-slot .zgc-slot-text", { timeout: 10000 }).catch(() => {});
      check(`${tag}: paying: the stand in's card fields and billing address in Payment details, Pay waits for them`, await a.page.isVisible(".zgc-pay .zgc-addr-mock") && await a.page.locator(".zgc input").count() === 0
        && await a.page.isDisabled(".zgc-pay-foot button:has-text('Pay $249')"));
      await fillCard(a.page); await waitFilled(a.page); await a.page.waitForTimeout(900);
      check(`${tag}: paying: the card filled from Stripe's preview, nothing more`, (await a.page.locator(".zgc-cardcol .zgc-card-front .zgc-cf-number").innerText()) === "•••• •••• •••• 4242" && onlyLast4AndExpiry(await cardText(a.page)));
      check(`${tag}: Stripe.js is never loaded by the stand in`, await a.page.evaluate(() => ![...document.scripts].some((s) => s.src.includes("stripe.com"))));
      await shot(a.page, look, width, "paying", axeSource);
      await a.page.click(".zgc-pay-foot button:has-text('Pay $249')");
      await a.page.waitForSelector(".zgc.is-confirming", { timeout: 8000 }).catch(() => {});
      await a.page.waitForTimeout(250);
      check(`${tag}: processing: confirming, nothing says paid`, await a.page.isVisible(".zgc-stage") && !(await a.page.isVisible("#zgc-status:has-text('Payment received')")));
      check(`${tag}: processing: still only the last 4 and the expiry`, onlyLast4AndExpiry(await cardText(a.page)));
      await shot(a.page, look, width, "processing", axeSource);
      await a.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      await a.page.waitForTimeout(4200);
      check(`${tag}: confirmed only after the server's later look`, (await a.page.locator("#zgc-status").innerText()) === "Payment received");
      const done = await a.page.evaluate(() => { const f = document.querySelector(".zgc-stage .zgc-card-done"); return { issuer: f?.querySelector(".zgc-cf-issuer")?.textContent, brand: f?.querySelector(".zgc-cf-brand")?.textContent, number: f?.querySelector(".zgc-cf-number")?.textContent }; });
      check(`${tag}: confirmed: issuer, brand and last 4 as the server returned them`, done.issuer === "Test Bank" && done.brand === "Visa" && done.number === "•••• •••• •••• 4242", JSON.stringify(done));
      await shot(a.page, look, width, "confirmed", axeSource);
      check(`${tag}: confirmed: the page offers the way back`, await a.page.isVisible("button:has-text('Back to Billing and subscription')"));
      await a.page.click("button:has-text('Back to Billing and subscription')");
      await a.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      check(`${tag}: back on Invoices and payments`, new URL(a.page.url()).pathname === "/app/settings/billing/invoices" && await a.page.isVisible("#zpay-how"));
      check(`${tag}: the payment page came with its ENFORCING policy and nothing was blocked`, (a.ctx.__cspServed ?? 0) >= 1 && (await cspViolations(a.page)).length === 0, (await cspViolations(a.page)).join("; "));
      check(`${tag}: no page errors`, a.errors.length === 0, a.errors.join("; "));
      check(`${tag}: nothing left this machine`, a.hits.length === 0, a.hits.join(", "));
      await a.ctx.close();

      // ---- the emailed link for an invoice already paid ----
      const b = await open(browser, look, width.viewport, `/pay/invoice/${OPEN}?scenario=paid`);
      await b.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
      await b.page.waitForTimeout(300);
      check(`${tag}: already paid: says so, nothing to pay`, (await b.page.locator("#zgc-status").innerText()) === "This is paid" && (await b.page.locator(".zgc-pay-btn").count()) === 0);
      const pdf = b.page.locator("a:has-text('Download PDF')");
      check(`${tag}: already paid: Download PDF opens Stripe's PDF in a new tab`, (await pdf.count()) === 1 && (await pdf.getAttribute("href")) === "https://invoice.stripe.example/ZV-0042.pdf"
        && (await pdf.getAttribute("target")) === "_blank" && /noopener/.test(await pdf.getAttribute("rel")));
      check(`${tag}: already paid: no hosted page link`, (await b.page.locator("a:has-text(\"Stripe's secure page\")").count()) === 0);
      await shot(b.page, look, width, "already-paid", axeSource);
      await b.ctx.close();

      // ---- Update card: Stripe's page, then back here ----
      const u = await open(browser, look, width.viewport, `/app/settings/billing/invoices?scenario=`);
      await u.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      await u.page.click("button:has-text('Update card')");
      await u.page.waitForSelector(".zpay-note", { timeout: 10000 }).catch(() => {});
      check(`${tag}: update card: back from Stripe's card page, the card Stripe has`, await u.page.isVisible("text=You're back from Stripe") && !u.page.url().includes("card=updated"));
      await shot(u.page, look, width, "update-card", axeSource);
      await u.ctx.close();

      // ---- buying a pack: the confirm panel, the bank wants to confirm, then added ----
      const p = await open(browser, look, width.viewport, `/app/settings/billing/invoices?scenario=packauth`);
      await p.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      await p.page.click(".zpay-row:has-text('100 AI minutes') button:has-text('Buy')");
      await p.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
      check(`${tag}: pack: the price from the server and the card it is charged to`, (await p.page.locator(".zgc-total strong").innerText()) === "$29" && await p.page.isVisible("text=Charged to your Visa •••• 4242"));
      await shot(p.page, look, width, "pack-confirm", axeSource);
      await p.page.click(".zgc-pay-foot button:has-text('Pay $29')");
      await p.page.waitForSelector(".zgc.is-error", { timeout: 15000 }).catch(() => {});
      check(`${tag}: pack: the bank wants to confirm, nothing added`, (await p.page.locator("#zgc-status").innerText()) === "Your bank wants to confirm this payment");
      await shot(p.page, look, width, "pack-action", axeSource);
      await p.page.click("button:has-text('Confirm with your bank')");
      await fillCard(p.page); await waitFilled(p.page);
      await p.page.click(".zgc-pay-foot button:has-text('Pay $29')");
      await p.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      await p.page.waitForTimeout(4200);
      check(`${tag}: pack: added only when the server grants it`, (await p.page.locator("#zgc-status").innerText()) === "Pack added");
      await shot(p.page, look, width, "pack-added", axeSource);
      await p.ctx.close();

      // ---- no card saved ----
      const n = await open(browser, look, width.viewport, `/app/settings/billing/invoices?scenario=nocard`);
      await n.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      await n.page.click(".zpay-row:has-text('100 AI minutes') button:has-text('Buy')");
      await n.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
      await n.page.click(".zgc-pay-foot button:has-text('Pay $29')");
      await n.page.waitForSelector(".zgc.is-error", { timeout: 10000 }).catch(() => {});
      check(`${tag}: no card: says so and offers Update card`, (await n.page.locator("#zgc-status").innerText()) === "There's no card to charge" && await n.page.isVisible(".zgc-pay-foot button:has-text('Update card')"));
      await shot(n.page, look, width, "no-card", axeSource);
      await n.ctx.close();
    }
  }

  // any country (owner, 27 Nov 2026): a business in Canada gets Stripe's billing address fields in Canada's format,
  // prefilled, and pays in US dollars like everyone else
  for (const width of [WIDTHS[0], WIDTHS[1]]) {
    const c = await open(browser, LOOKS[0], width.viewport, `/app/settings/billing/invoices?scenario=canada`);
    await c.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
    await c.page.click(".zpay-row[data-invoice='ZV-0042'] button:has-text('Pay now')");
    await c.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await c.page.click(".zgc-pay button:has-text('Pay now')");
    await c.page.waitForSelector(".zgc-addr-mock", { timeout: 10000 }).catch(() => {});
    const addr = await addressMock(c.page);
    check(`canada ${width.name}: the address format follows the country (Province, Postal code; no State or ZIP code)`, addr?.country === "CA" && addr.labels.includes("Province")
      && addr.labels.includes("Postal code") && !addr.labels.includes("ZIP code") && !addr.labels.includes("State") && addr.values.country === "Canada"
      && addr.values.postal_code === "M5H 3T4", JSON.stringify(addr));
    check(`canada ${width.name}: the price stays in US dollars`, await c.page.isVisible(".zgc-pay-foot button:has-text('Pay $249')"));
    await fillCard(c.page); await waitFilled(c.page); await c.page.waitForTimeout(900);
    await shot(c.page, LOOKS[0], width, "canada-address", loadAxe());
    await c.page.click(".zgc-pay-foot button:has-text('Pay $249')");
    await c.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
    check(`canada ${width.name}: paid like any other card, confirmed by the server`, (await c.page.locator("#zgc-status").innerText()) === "Payment received");
    check(`canada ${width.name}: nothing left this machine`, c.hits.length === 0, c.hits.join(", "));
    await c.ctx.close();
  }

  // Auto pay in How you pay: off and back on, each confirmed in a dialog; Stripe's event (a moment later) changes it
  for (const look of LOOKS) {
    for (const width of [WIDTHS[0], WIDTHS[1]]) {
      const tag = `${look.name} ${width.name} autopay`;
      const t = await open(browser, look, width.viewport, `/app/settings/billing/invoices?scenario=`);
      await t.page.waitForSelector(".zpay-autopay [role=switch]", { timeout: 10000 }).catch(() => {});
      await shot(t.page, look, width, "autopay-on", axeSource);
      await t.page.click(".zpay-autopay [role=switch]");
      await t.page.waitForSelector("[role=dialog]:has-text('Auto pay')", { timeout: 5000 }).catch(() => {}); await t.page.waitForTimeout(500);   // the dialog's opening motion
      check(`${tag}: turning it off asks first, saying what changes`, (await t.page.locator("[role=dialog]:has-text('Auto pay')").innerText()).includes("Turn Auto pay off?")
        && (await t.page.locator("[role=dialog]:has-text('Auto pay')").innerText()).includes("Your invoice appears in the CRM; pay it there within 3 days."));
      await shot(t.page, look, width, "autopay-confirm-off", axeSource);
      await t.page.click("[role=dialog]:has-text('Auto pay') button:has-text('Turn off')");
      await t.page.waitForSelector(".zpay-note:has-text('waiting for Stripe')", { timeout: 5000 }).catch(() => {});
      const pending = await t.page.locator(".zpay-note:has-text('waiting for Stripe')").count();
      await t.page.waitForFunction(() => document.querySelector(".zpay-autopay [role=switch]")?.getAttribute("aria-checked") === "false"
        && !document.querySelector(".zpay-note"), null, { timeout: 15000 }).catch(() => {});
      check(`${tag}: off only after Stripe's change came back (pending first)`, pending === 1 && (await t.page.locator(".zpay-lead").innerText()).includes("Your next invoice is due")
        && (await t.page.locator(".zpay-lead").innerText()).includes("Pay now"));
      await shot(t.page, look, width, "autopay-off", axeSource);
      await t.page.click(".zpay-autopay [role=switch]");
      await t.page.waitForSelector("[role=dialog]:has-text('Auto pay')", { timeout: 5000 }).catch(() => {}); await t.page.waitForTimeout(500);   // the dialog's opening motion
      check(`${tag}: turning it on asks first too`, (await t.page.locator("[role=dialog]:has-text('Auto pay')").innerText()).includes("Turn Auto pay on?"));
      await shot(t.page, look, width, "autopay-confirm-on", axeSource);
      await t.page.click("[role=dialog]:has-text('Auto pay') button:has-text('Turn on')");
      await t.page.waitForFunction(() => document.querySelector(".zpay-autopay [role=switch]")?.getAttribute("aria-checked") === "true" && !document.querySelector(".zpay-note"), null, { timeout: 15000 }).catch(() => {});
      check(`${tag}: back on: renews on the date, the saved card`, (await t.page.locator(".zpay-lead").innerText()).includes("We'll charge your Visa •••• 4242"));
      check(`${tag}: no page errors, nothing left this machine`, t.errors.length === 0 && t.hits.length === 0, [...t.errors, ...t.hits].join("; "));
      await t.ctx.close();
    }
  }
  // turning Auto pay on with no saved card: the dialog offers Update card first, and nothing changes
  {
    const n = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/invoices?scenario=nocard`);
    await n.page.waitForSelector(".zpay-autopay [role=switch]", { timeout: 10000 }).catch(() => {});
    await n.page.click(".zpay-autopay [role=switch]");
    await n.page.click("[role=dialog]:has-text('Auto pay') button:has-text('Turn off')");
    await n.page.waitForFunction(() => document.querySelector(".zpay-autopay [role=switch]")?.getAttribute("aria-checked") === "false" && !document.querySelector(".zpay-note"), null, { timeout: 15000 }).catch(() => {});
    await n.page.click(".zpay-autopay [role=switch]");
    await n.page.waitForSelector("[role=dialog]:has-text('Auto pay')", { timeout: 5000 }).catch(() => {}); await n.page.waitForTimeout(500);
    check("autopay no card: turning it on offers Update card first", await n.page.isVisible("[role=dialog]:has-text('Auto pay') button:has-text('Update card')")
      && (await n.page.locator("[role=dialog]:has-text('Auto pay') button:has-text('Turn on')").count()) === 0);
    await shot(n.page, LOOKS[0], WIDTHS[0], "autopay-needs-card", loadAxe());
    await n.ctx.close();
  }

  // View on a paid invoice from the list: its PDF, from our stored record
  {
    const v = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/invoices?scenario=`);
    await v.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
    await v.page.click(".zpay-row[data-invoice='ZV-0031'] button:has-text('View')");
    await v.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await v.page.waitForTimeout(300);
    check("view: Download PDF for a paid invoice with a PDF", (await v.page.locator("a:has-text('Download PDF')").getAttribute("href").catch(() => null)) === "https://invoice.stripe.example/ZV-0031.pdf");
    await v.ctx.close();
  }
  // Stripe's form can't load: the error state is the ONE place Stripe's hosted page is offered
  for (const look of LOOKS) {
    const f = await open(browser, look, { width: 1440, height: 900 }, `/pay/invoice/${OPEN}?scenario=stripefail`);
    await f.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await f.page.click(".zgc-pay button:has-text('Pay now')");
    await f.page.waitForSelector(".zgc.is-error", { timeout: 10000 }).catch(() => {});
    const fb = f.page.locator("a:has-text(\"Pay on Stripe's secure page\")");
    check(`${look.name} stripefail: the form didn't load, and Stripe's secure page is offered as the fallback`, (await f.page.locator("#zgc-status").innerText()) === "The secure form didn't load"
      && (await fb.count()) === 1 && (await fb.getAttribute("href")) === "https://invoice.stripe.example/ZV-0042" && /noopener/.test(await fb.getAttribute("rel")));
    await shot(f.page, look, { name: "1440" }, "stripe-load-fallback", loadAxe());
    await f.ctx.close();
  }

  // navigation: Back in the browser returns to the overview; a deep link and a reload open the same page; the emailed
  // link lands on it; a pack has its own page too
  {
    const n = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/invoices?scenario=`);
    await n.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
    await n.page.click(".zpay-row[data-invoice='ZV-0042'] button:has-text('Pay now')");
    await n.page.waitForSelector("#zpay-route-title:has-text('Pay for your plan')", { timeout: 10000 }).catch(() => {});
    await n.page.goBack();
    await n.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
    check("navigation: Back in the browser returns to Invoices and payments", new URL(n.page.url()).pathname === "/app/settings/billing/invoices" && await n.page.isVisible("#zpay-how"));
    await n.page.click(".zpay-row:has-text('100 AI minutes') button:has-text('Buy')");
    await n.page.waitForSelector("#zpay-route-title:has-text('Buy 100 AI minutes')", { timeout: 10000 }).catch(() => {});
    check("navigation: a pack opens its own page", new URL(n.page.url()).pathname === "/app/settings/billing/pack/minutes_100" && await n.page.isVisible(".zgc"));
    await n.ctx.close();
    const d = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/pay/${OPEN}?scenario=`);
    await d.page.waitForSelector("#zpay-route-title:has-text('Pay for your plan')", { timeout: 10000 }).catch(() => {});
    const first = await d.page.isVisible(".zgc");
    await d.page.reload();
    await d.page.waitForSelector("#zpay-route-title:has-text('Pay for your plan')", { timeout: 10000 }).catch(() => {});
    check("navigation: a deep link opens the page, and so does a reload", first && await d.page.isVisible(".zgc") && (await d.page.locator("#zpay-route-title").innerText()) === "Pay for your plan");
    await d.ctx.close();
    const e = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/pay/invoice/${OPEN}?scenario=`);
    await e.page.waitForSelector("#zpay-route-title:has-text('Pay for your plan')", { timeout: 15000 }).catch(() => {});
    check("emailed link: /pay/invoice/<id> lands on the invoice's page in the CRM", new URL(e.page.url()).pathname === `/app/settings/billing/pay/${OPEN}` && await e.page.isVisible(".zgc"));
    await e.ctx.close();
    const s = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/pay/${OPEN}?scenario=`, { role: "staff" });
    await s.page.waitForSelector(".zob-state.error, .zgc", { timeout: 10000 }).catch(() => {});
    check("a team member who isn't the owner gets the same page as an invoice that doesn't exist", await s.page.isVisible("text=We couldn't open this invoice") && (await s.page.locator(".zgc").count()) === 0);
    await s.ctx.close();
    // double payment protections on the CRM's payment page (owner priority, 27 Nov 2026)
    const p2 = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/pay/${OPEN}?scenario=`);
    await p2.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await p2.page.click(".zgc-pay button:has-text('Pay now')");
    await fillCard(p2.page); await waitFilled(p2.page);
    await p2.page.dblclick(".zgc-pay-foot button:has-text('Pay $249')").catch(() => {});
    await p2.page.keyboard.press("Enter").catch(() => {});
    await p2.page.waitForSelector(".zgc.is-confirming, .zgc.is-confirmed", { timeout: 8000 }).catch(() => {});
    check("case 7: a double click and Enter on Pay make one confirm", (await p2.page.evaluate(() => window.__zgcConfirms)) === 1);
    await p2.page.reload();
    await p2.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await p2.page.waitForTimeout(400);
    check("case 1: a reload while Stripe has the payment opens confirming, with no Pay", await p2.page.isVisible(".zgc.is-confirming, .zgc.is-pending, .zgc.is-confirmed")
      && (await p2.page.locator(".zgc button:has-text('Pay now'), .zgc-pay-foot button:has-text('Pay $249')").count()) === 0);
    await p2.page.goto(`${APP}/app/settings/billing/invoices?scenario=`);
    await p2.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
    await p2.page.goto(`${APP}/app/settings/billing/pay/${OPEN}?scenario=`);
    await p2.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await p2.page.waitForTimeout(400);
    check("case 8: left mid payment and came back: processing from the server, no Pay", await p2.page.isVisible(".zgc.is-confirming, .zgc.is-pending, .zgc.is-confirmed")
      && (await p2.page.locator(".zgc button:has-text('Pay now')").count()) === 0);
    await p2.ctx.close();
    const q2 = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/pay/${OPEN}?scenario=&payment_intent=pi_stale&payment_intent_client_secret=pi_stale_secret_x&redirect_status=succeeded`);
    await q2.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await q2.page.waitForTimeout(600);
    check("case 9: a stale 3D Secure return is never trusted: the query is removed and the server is asked", !/payment_intent|redirect_status/.test(q2.page.url())
      && !(await q2.page.isVisible("#zgc-status:has-text('Payment received')")));
    await q2.ctx.close();
    const k = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/pack/not_a_pack?scenario=`);
    await k.page.waitForSelector(".zob-state.error", { timeout: 10000 }).catch(() => {});
    check("case 5: an edited pack code opens nothing payable", await k.page.isVisible("text=We couldn't open this pack") && (await k.page.locator(".zgc").count()) === 0);
    await k.ctx.close();

    // nothing open: what's next, information only (paying early isn't offered, owner decision 27 Nov 2026)
    const x = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/invoices?scenario=paid`);
    await x.page.waitForSelector(".zpay-next", { timeout: 10000 }).catch(() => {});
    check("nothing open: \"Next payment: $249 on Nov 30, 2026\" with the Auto pay status, and no way to pay early",
      (await x.page.locator(".zpay-next").innerText()).includes("Next payment: $249 on Nov 30, 2026") && (await x.page.locator(".zpay-next").innerText()).includes("Auto pay is on")
      && (await x.page.locator("button:has-text('Pay now')").count()) === 0);
    await x.ctx.close();
  }

  // the emailed link: someone who isn't this invoice's owner gets nothing but "couldn't open"
  {
    const x = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/pay/invoice/00000000-0000-4000-8000-00000000ffff?scenario=`);
    await x.page.waitForTimeout(600);
    check("emailed link: an id that isn't this owner's opens nothing", await x.page.isVisible("text=We couldn't open this invoice") && (await x.page.locator(".zgc").count()) === 0);
    await x.ctx.close();
  }

  if (process.env.VIDEO) {
    fs.mkdirSync(process.env.VIDEO, { recursive: true });
    const v = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/app/settings/billing/invoices?scenario=`, { video: process.env.VIDEO });
    await v.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
    await v.page.waitForTimeout(800);
    await v.page.click(".zpay-row[data-invoice='ZV-0042'] button:has-text('Pay now')");
    await v.page.waitForTimeout(1000);
    await v.page.hover(".zgc-cardcol .zgc-card"); await v.page.mouse.move(400, 420, { steps: 12 }); await v.page.waitForTimeout(500);
    await v.page.click(".zgc-pay button:has-text('Pay now')");
    await fillCard(v.page);
    await waitFilled(v.page);
    await v.page.waitForTimeout(1200);
    await v.page.click(".zgc-pay-foot button:has-text('Pay $249')");
    await v.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
    await v.page.waitForTimeout(4500);
    const rec = v.page.video();
    await v.ctx.close();
    const to = path.join(process.env.VIDEO, "crm-paynow-page-zella-1440.webm");
    fs.renameSync(await rec.path(), to);
    console.log(`video ${to}`);
  }
  await browser.close();
  console.log(`${passes} passed, ${fails} failed`);
  process.exit(fails ? 1 : 0);
})();
