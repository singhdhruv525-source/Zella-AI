// Sidebar logo and default theme, in a real browser against the local stand-in (see README.md). Test data only.
// Checks, for the admin dashboard and the CRM:
//  - the Zella Voice theme is the default without a saved look; a saved look (Classic, Glass) is kept;
//  - expanded: the full official logo, not stretched, inside the sidebar, the bar symbol exactly on the logo's bars;
//  - collapsed (dock, tablet rail): only the bars, centred, same size;
//  - the transition: frames during expand and collapse never stretch the bars, never cut the visible wordmark off,
//    and never scroll the page sideways; reduced motion turns the movement off;
//  - the phone drawer shows the expanded logo; "Zella Voice" is the accessible name in every state.
// Usage: node tests/browser/brand-check.cjs   (env OUT for screenshots)
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const path = require("path");
const APP = process.env.APP_URL ?? "http://localhost:5199", BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const OUT = process.env.OUT ?? "/tmp";
const PG = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zella_ui", "-AtqX", "-c"];
const sql = (q) => execFileSync("psql", [...PG, q]).toString().trim();
const B1 = "b0000000-0000-0000-0000-000000000001";
let fails = 0;
const check = (name, ok, detail = "") => { if (!ok) fails++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` - ${detail}` : ""}`); };
const look = (email, value) => sql(`update auth.users set raw_user_meta_data = ${value ? `coalesce(raw_user_meta_data,'{}') || '{"zella_appearance": ${JSON.stringify(value)}}'::jsonb` : "raw_user_meta_data - 'zella_appearance'"} where email = '${email}'`);

async function open(browser, email, route, { width = 1280, height = 860, reduced = false } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 2, reducedMotion: reduced ? "reduce" : "no-preference" });
  await ctx.addInitScript((id) => localStorage.setItem("zella.lastBusiness", id), B1);
  await ctx.route("https://zlocal.supabase.co/**", async (r) => {
    const q = r.request();
    const res = await fetch(q.url().replace("https://zlocal.supabase.co", BACKEND), { method: q.method(), headers: q.headers(), body: ["GET", "HEAD"].includes(q.method()) ? undefined : q.postDataBuffer() });
    await r.fulfill({ status: res.status, headers: Object.fromEntries(res.headers.entries()), body: Buffer.from(await res.arrayBuffer()) });
  });
  const p = await ctx.newPage();
  await p.goto(APP + (email.includes("zella.test") ? "/" : "/app"));
  await p.fill('input[type="email"]', email);
  if (!(await p.$('input[type="password"]'))) await p.click('button[type="submit"]');
  await p.fill('input[type="password"]', "Test-pass-1");
  await p.click('button[type="submit"]');
  await p.waitForTimeout(2500);
  if (route) { await p.goto(APP + route); await p.waitForTimeout(2000); }
  return { ctx, p };
}

// Where everything is, right now.
const measure = (p, side) => p.evaluate((side) => {
  const s = document.querySelector(side), b = s?.querySelector(".zv-brand");
  if (!b) return null;
  const vis = [...b.querySelectorAll(".zv-brand-full")].find((e) => getComputedStyle(e).display !== "none");
  const mark = b.querySelector(".zv-brand-mark"), logo = b.querySelector(".zv-brand-logo");
  const r = (e) => { const x = e.getBoundingClientRect(); return { x: x.x, y: x.y, w: x.width, h: x.height, r: x.right }; };
  const sr = r(s), cs = getComputedStyle(s);
  return {
    theme: document.documentElement.dataset.zellaTheme, sidebar: document.documentElement.dataset.zellaSidebar,
    side: sr, innerL: sr.x + parseFloat(cs.paddingLeft) + parseFloat(cs.borderLeftWidth), innerR: sr.r - parseFloat(cs.paddingRight),
    full: r(vis), fullOpacity: Number(getComputedStyle(vis).opacity), fullSrc: vis.getAttribute("src"),
    natural: vis.naturalWidth / vis.naturalHeight, mark: r(mark), markNatural: mark.naturalWidth / mark.naturalHeight,
    label: logo.getAttribute("aria-label"), role: logo.getAttribute("role"),
    scrollX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    duration: getComputedStyle(mark).transitionDuration,
  };
}, side);

function expandedOk(m, tag) {
  check(`${tag}: full logo shown`, m.fullOpacity > 0.99, `opacity ${m.fullOpacity}`);
  check(`${tag}: logo keeps its proportions`, Math.abs(m.full.w / m.full.h - m.natural) < 0.02, `${(m.full.w / m.full.h).toFixed(3)} vs ${m.natural.toFixed(3)}`);
  check(`${tag}: logo fits inside the sidebar`, m.full.x >= m.innerL - 0.5 && m.full.r <= m.innerR + 0.5, `${m.full.x.toFixed(1)}-${m.full.r.toFixed(1)} in ${m.innerL.toFixed(1)}-${m.innerR.toFixed(1)}`);
  const ex = m.full.x + m.full.w * 0.282524, ey = m.full.y + m.full.h * 0.001587;
  check(`${tag}: bar symbol sits on the logo's own bars`, Math.abs(m.mark.x - ex) < 0.6 && Math.abs(m.mark.y - ey) < 0.6 && Math.abs(m.mark.h - m.full.h * 0.980952) < 0.6, `dx ${(m.mark.x - ex).toFixed(2)}, dy ${(m.mark.y - ey).toFixed(2)}`);
}
function collapsedOk(m, tag, markH) {
  check(`${tag}: wordmark hidden`, m.fullOpacity < 0.01, `opacity ${m.fullOpacity}`);
  const c = (m.innerL + m.innerR) / 2, mc = m.mark.x + m.mark.w / 2;
  check(`${tag}: bars centred`, Math.abs(c - mc) < 1, `off by ${(mc - c).toFixed(2)}px`);
  check(`${tag}: bars same size as expanded, not stretched`, Math.abs(m.mark.h - markH) < 0.3 && Math.abs(m.mark.w / m.mark.h - m.markNatural) < 0.02, `${m.mark.w.toFixed(2)}x${m.mark.h.toFixed(2)}`);
  check(`${tag}: accessible name stays`, m.role === "img" && m.label === "Zella Voice");
}

