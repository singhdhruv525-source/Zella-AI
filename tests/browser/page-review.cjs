// Page-by-page review in a real browser, against the local Supabase stand-in (tests/browser/local-backend.mjs) over an
// ISOLATED database restored from sql/baseline with test-only people and businesses. Real row security, real RPCs and
// the real owner-provision-business code; no production data, nothing sent.
//
// Signs in through the real sign-in pages as each test person, then opens every route from the app's own registries
// (admin navigation, admin settings, CRM pages, CRM settings, public links) by direct address (deep link + refresh), and
// records for each: crashes (page errors, error boundary), "Page not found" on a registered page, failed backend calls,
// accessibility problems found by axe-core (contrast, names, labels, ARIA), horizontal overflow, raw icon words, and a
// screenshot.
//
// Usage: node tests/browser/page-review.cjs <persona|all> [--mobile] [--glass] [--only=substring]
//   --glass only names the output folder: set the theme on the test accounts first (user metadata zella_appearance).
//   env APP_URL (default http://localhost:5199), OUT (results/screenshots folder), AXE (path to axe.min.js)
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const OUT = process.env.OUT ?? path.join(process.cwd(), "page-review-out");
const AXE = fs.readFileSync(process.env.AXE ?? require.resolve("axe-core/axe.min.js"), "utf8");
const INV = JSON.parse(fs.readFileSync(process.env.INVENTORY ?? path.join(OUT, "..", "inventory.json"), "utf8"));
const PASSWORD = "Test-pass-1";
const B1 = "b0000000-0000-0000-0000-000000000001";
const args = process.argv.slice(2);
const MOBILE = args.includes("--mobile");
const GLASS = args.includes("--glass");
const ONLY = (args.find((a) => a.startsWith("--only=")) ?? "").slice(7);

const ADMIN_PAGES = ["/", "/businesses", "/verification", "/industries", "/modules", "/plans", "/offers", "/agents", "/voice", "/messaging",
  "/operations", "/automations", "/integrations", "/support", "/security-abuse", "/users", "/audit-logs", "/settings",
  `/businesses/${B1}`, `/businesses/${B1}/setup`, "/businesses/new"];
const CRM_PAGES = ["today", "calendar", "checkins", "waitlist", "tasks", "leads", "customers", "attention", "inbox", "messages", "calls", "callbacks",
  "drafts", "failed", "spam", "receptionist", "transcripts", "knowledge", "automations", "lead-sources", "reviews", "reports", "team", "scorecards",
  "access", "approvals", "security", "integrations", "settings", "record-settings"];
// Pages each CRM role is NOT meant to see (navConfig roles); they must say so, not show data.
const CRM_RESTRICTED = { staff: ["failed", "spam", "reviews", "access", "approvals", "security"], viewer: ["drafts", "failed", "spam", "reviews", "access", "approvals", "security"] };

const PERSONAS = {
  admin: { email: "admin@zella.test", start: "/", routes: () => [...ADMIN_PAGES, ...INV.admin.flatMap((c) => c.items.map((i) => `/settings/${c.key}/${i.key}`))] },
  readonly: { email: "readonly@zella.test", start: "/", routes: () => ADMIN_PAGES.slice(0, 18) },
  owner: { email: "owner@glow.test", start: "/app", routes: () => [...CRM_PAGES.map((p) => `/app/${p}`), "/app/records/x-unknown",
    ...INV.crm.flatMap((c) => c.items.map((i) => `/app/settings/${c.key}/${i.key}`))] },
  staff: { email: "staff@glow.test", start: "/app", routes: () => CRM_PAGES.map((p) => `/app/${p}`) },
  viewer: { email: "viewer@glow.test", start: "/app", routes: () => CRM_PAGES.map((p) => `/app/${p}`) },
  public: { email: null, start: "/status", routes: () => ["/status", `/r/${"a".repeat(64)}`, `/u/${"b".repeat(32)}`, `/w/${"c".repeat(64)}`, "/welcome", "/app", "/", "/continue-plan"] },
};

async function signIn(page, email) {
  await page.waitForSelector('input[type="email"]', { timeout: 15000 });
  await page.fill('input[type="email"]', email);
  if (!(await page.$('input[type="password"]'))) await page.click('button[type="submit"]');
  await page.waitForSelector('input[type="password"]', { timeout: 10000 });
  await page.fill('input[type="password"]', PASSWORD);
  await page.click('button[type="submit"]');
}

async function settle(page) {
  // wait until nothing says it is loading (or 8 s), then a little longer for late requests
  const t0 = Date.now();
  while (Date.now() - t0 < 8000) {
    const busy = await page.evaluate(() => /Loading|Checking/i.test(document.querySelector("main, .owner-content, .ba-main, #root")?.innerText?.slice(0, 4000) ?? "")).catch(() => false);
    if (!busy) break;
    await page.waitForTimeout(250);
  }
  await page.waitForTimeout(600);
}

