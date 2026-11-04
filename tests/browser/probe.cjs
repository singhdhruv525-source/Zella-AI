// Opens one page as a test person (local stand-in, see local-backend.mjs) and prints the result of a browser expression.
// Usage: node tests/browser/probe.cjs <email> <route> "<js expression>" [width]
//   e.g. node tests/browser/probe.cjs owner@glow.test /app/today "document.title"
const { chromium } = require("playwright");
const [email, route, expr, width = "1280"] = process.argv.slice(2);
const APP = process.env.APP_URL ?? "http://localhost:5199", BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: Number(width), height: 900 } });
  if (process.env.BUSINESS) await ctx.addInitScript((id) => localStorage.setItem("zella.lastBusiness", id), process.env.BUSINESS);
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const q = route.request();
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
  await p.goto(APP + route);
  await p.waitForTimeout(3500);
  const out = await p.evaluate(expr);
  console.log(typeof out === "string" ? out : JSON.stringify(out, null, 1));
  if (process.env.SHOT) await p.screenshot({ path: process.env.SHOT, fullPage: false });
  await b.close();
})();