(async () => {
  const browser = await chromium.launch();
  const apps = [
    { name: "admin", email: "admin@zella.test", side: ".owner-sidebar", route: "/", tablet: 850, toggle: ".owner-sidebar .zella-dock-toggle" },
    { name: "crm", email: "owner@glow.test", side: ".ba-sidebar", route: "/app/today", tablet: 1000, toggle: ".ba-sidebar .zella-dock-toggle" },
  ];
  for (const a of apps) {
    // default theme (no saved look) and sidebar states
    look(a.email, null);
    const { ctx, p } = await open(browser, a.email, a.route);
    let m = await measure(p, a.side);
    check(`${a.name}: no saved look -> Zella Voice theme`, m.theme === "zella", m.theme);
    check(`${a.name}: colour logo on the light sidebar`, m.fullSrc.endsWith("zella-voice-logo-sidebar.png"));
    expandedOk(m, `${a.name} expanded`);
    const markH = m.mark.h;
    await p.screenshot({ path: path.join(OUT, `brand-${a.name}-expanded.png`), clip: { x: 0, y: 0, width: 420, height: 320 } });

    // collapse, sampling frames during the transition
    await p.click(a.toggle);
    const frames = [];
    for (let i = 0; i < 8; i++) { frames.push(await measure(p, a.side)); await p.waitForTimeout(35); }
    await p.waitForTimeout(400);
    m = await measure(p, a.side);
    collapsedOk(m, `${a.name} collapsed`, markH);
    await p.locator(a.side).evaluate((e) => e.scrollTo(0, 0));
    await p.screenshot({ path: path.join(OUT, `brand-${a.name}-collapsed.png`), clip: { x: 0, y: 0, width: 420, height: 320 } });
    const bad = frames.filter((f) => Math.abs(f.mark.h - markH) > 0.3 || (f.fullOpacity > 0.05 && f.full.r > f.side.r + 0.5) || f.scrollX > 0);
    check(`${a.name} collapsing: bars keep their size, visible wordmark never cut off, no sideways scroll`, bad.length === 0, `${bad.length} bad of ${frames.length} frames`);
    check(`${a.name}: the movement is animated (240 ms)`, frames[0].duration.includes("0.24s"), frames[0].duration);

    // a frame in the middle of expanding, for people to look at
    await p.click(a.toggle); await p.waitForTimeout(120);
    await p.screenshot({ path: path.join(OUT, `brand-${a.name}-mid-expand.png`), clip: { x: 0, y: 0, width: 420, height: 320 } });
    await p.waitForTimeout(500); await p.click(a.toggle); await p.waitForTimeout(500);
    // expand again, sampling frames
    await p.click(a.toggle);
    const back = [];
    for (let i = 0; i < 8; i++) { back.push(await measure(p, a.side)); await p.waitForTimeout(35); }
    await p.waitForTimeout(400);
    const bad2 = back.filter((f) => Math.abs(f.mark.h - markH) > 0.3 || (f.fullOpacity > 0.05 && f.full.r > f.side.r + 0.5) || f.scrollX > 0);
    check(`${a.name} expanding: bars keep their size, visible wordmark never cut off, no sideways scroll`, bad2.length === 0, `${bad2.length} bad of ${back.length} frames`);
    expandedOk(await measure(p, a.side), `${a.name} expanded again`);
    await ctx.close();

    // tablet rail: collapsed without the dock
    {
      const { ctx, p } = await open(browser, a.email, a.route, { width: a.tablet });
      collapsedOk(await measure(p, a.side), `${a.name} tablet rail (${a.tablet}px)`, markH);
      await ctx.close();
    }
    // phone drawer: expanded
    {
      const { ctx, p } = await open(browser, a.email, a.route, { width: 390, height: 844 });
      await p.locator(a.name === "admin" ? ".owner-menu-btn" : ".ba-menu-btn").first().click();
      await p.waitForTimeout(500);
      const d = await measure(p, a.side);
      expandedOk(d, `${a.name} phone drawer`);
      await p.locator(a.side).screenshot({ path: path.join(OUT, `brand-${a.name}-phone.png`) });
      await ctx.close();
    }
    // reduced motion: no movement
    {
      const { ctx, p } = await open(browser, a.email, a.route, { reduced: true });
      const r = await measure(p, a.side);
      check(`${a.name}: reduced motion turns the movement off`, parseFloat(r.duration) < 0.001, r.duration);
      await ctx.close();
    }
    // a saved look is kept, and Glass uses the white logo
    for (const [theme, file] of [["classic", "zella-voice-logo-sidebar.png"], ["glass", "zella-voice-logo-sidebar-white.png"]]) {
      look(a.email, { admin: { theme }, crm: { theme } });
      const { ctx, p } = await open(browser, a.email, a.route);
      const g = await measure(p, a.side);
      check(`${a.name}: saved ${theme} look is kept`, g.theme === theme, g.theme);
      check(`${a.name}: ${theme} uses ${file}`, g.fullSrc.endsWith(file));
      if (theme === "glass") { await p.waitForTimeout(800); await p.screenshot({ path: path.join(OUT, `brand-${a.name}-glass-collapsed.png`), clip: { x: 0, y: 0, width: 420, height: 320 } }); }
      else expandedOk(g, `${a.name} classic`);
      await ctx.close();
    }
    look(a.email, null);
  }
  await browser.close();
  console.log(fails ? `${fails} FAILED` : "ALL PASSED");
  process.exit(fails ? 1 : 0);
})();
