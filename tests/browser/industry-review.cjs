// Every CRM page, as a business of every industry, in a real browser against the local stand-in (see README.md).
// One test business per industry (test data only), owned by owner@glow.test. For each industry it records the sidebar
// (labels, groups, the industry's own operations pages), every page's heading and empty-state wording, and problems:
// crashes, error screens, failed backend calls, axe-core results. Output: <OUT>/<slug>.json and a few screenshots.
// Usage: node tests/browser/industry-review.cjs [worker index] [worker count]
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const APP = process.env.APP_URL ?? "http://localhost:5199", BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const OUT = process.env.OUT ?? "/tmp/industry-review";
const AXE = fs.readFileSync(process.env.AXE ?? require.resolve("axe-core/axe.min.js"), "utf8");
const PG = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zella_ui", "-AtqX", "-c"];
const sql = (q) => execFileSync("psql", [...PG, q]).toString().trim();
const PAGES = ["today", "calendar", "checkins", "waitlist", "tasks", "leads", "customers", "attention", "inbox", "messages", "calls", "callbacks",
  "drafts", "failed", "spam", "receptionist", "transcripts", "knowledge", "automations", "lead-sources", "reviews", "reports", "team", "scorecards",
  "integrations", "record-settings"];
const [worker = 0, workers = 1] = process.argv.slice(2).map(Number);

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const list = sql(`select b.id || '|' || i.slug || '|' || coalesce((select string_agg(t.key, ',' order by t.key) from crm_record_types t where t.business_id = b.id), '')
    from businesses b join industries i on i.id = b.industry_id where b.id::text like 'c0000000%' order by i.slug`).split("\n")
    .map((l) => { const [id, slug, types] = l.split("|"); return { id, slug, types: types ? types.split(",") : [] }; })
    .filter((_, i) => i % workers === worker);
  const browser = await chromium.launch();
  for (const biz of list) {
    const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
    await ctx.addInitScript((id) => localStorage.setItem("zella.lastBusiness", id), biz.id);
    await ctx.route("https://zlocal.supabase.co/**", async (r) => {
      const q = r.request();
      const res = await fetch(q.url().replace("https://zlocal.supabase.co", BACKEND), { method: q.method(), headers: q.headers(), body: ["GET", "HEAD"].includes(q.method()) ? undefined : q.postDataBuffer() });
      await r.fulfill({ status: res.status, headers: Object.fromEntries(res.headers.entries()), body: Buffer.from(await res.arrayBuffer()) });
    });
    const p = await ctx.newPage();
    const errors = [], failed = [];
    p.on("pageerror", (e) => errors.push(e.message));
    p.on("response", async (r) => { if (r.status() >= 400 && r.url().includes("zlocal.supabase.co")) { let b = ""; try { b = (await r.text()).slice(0, 160); } catch { /* gone */ } failed.push(`${r.status()} ${decodeURIComponent(r.url().split("supabase.co")[1]).split("?")[0]} ${b}`); } });
    await p.goto(APP + "/app");
    await p.fill('input[type="email"]', "owner@glow.test");
    if (!(await p.$('input[type="password"]'))) await p.click('button[type="submit"]');
    await p.fill('input[type="password"]', "Test-pass-1");
    await p.click('button[type="submit"]');
    await p.waitForTimeout(3000);
    // expand every sidebar group and parent, then read it
    const sidebar = await p.evaluate(async () => {
      for (const b of document.querySelectorAll('.ba-sidebar .ba-nav-section [aria-expanded="false"]')) b.click();
      await new Promise((r) => setTimeout(r, 300));
      return [...document.querySelectorAll(".ba-sidebar .ba-nav-section")].map((s) => ({
        group: s.querySelector(".ba-nav-group")?.innerText.trim() ?? "",
        items: [...s.querySelectorAll(".ba-nav-item")].map((i) => i.innerText.replace(/\s+/g, " ").replace(/expand_(more|less)/g, "").trim()),
      }));
    });
    const result = { slug: biz.slug, business: biz.id, sidebar, pages: [] };
    const routes = [...PAGES.map((x) => `/app/${x}`), ...biz.types.map((t) => `/app/records/${t}`), "/app/settings/industry/profile", "/app/settings/industry/fields", "/app/settings/industry/workflows"];
    for (const route of routes) {
      errors.length = 0; failed.length = 0;
      if (process.env.DEBUG) console.log('goto', route, Date.now());
      await p.goto(APP + route, { timeout: 15000 }).catch((e) => process.env.DEBUG && console.log('goto failed', e.message.slice(0, 80)));
      if (process.env.DEBUG) console.log('loaded', Date.now());
      const t0 = Date.now();
      while (Date.now() - t0 < 6000 && await p.evaluate(() => /Loading|Checking/.test(document.querySelector(".ba-main, main")?.innerText?.slice(0, 2000) ?? "")).catch(() => false)) await p.waitForTimeout(250);
      await p.waitForTimeout(500);
      const info = await p.evaluate(() => {
        const main = document.querySelector(".ba-main, main") ?? document.body;
        const t = main.innerText;
        return {
          title: (main.querySelector("h1")?.innerText ?? "").trim(),
          sub: (main.querySelector(".ba-page-head p, .ba-page-sub, h1 + p")?.innerText ?? "").trim().slice(0, 200),
          headings: [...main.querySelectorAll("h2, h3, .ba-panel-title h2")].map((h) => h.innerText.trim()).filter(Boolean).slice(0, 14),
          buttons: [...main.querySelectorAll("button")].map((b) => (b.getAttribute("aria-label") || b.innerText).replace(/\s+/g, " ").trim()).filter((x) => x && x.length < 40).slice(0, 18),
          empty: [...main.querySelectorAll(".ba-empty, .zs-empty, .owner-empty-state, .bp-empty")].map((e) => e.innerText.replace(/\s+/g, " ").trim()).slice(0, 4),
          columns: [...main.querySelectorAll("th")].map((th) => th.innerText.trim()).filter(Boolean).slice(0, 14),
          crashed: /Something went wrong on this page/.test(t), notAvailable: /isn't available/.test(t), notFound: /Page not found/.test(t),
          words: t.slice(0, 1500),
        };
      });
      if (process.env.DEBUG) console.log('info', Date.now());
      await p.addScriptTag({ content: AXE }).catch(() => {});
      const axe = await p.evaluate(async () => (window.axe ? (await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa"] }, resultTypes: ["violations"] })).violations.map((v) => v.id) : null)).catch(() => ["axe-failed"]);
      result.pages.push({ route, ...info, errors: [...errors], failed: [...failed], axe });
      if (["/app/today", `/app/records/${biz.types[0]}`, "/app/customers"].includes(route)) await p.screenshot({ path: path.join(OUT, `${biz.slug}-${route.split("/").pop()}.png`) });
      console.log(`${info.crashed || errors.length ? "CHECK" : "ok   "} ${biz.slug} ${route} [${info.title}]${failed.length ? ` failed=${failed.length}` : ""}${axe?.length ? ` axe=${axe}` : ""}`);
    }
    fs.writeFileSync(path.join(OUT, `${biz.slug}.json`), JSON.stringify(result, null, 1));
    await ctx.close();
  }
  await browser.close();
})();