async function review(browser, name) {
  const persona = PERSONAS[name];
  const vw = MOBILE ? { width: 390, height: 844 } : { width: 1280, height: 860 };
  const ctx = await browser.newContext({ viewport: vw, deviceScaleFactor: 1 });
  // The app accepts only https://<project>.supabase.co; the test build uses zlocal.supabase.co, sent here to the stand-in.
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const req = route.request();
    const url = req.url().replace("https://zlocal.supabase.co", BACKEND);
    try {
      const r = await fetch(url, { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
      const headers = Object.fromEntries(r.headers.entries());
      await route.fulfill({ status: r.status, headers, body: Buffer.from(await r.arrayBuffer()) });
    } catch (e) { await route.abort(); }
  });
  if (process.env.BUSINESS) await ctx.addInitScript((id) => { try { localStorage.setItem("zella.lastBusiness", id); } catch { /* */ } }, process.env.BUSINESS);
  const page = await ctx.newPage();
  const pageErrors = [], failed = [], consoleErrors = [];
  page.on("pageerror", (e) => pageErrors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text().slice(0, 200)); });
  page.on("response", async (r) => {
    if (r.status() >= 400 && r.url().includes("zlocal.supabase.co")) {
      let body = ""; try { body = (await r.text()).slice(0, 240); } catch { /* gone */ }
      failed.push({ status: r.status(), url: decodeURIComponent(r.url().replace(/^https?:\/\/[^/]+/, "")).slice(0, 200), body });
    }
  });
  await page.goto(APP + persona.start);
  if (persona.email) {
    await signIn(page, persona.email);
    await page.waitForTimeout(2500);
  }
  const results = [];
  const dir = path.join(OUT, `${name}${process.env.BUSINESS ? "-" + process.env.BUSINESS.slice(-1) : ""}${MOBILE ? "-mobile" : ""}${GLASS ? "-glass" : ""}`);
  fs.mkdirSync(dir, { recursive: true });
  for (const route of persona.routes()) {
    if (ONLY && !route.includes(ONLY)) continue;
    pageErrors.length = 0; failed.length = 0; consoleErrors.length = 0;
    await page.goto(APP + route).catch(() => {});
    await settle(page);
    const info = await page.evaluate(() => {
      const text = document.body.innerText;
      const iconWords = [...document.querySelectorAll(".ba-icon")].filter((e) => getComputedStyle(e).color !== "rgba(0, 0, 0, 0)" && document.documentElement.dataset.zellaIcons !== "ready").length;
      return {
        title: (document.querySelector("h1")?.innerText ?? "").slice(0, 80),
        crashed: /Something went wrong on this page/i.test(text),
        notFound: /Page not found/i.test(text),
        notAvailable: /isn't available|not available to your role|don't have access|Platform admin access required/i.test(text),
        signIn: Boolean(document.querySelector('input[type="password"]')),
        overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        iconWords,
        errorsShown: [...document.querySelectorAll('[role="alert"], .zs-banner.error, .owner-form-error, .ba-error')].map((e) => e.innerText.slice(0, 160)).filter(Boolean),
      };
    });
    await page.addScriptTag({ content: AXE }).catch(() => {});
    const axe = await page.evaluate(async () => {
      if (!window.axe) return null;
      const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] }, resultTypes: ["violations"] });
      return r.violations.map((v) => ({ id: v.id, impact: v.impact, n: v.nodes.length,
        sample: v.nodes.slice(0, 3).map((n) => `${n.target.join(" ")} :: ${(n.failureSummary ?? "").split("\n").slice(-1)[0].slice(0, 140)}`) }));
    }).catch((e) => [{ id: "axe-failed", n: 1, sample: [e.message] }]);
    const shot = path.join(dir, route.replace(/[^a-z0-9]+/gi, "_").replace(/^_|_$/g, "") || "root") + ".png";
    await page.screenshot({ path: shot, fullPage: false }).catch(() => {});
    const row = { route, ...info, pageErrors: [...pageErrors], failed: [...failed], consoleErrors: [...new Set(consoleErrors)].slice(0, 5), axe, shot };
    results.push(row);
    const bad = row.crashed || row.pageErrors.length || (row.notFound && !route.includes("unknown")) || row.signIn || row.failed.some((f) => f.status >= 500);
    console.log(`${bad ? "CHECK" : "ok   "} ${name} ${route} ${row.title ? `[${row.title}]` : ""}${row.failed.length ? ` failed=${row.failed.length}` : ""}${axe?.length ? ` axe=${axe.map((a) => a.id).join(",")}` : ""}${row.overflowX > 0 ? ` overflowX=${row.overflowX}` : ""}`);
  }
  fs.writeFileSync(path.join(dir, "results.json"), JSON.stringify(results, null, 1));
  await ctx.close();
  return results;
}

(async () => {
  const browser = await chromium.launch();
  const names = args[0] === "all" || !args[0] ? Object.keys(PERSONAS) : [args[0]];
  for (const n of names) await review(browser, n);
  await browser.close();
})();
