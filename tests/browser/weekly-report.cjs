// Settings, Reporting configuration: the weekly platform report, in a real browser against the REAL local backend
// (isolated database with sql/zella_weekly_platform_report.sql applied and a few reports made; local stand in; the real
// owner-provision-business code). Nothing is sent.
// Usage: APP_URL=http://localhost:5299 BACKEND_URL=http://localhost:54341 SHOTS=<dir> node tests/browser/weekly-report.cjs
// Checks: the Zella Voice owner sees the schedule, the latest report with every figure and its definition, and earlier
// weeks, at 1440 x 900 and at 390 px with no sideways scrolling; a read only admin (no reports.view) sees the refusal and
// no figure. Screenshots go to SHOTS.
const { chromium } = require("playwright");
const path = require("node:path");
const APP = process.env.APP_URL ?? "http://localhost:5199", BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const SHOTS = process.env.SHOTS ?? "/tmp";
const ROUTE = "/settings/analytics/reporting";
let fails = 0; const check = (ok, name) => { console.log(`${ok ? "PASS" : "FAIL"} ${name}`); if (!ok) fails++; };

async function open(b, email, width, height) {
  const ctx = await b.newContext({ viewport: { width, height } });
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const q = route.request();
    const r = await fetch(q.url().replace("https://zlocal.supabase.co", BACKEND), { method: q.method(), headers: q.headers(), body: ["GET", "HEAD"].includes(q.method()) ? undefined : q.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  const p = await ctx.newPage();
  await p.goto(APP + "/");
  await p.fill('input[type="email"]', email);
  if (!(await p.$('input[type="password"]'))) await p.click('button[type="submit"]');
  await p.fill('input[type="password"]', "Test-pass-1");
  await p.click('button[type="submit"]');
  await p.waitForTimeout(2500);
  await p.goto(APP + ROUTE);
  await p.waitForTimeout(3500);
  return { ctx, p };
}

(async () => {
  const b = await chromium.launch();
  for (const [w, h, name] of [[1440, 900, "desktop"], [390, 844, "phone"]]) {
    const { ctx, p } = await open(b, "admin@zella.test", w, h);
    const text = await p.evaluate(() => document.querySelector("main")?.innerText ?? document.body.innerText);
    check(/Weekly platform report/.test(text) && /Latest report: /.test(text), `${name}: the owner sees the schedule and the latest report`);
    check(["New businesses", "Live businesses", "Missed calls", "Texts sent", "Open platform alerts", "Support tickets opened", "Failed automations"].every((f) => text.includes(f)), `${name}: every figure is shown`);
    check(/Earlier weeks/.test(text), `${name}: earlier weeks are listed`);
    check(/switched off|isn't set up/.test(text) && /once email is live/.test(text), `${name}: it says the weekly job is off and email isn't live`);
    check(!/[‐-―]|\w-\w/.test(text.replace(/\d{4}-\d{2}-\d{2}/g, "")), `${name}: no dash or hyphen in the page text`);
    const sideways = await p.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
    check(!sideways, `${name}: no sideways scrolling`);
    await p.screenshot({ path: path.join(SHOTS, `reporting-${name}.png`), fullPage: false });
    await p.screenshot({ path: path.join(SHOTS, `reporting-${name}-full.png`), fullPage: true });
    await ctx.close();
  }
  const { ctx, p } = await open(b, "readonly@zella.test", 1440, 900);
  const text = await p.evaluate(() => document.querySelector("main")?.innerText ?? document.body.innerText);
  check(/can't read the weekly platform report/.test(text) && !/Latest report/.test(text), "a read only admin sees the refusal and no figure");
  await p.screenshot({ path: path.join(SHOTS, "reporting-readonly.png"), fullPage: false });
  await ctx.close();
  await b.close();
  console.log(fails ? `${fails} FAILED` : "ALL PASSED");
  process.exit(fails ? 1 : 0);
})();
