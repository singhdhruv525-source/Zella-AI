// The owner onboarding Pay screen with payments connected (lane F), in a real browser, against the stand in api
// (scenario "pay"): Ready to pay -> Pay securely -> back from "Stripe" -> Payment received. Nothing reaches Supabase
// or Stripe: every request off this machine is refused here and counted. Build and serve a LOCAL copy as described in
// owner-onboarding-journey.cjs, then: APP_URL=http://localhost:5150 SHOTS=<folder> node tests/browser/stripe-pay-screen.cjs
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const APP = process.env.APP_URL ?? "http://localhost:5150";
const SHOTS = process.env.SHOTS ?? path.join(process.cwd(), "pay-shots");
if (!["localhost", "127.0.0.1"].includes(new URL(APP).hostname)) { console.error("APP_URL must be a local preview"); process.exit(2); }
fs.mkdirSync(SHOTS, { recursive: true });
let fails = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); if (!ok) fails++; };

(async () => {
  // the stand in's state at step 6, made by walking its own rules (the same calls the screens make)
  const { createFakeApi } = await import(path.join(__dirname, "../../web/src/onboarding/fakeApi.js"));
  const mem = new Map(); const storage = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) };
  const api = createFakeApi({ scenario: "pay", storage, delay: 0 });
  const id = (await api.listBusinesses()).businesses[0].business_id;
  await api.completeStep(id, "welcome"); await api.setPassword("A good pass 1!"); await api.finishMfa("x", "123456"); await api.completeStep(id, "security");
  for (const k of ["business", "hours_services", "team", "receptionist_phone"]) await api.answerSection(id, k, "looks_right");
  await api.completeStep(id, "details"); api.approveIdentity(); await api.completeStep(id, "identity");
  const s = await api.getState(id); await api.acceptPlan(id, s.plan.current.version);
  const seeded = [...mem.entries()];

  const browser = await chromium.launch();
  for (const vp of [{ name: "1440", viewport: { width: 1440, height: 900 } }, { name: "390", viewport: { width: 390, height: 844 } }]) {
    const ctx = await browser.newContext({ viewport: vp.viewport, deviceScaleFactor: 1 });
    const hits = [];
    await ctx.route((url) => ["http:", "https:"].includes(url.protocol), async (route) => {
      const url = new URL(route.request().url());
      if (["localhost", "127.0.0.1", "fonts.googleapis.com", "fonts.gstatic.com"].includes(url.hostname)) return route.continue();
      hits.push(`${route.request().method()} ${url.hostname}${url.pathname}`);
      return route.fulfill({ status: 503, contentType: "application/json", body: "{}" });
    });
    await ctx.addInitScript((entries) => { if (!sessionStorage.getItem("seeded")) { for (const [k, v] of entries) localStorage.setItem(k, v); sessionStorage.setItem("seeded", "1"); } }, seeded);
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(`${APP}/welcome/setup?scenario=pay`);
    await page.waitForSelector("text=Ready to pay", { timeout: 10000 }).catch(() => {});
    check(`${vp.name}: Pay shows Ready to pay with the amount from the server`, await page.isVisible("text=Ready to pay") && await page.isVisible("text=$898"));
    check(`${vp.name}: no horizontal scroll`, !(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)));
    await page.screenshot({ path: path.join(SHOTS, `f3-pay-ready-${vp.name}.png`), fullPage: true });
    await page.click("button:has-text('Pay securely')");
    await page.waitForSelector("text=Payment received", { timeout: 10000 }).catch(() => {});
    check(`${vp.name}: back from Stripe, the server's answer says Payment received`, await page.isVisible("text=Payment received"));
    check(`${vp.name}: the address bar is tidied (no session id left)`, !page.url().includes("session_id"));
    await page.screenshot({ path: path.join(SHOTS, `f3-pay-confirmed-${vp.name}.png`), fullPage: true });
    check(`${vp.name}: no page errors`, errors.length === 0, errors.join("; "));
    check(`${vp.name}: nothing left this machine`, hits.length === 0, hits.join(", "));
    await ctx.close();
  }
  await browser.close();
  console.log(fails ? `${fails} failed` : "all passed");
  process.exit(fails ? 1 : 0);
})();
