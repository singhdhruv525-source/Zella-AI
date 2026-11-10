// Screenshots of the fixed screens (local stand-in, test data only), at 2x for people to look at.
// Usage: OUT=<folder> node tests/browser/evidence-shots.cjs
const { chromium } = require("playwright");
const path = require("path");
const APP = process.env.APP_URL ?? "http://localhost:5199", BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const OUT = process.env.OUT ?? ".";
const B1 = "b0000000-0000-0000-0000-000000000001";

async function session(browser, email, { width = 1280, height = 860, fail } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 2 });
  await ctx.addInitScript((id) => localStorage.setItem("zella.lastBusiness", id), B1);
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const q = route.request();
    if (fail?.(q)) return route.fulfill({ status: 500, contentType: "application/json", body: '{"msg":"down"}' });
    const r = await fetch(q.url().replace("https://zlocal.supabase.co", BACKEND), { method: q.method(), headers: q.headers(), body: ["GET", "HEAD"].includes(q.method()) ? undefined : q.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  const p = await ctx.newPage();
  await p.goto(APP + (email.includes("zella.test") ? "/" : "/app"));
  await p.fill('input[type="email"]', email);
  if (!(await p.$('input[type="password"]'))) await p.click('button[type="submit"]');
  await p.fill('input[type="password"]', "Test-pass-1");
  await p.click('button[type="submit"]');
  await p.waitForTimeout(2500);
  return { ctx, p };
}
const shot = (p, name) => p.screenshot({ path: path.join(OUT, `${name}.png`) });

(async () => {
  const b = await chromium.launch();
  { // 1. wizard: unsaved changes dialog
    const { ctx, p } = await session(b, "admin@zella.test");
    await p.goto(APP + `/businesses/${B1}/setup`); await p.waitForTimeout(2500);
    await p.locator(".wiz-stepper button", { hasText: "Hours & services" }).click(); await p.waitForTimeout(1200);
    await p.locator("textarea").first().fill("Family salon since 2009. Walk-ins welcome.");
    await p.locator(".wiz-stepper button", { hasText: "Team" }).click(); await p.waitForTimeout(500);
    await shot(p, "1-wizard-unsaved-dialog"); await ctx.close();
  }
  { // 2. templates scoped to the business, with source and in use
    const { ctx, p } = await session(b, "owner@glow.test");
    await p.goto(APP + "/app/settings/messages/templates"); await p.waitForTimeout(2500);
    await shot(p, "2-templates-this-business"); await ctx.close();
  }
  { // 3. appearance save failed, with Try again
    const { ctx, p } = await session(b, "owner@glow.test", { fail: (q) => q.method() === "PUT" && q.url().includes("/auth/v1/user") });
    await p.goto(APP + "/app/settings/me/appearance"); await p.waitForTimeout(1500);
    await p.getByRole("radio", { name: /^Glass/ }).click(); await p.waitForTimeout(1500);
    await shot(p, "3-appearance-save-failed"); await ctx.close();
  }
  { // 4. automations page that used to crash
    const { ctx, p } = await session(b, "owner@glow.test");
    await p.goto(APP + "/app/automations"); await p.waitForTimeout(2500);
    await shot(p, "4-automations-opens"); await ctx.close();
  }
  { // 5. receptionist on a phone, no sideways scroll, honest go-live card
    const { ctx, p } = await session(b, "owner@glow.test", { width: 390, height: 844 });
    await p.goto(APP + "/app/receptionist"); await p.waitForTimeout(3000);
    await shot(p, "5-receptionist-mobile"); await ctx.close();
  }
  { // 6. admin alerts bell when alerts can't be read
    const { ctx, p } = await session(b, "admin@zella.test", { fail: (q) => q.url().includes("/rest/v1/platform_alerts") });
    await p.goto(APP + "/"); await p.waitForTimeout(2500);
    await p.getByRole("button", { name: /Platform alerts/ }).click(); await p.waitForTimeout(500);
    await shot(p, "6-alerts-could-not-load"); await ctx.close();
  }
  await b.close();
})();
