// Admin > Plans & subscriptions > Payments (lane F) in a real browser against the local stand in
// (tests/browser/local-backend.mjs on BACKEND_URL, seeded with test invoices and one refund request). The Supabase
// address of the build (zlocal.supabase.co) is rerouted to the stand in; nothing else leaves the machine.
//   APP_URL=http://localhost:5151 BACKEND_URL=http://localhost:54336 EMAIL=owner@lanef.test SHOTS=<folder> node tests/browser/stripe-admin-payments.cjs
const { chromium } = require("playwright");
const path = require("path");
const APP = process.env.APP_URL ?? "http://localhost:5151", BACKEND = process.env.BACKEND_URL ?? "http://localhost:54336";
const SHOTS = process.env.SHOTS ?? process.cwd(), EMAIL = process.env.EMAIL ?? "owner@lanef.test";
if (!["localhost", "127.0.0.1"].includes(new URL(APP).hostname) || !["localhost", "127.0.0.1"].includes(new URL(BACKEND).hostname)) process.exit(2);
let fails = 0;
const check = (n, ok, d = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${n}${d ? " - " + d : ""}`); if (!ok) fails++; };
(async () => {
  const browser = await chromium.launch();
  for (const [name, viewport] of [["1440", { width: 1440, height: 900 }], ["390", { width: 390, height: 844 }]]) {
    const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1 });
    const outside = [];
    await ctx.route((u) => ["http:", "https:"].includes(u.protocol), async (route) => {
      const req = route.request(), u = new URL(req.url());
      if (u.hostname === "zlocal.supabase.co") {
        const r = await fetch(req.url().replace("https://zlocal.supabase.co", BACKEND), { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
        return route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
      }
      if (["localhost", "127.0.0.1", "fonts.googleapis.com", "fonts.gstatic.com"].includes(u.hostname)) return route.continue();
      outside.push(u.hostname); return route.fulfill({ status: 503, body: "" });
    });
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(APP + "/");
    await page.waitForSelector('input[type="email"]', { timeout: 15000 });
    await page.fill('input[type="email"]', EMAIL);
    if (!(await page.$('input[type="password"]'))) await page.click('button[type="submit"]');
    await page.waitForSelector('input[type="password"]', { timeout: 10000 });
    await page.fill('input[type="password"]', "Test-pass-1");
    await page.click('button[type="submit"]');
    await page.waitForTimeout(2500);
    if (viewport.width < 800) { const menu = await page.$('button[aria-label*="menu" i]'); if (menu) { await menu.click(); await page.waitForTimeout(300); } }
    await page.click("text=Plans & Subscriptions").catch(() => {});
    await page.waitForSelector("text=Payments", { timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(800);
    check(`${name}: the Payments panel lists the invoices with amounts from cents`, await page.isVisible("text=ZV-0001") && await page.isVisible("text=$898.00"));
    check(`${name}: no horizontal scroll`, !(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)));
    await page.locator("text=Payments").first().scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(SHOTS, `f8-payments-invoices-${name}.png`), fullPage: true });
    await page.click('[role="tab"]:has-text("Refunds")');
    await page.waitForSelector("text=30 day guarantee", { timeout: 8000 }).catch(() => {});
    check(`${name}: the refund waiting for approval is listed`, await page.isVisible("text=30 day guarantee") && await page.locator("td >> text=Waiting for approval").isVisible());
    await page.screenshot({ path: path.join(SHOTS, `f8-payments-refunds-${name}.png`), fullPage: true });
    await page.click('[role="tab"]:has-text("Disputes")');
    await page.waitForTimeout(800);
    check(`${name}: the open dispute is listed with its amount`, await page.locator("td >> text=fraudulent").isVisible() && await page.locator("td >> text=$898.00").isVisible());
    await page.screenshot({ path: path.join(SHOTS, `f9-payments-disputes-${name}.png`), fullPage: true });
    check(`${name}: no page errors`, errors.length === 0, errors.join("; "));
    check(`${name}: nothing left the machine`, outside.length === 0, outside.join(","));
    await ctx.close();
  }
  await browser.close();
  console.log(fails ? `${fails} failed` : "all passed"); process.exit(fails ? 1 : 0);
})();
