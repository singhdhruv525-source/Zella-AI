// Glitch sweep: every page a person can reach, in a real browser, against the local Supabase stand-in
// (tests/browser/local-backend.mjs) over an ISOLATED test database. No production data; nothing is sent.
//
// For each persona it signs in through the real sign-in page, then crawls: the start page, every link in the
// navigation, every Settings subpage (all categories opened), and links found on those pages (detail pages: one
// example per address shape, so 500 customers are not all opened). For each page it records:
//   crashes (page errors, the error screen), console errors, failed backend calls (status >= 400), "Page not found",
//   a page still loading after 10 s, sideways overflow and the elements causing it, clipped buttons, broken images,
//   empty pages, and axe-core problems (serious and critical; WCAG 2.1 AA) — plus a screenshot.
//
// Usage: node tests/browser/glitch-sweep.cjs <persona|all> [--mobile] [--dark] [--only=substring] [--max=N]
//   personas and their emails: PERSONAS below (env PERSONAS='{"name":"email"}' replaces them)
//   env APP_URL (default http://localhost:5199), BACKEND_URL (default http://localhost:54321), OUT (results folder)
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const OUT = process.env.OUT ?? path.join(__dirname, "out", "glitch");
let AXE = null; try { AXE = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8"); } catch { /* axe optional */ }
const PASSWORD = "Test-pass-1";
const args = process.argv.slice(2);
const MOBILE = args.includes("--mobile"), DARK = args.includes("--dark");
const ONLY = (args.find((a) => a.startsWith("--only=")) ?? "").slice(7);
const MAX = Number((args.find((a) => a.startsWith("--max=")) ?? "--max=400").slice(6));
const PERSONAS = process.env.PERSONAS ? JSON.parse(process.env.PERSONAS) : {
  admin: "admin@zella.test", readonly: "readonly@zella.test",
  owner: "own-a@b3.test", manager: "multi@b3.test", staff: "staff-a@b3.test", viewer: "view-a@b3.test",
};
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const shape = (u) => u.replace(UUID, ":id").replace(/\/\d+(?=\/|$)/g, "/:n");
const SKIP = /\/(sign-?out|logout)|^mailto:|^tel:|\/r\/|\/u\/|\/w\/|\/welcome|\/continue-plan|\/status$/i;

async function signIn(page, email) {
  await page.waitForSelector('input[type="email"]', { timeout: 15000 });
  await page.fill('input[type="email"]', email);
  if (!(await page.$('input[type="password"]'))) await page.click('button[type="submit"]');
  await page.waitForSelector('input[type="password"]', { timeout: 10000 });
  await page.fill('input[type="password"]', PASSWORD);
  await page.click('button[type="submit"]');
  await page.waitForFunction(() => !document.querySelector('input[type="password"]'), null, { timeout: 15000 }).catch(() => {});
}

async function settle(page) {
  const t0 = Date.now();
  let busy = true;
  while (Date.now() - t0 < 10000) {
    busy = await page.evaluate(() => {
      const t = document.querySelector("main, .owner-content, .ba-main, #root")?.innerText?.slice(0, 5000) ?? "";
      return /\bLoading\b|Checking…|Loading…/i.test(t) || Boolean(document.querySelector('[aria-busy="true"], .ba-skeleton, .zs-skeleton'));
    }).catch(() => false);
    if (!busy) break;
    await page.waitForTimeout(250);
  }
  await page.waitForTimeout(500);
  return busy;
}

async function openSettingsTree(page) {
  const cats = page.locator(".zs-cat");
  const n = await cats.count().catch(() => 0);
  for (let i = 0; i < n; i++) {
    const c = cats.nth(i);
    if ((await c.getAttribute("aria-expanded").catch(() => "true")) !== "true") await c.click().catch(() => {});
  }
}

async function links(page, root) {
  return page.$$eval("a[href]", (els, root) => els.map((e) => e.getAttribute("href")).filter((h) => h && h.startsWith("/") && (root === "/app" ? h.startsWith("/app") : !h.startsWith("/app"))), root).catch(() => []);
}

async function inspect(page, vw) {
  return page.evaluate((vw) => {
    const text = document.body.innerText;
    const main = document.querySelector("main, .owner-content, .ba-main") ?? document.body;
    const sel = (e) => {
      let s = e.tagName.toLowerCase();
      if (e.id) s += "#" + e.id;
      const c = [...e.classList].slice(0, 2).join(".");
      if (c) s += "." + c;
      const p = e.parentElement;
      return p && p !== document.body ? `${p.tagName.toLowerCase()}${p.classList[0] ? "." + p.classList[0] : ""} > ${s}` : s;
    };
    const scrollsX = (e) => { for (let a = e.parentElement; a; a = a.parentElement) { const o = getComputedStyle(a).overflowX; if (o === "auto" || o === "scroll" || o === "hidden" || o === "clip") return true; } return false; };
    const wide = [];
    for (const e of document.querySelectorAll("body *")) {
      const r = e.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      const st = getComputedStyle(e);
      if (st.position === "fixed" || st.visibility === "hidden") continue;
      if (r.right > vw + 1 && !scrollsX(e)) wide.push(`${sel(e)} (${Math.round(r.right - vw)}px)`);
      if (wide.length > 6) break;
    }
    const clipped = [...document.querySelectorAll("button, .ba-btn, a.ba-btn, .ba-chip, th")].filter((e) => {
      const st = getComputedStyle(e);
      return e.offsetParent && e.scrollWidth > e.clientWidth + 2 && st.overflow !== "visible" && st.textOverflow !== "ellipsis";
    }).slice(0, 6).map((e) => `${sel(e)} "${e.innerText.trim().slice(0, 30)}"`);
    const brokenImg = [...document.querySelectorAll("img")].filter((i) => i.complete && i.naturalWidth === 0 && i.offsetParent).map((i) => i.getAttribute("src")?.slice(0, 80));
    // tables (or boards) that need sideways scrolling inside their box at this width
    const scrollers = [...document.querySelectorAll(".ba-table-wrap, .owner-table-wrap, .zs-table-wrap, [class*='table-wrap']")]
      .filter((w) => w.offsetParent && w.scrollWidth > w.clientWidth + 2).map((w) => `${sel(w)} (+${w.scrollWidth - w.clientWidth}px)`).slice(0, 4);
    const raw = (main.innerText.match(/\b(undefined|NaN|null|\[object Object\]|Invalid Date)\b/g) ?? []);
    return {
      title: (document.querySelector("h1")?.innerText ?? "").slice(0, 80),
      crashed: /Something went wrong/i.test(text),
      notFound: /Page not found/i.test(text),
      notAvailable: /isn't available|not available to your role|don't have access|Platform admin access required|no permission/i.test(text),
      signIn: Boolean(document.querySelector('input[type="password"]') && document.querySelector('input[type="email"]') && !document.querySelector('nav, .ba-sidebar, .owner-sidebar')),
      overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      wide, clipped, brokenImg, scrollers,
      rawValues: [...new Set(raw)],
      empty: main.innerText.trim().length < 20,
      errorsShown: [...document.querySelectorAll('[role="alert"], .zs-banner.error, .owner-form-error, .ba-error')].map((e) => e.innerText.slice(0, 160)).filter(Boolean),
    };
  }, vw);
}

// The menus are buttons, not links, so the pages come from the app's own registries (and record types from the
// test database when ZDB is set), plus links found while crawling.
const ADMIN_PAGES = ["/businesses", "/businesses/new", "/verification", "/industries", "/modules", "/plans", "/offers", "/agents", "/voice",
  "/messaging", "/operations", "/automations", "/integrations", "/support", "/security-abuse", "/users", "/audit-logs"];
async function seeds(isAdmin, email) {
  const { execFileSync } = require("child_process");
  const q = (sql) => { try { return execFileSync("psql", ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB, "-qtAX", "-c", sql], { encoding: "utf8" }).trim().split("\n").filter(Boolean); } catch { return []; } };
  if (isAdmin) return [...ADMIN_PAGES, ...(process.env.ZDB ? q("select '/businesses/' || id from businesses where name like 'B3 Alpha' union all select '/businesses/' || id || '/setup' from businesses where name like 'B3 Alpha'") : [])];
  const nav = await import(path.join(__dirname, "../../web/src/navigation/navConfig.js"));
  const flat = (items) => items.flatMap((i) => (i.children ? [i, ...flat(i.children)] : [i]));
  const pages = flat(nav.NAV_ITEMS).filter((i) => i.page && i.page !== "today").map((i) => `/app/${i.page}`);
  pages.push("/app/record-settings");
  if (process.env.ZDB) for (const k of q(`select distinct t.key from crm_record_types t join business_members m on m.business_id = t.business_id join auth.users u on u.id = m.user_id where lower(u.email) = lower('${email.replace(/'/g, "")}')`)) pages.push(`/app/records/${encodeURIComponent(k)}`);
  return pages;
}

async function sweep(browser, name, email) {
  const vw = MOBILE ? { width: 390, height: 844 } : { width: 1280, height: 860 };
  const ctx = await browser.newContext({ viewport: vw, deviceScaleFactor: 1, colorScheme: DARK ? "dark" : "light", reducedMotion: "reduce", isMobile: MOBILE, hasTouch: MOBILE });
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const req = route.request();
    const url = req.url().replace("https://zlocal.supabase.co", BACKEND);
    try {
      const r = await fetch(url, { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
      await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
    } catch { await route.abort(); }
  });
  // fonts and other outside hosts: answered empty so a blocked network is not reported as a glitch
  await ctx.route(/^https:\/\/(?!zlocal\.supabase\.co|fonts\.googleapis\.com|fonts\.gstatic\.com)/, (r) => r.fulfill({ status: 200, body: "" }));
  const page = await ctx.newPage();
  page.setDefaultTimeout(8000);
  const pageErrors = [], failed = [], consoleErrors = [];
  page.on("pageerror", (e) => pageErrors.push(e.message.slice(0, 200)));
  page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text().slice(0, 200)); });
  page.on("response", async (r) => {
    if (r.status() >= 400 && r.url().includes("zlocal.supabase.co")) {
      let body = ""; try { body = (await r.text()).slice(0, 200); } catch { /* gone */ }
      failed.push({ status: r.status(), url: decodeURIComponent(r.url().replace(/^https?:\/\/[^/]+/, "")).slice(0, 160), body });
    }
  });
  const isAdmin = !/@b3\.test$/.test(email) && /zella\.test$/.test(email);
  const root = isAdmin ? "/" : "/app";
  await page.goto(APP + root);
  await signIn(page, email);
  await page.waitForTimeout(2500);
  const dir = path.join(OUT, `${name}${MOBILE ? "-mobile" : ""}${DARK ? "-dark" : ""}`);
  fs.mkdirSync(dir, { recursive: true });
  const queue = [root, isAdmin ? "/settings" : "/app/settings", ...(await seeds(isAdmin, email))], seen = new Set(), shapes = new Map(), results = [];
  while (queue.length && results.length < MAX) {
    const route = queue.shift();
    const key = route.split("?")[0].split("#")[0];
    if (seen.has(key) || SKIP.test(key)) continue;
    const sh = shape(key);
    if ((shapes.get(sh) ?? 0) >= 1 && sh !== key) continue;
    seen.add(key); shapes.set(sh, (shapes.get(sh) ?? 0) + 1);
    if (ONLY && !key.includes(ONLY)) { /* still crawl through it for links */ }
    pageErrors.length = 0; failed.length = 0; consoleErrors.length = 0;
    await page.goto(APP + key).catch(() => {});
    const stuck = await settle(page);
    if (/\/settings/.test(key)) await openSettingsTree(page);
    if (MOBILE) { // the phone menu: open it to collect its links, then close it
      const burger = page.locator('[aria-label*="menu" i]').first();
      if (await burger.isVisible().catch(() => false)) { await burger.click().catch(() => {}); await page.waitForTimeout(300); }
    }
    for (const h of await links(page, root)) if (!seen.has(h.split("?")[0])) queue.push(h);
    if (MOBILE) await page.keyboard.press("Escape").catch(() => {});
    if (ONLY && !key.includes(ONLY)) continue;
    const info = await inspect(page, vw.width);
    let axe = null;
    if (AXE) {
      await page.addScriptTag({ content: AXE }).catch(() => {});
      axe = await page.evaluate(async () => {
        if (!window.axe) return null;
        const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] }, resultTypes: ["violations"] });
        return r.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => ({ id: v.id, n: v.nodes.length,
          sample: v.nodes.slice(0, 2).map((n) => `${n.target.join(" ")} :: ${(n.failureSummary ?? "").split("\n").slice(-1)[0].slice(0, 120)}`) }));
      }).catch(() => null);
    }
    const shot = path.join(dir, (key.replace(UUID, "id").replace(/[^a-z0-9]+/gi, "_").replace(/^_|_$/g, "") || "root") + ".png");
    await page.screenshot({ path: shot }).catch(() => {});
    const row = { route: key, ...info, stuck, pageErrors: [...pageErrors], failed: [...failed], consoleErrors: [...new Set(consoleErrors)].slice(0, 5), axe, shot };
    const problems = [
      row.crashed && "CRASH", row.pageErrors.length && `pageerror:${row.pageErrors[0]}`, row.notFound && "NOT-FOUND", row.signIn && "SIGNED-OUT",
      row.stuck && "STUCK-LOADING", row.failed.length && `failed:${row.failed.map((f) => `${f.status} ${f.url.split("?")[0]}`).join(",")}`,
      row.consoleErrors.length && `console:${row.consoleErrors[0]}`, row.overflowX > 0 && `overflowX=${row.overflowX} ${row.wide.slice(0, 2).join(" ; ")}`,
      !MOBILE && row.scrollers.length && `table-scrolls:${row.scrollers.join(" ; ")}`,
      row.clipped.length && `clipped:${row.clipped.slice(0, 2).join(" ; ")}`, row.brokenImg.length && "broken-img", row.rawValues.length && `raw:${row.rawValues.join("/")}`,
      row.empty && !row.notAvailable && "EMPTY", row.axe?.length && `axe:${row.axe.map((a) => a.id).join(",")}`,
    ].filter(Boolean);
    row.problems = problems;
    results.push(row);
    console.log(`${problems.length ? "CHECK" : "ok   "} ${name} ${key} [${row.title}] ${problems.join(" | ")}`);
  }
  fs.writeFileSync(path.join(dir, "results.json"), JSON.stringify(results, null, 1));
  await ctx.close();
  return results;
}

(async () => {
  const browser = await chromium.launch();
  const names = !args[0] || args[0] === "all" ? Object.keys(PERSONAS) : args[0].split(",");
  const summary = {};
  for (const n of names) {
    const r = await sweep(browser, n, PERSONAS[n]);
    summary[n] = { pages: r.length, withProblems: r.filter((x) => x.problems.length).length };
  }
  await browser.close();
  console.log(JSON.stringify(summary));
})();
