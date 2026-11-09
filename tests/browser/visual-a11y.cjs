// Real-browser look and accessibility pass, STUBBED backend. Screenshots in tests/browser/out/shots/.
// Needs the app (vite on 5199) and axe-core:  AXE=/path/to/axe.min.js node tests/browser/visual-a11y.cjs
//   (axe-core is not a project dependency; install it anywhere outside the repo, e.g. npm i --prefix /tmp/axe axe-core)
// For Classic and Glass, at 1366 (desktop), 820 (tablet) and 390 (phone) wide: axe rules (contrast, names, labels,
// ARIA), horizontal page overflow, visible keyboard focus, reduced motion, and pages with Google Fonts blocked.
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const BASE = process.env.APP_URL ?? "http://localhost:5199";
const AXE = fs.readFileSync(process.env.AXE ?? require.resolve("axe-core/axe.min.js"), "utf8");
const OUT = path.join(__dirname, "out", "shots"); fs.mkdirSync(OUT, { recursive: true });
const B1 = "20000000-0000-0000-0000-000000000001";
const user = { id: "30000000-0000-0000-0000-000000000001", email: "owner@glow.test", aud: "authenticated", role: "authenticated", factors: [] };
const now = Date.now(); const ago = (m) => new Date(now - m * 60000).toISOString();
const ws = { id: B1, name: "Glow & Grace Hair and Beauty Studio of Greater Austin", industry: "Salon", role: "owner", timezone: "America/New_York", is_active: true, onboarding_status: "active",
  terminology: {}, modules: ["calendar", "calls", "automations", "ai-receptionist"], receptionist: { name: "Ava", status: "active" }, phone_connected: true, voice_connected: true };
const NAV = { role: "owner", configured: true, industry: { slug: "salon", name: "Salon" }, operations_label: "Salon operations",
  modules: ["ai-receptionist", "automations", "calendar", "calls", "sms", "email"].map((slug) => ({ slug, available: true, enabled: true })) };
const CALLS = [1, 2, 3, 4].map((n) => ({ id: "c" + n, business_id: B1, status: ["completed", "missed", "failed", "answered"][n - 1], direction: "inbound", ai_handled: n !== 4, from_number: "+1555000000" + n, created_at: ago(n * 30), duration_seconds: 80, metadata: {} }));
const ME = { role: "zella_owner", roleLabel: "Zella Voice owner", permissions: ["businesses.view", "businesses.manage", "billing.view", "security.view", "audit.view", "support.manage", "analytics.view"], mfa: true, aal: "aal2" };
const DASH = { businesses: [1, 2, 3].map((n) => ({ id: `4000000${n}-0000-0000-0000-000000000000`, name: ["Bright Smile Family Dentistry and Orthodontics", "Glow Salon", "Fix-It Plumbing"][n - 1], industry: "Dental", onboarding_status: ["active", "owner_setup", "testing"][n - 1], is_active: n === 1, invitations: [{ status: "sent" }], created_at: ago(n * 1000), updated_at: ago(n * 100) })),
  industries: [{ id: "i1", name: "Dental", slug: "dental", is_active: true }], stats: { totalBusinesses: 3, activeWorkspaces: 1, pendingInvitations: 1, provisioningIssues: 0 } };

const PAGES = [
  { app: "crm", url: "/app", name: "crm-today", ready: ".ba-content" },
  { app: "crm", url: "/app/calls", name: "crm-calls", ready: ".ba-content" },
  { app: "crm", url: "/app/settings/profile/info", name: "crm-settings", ready: ".zs-card" },
  { app: "crm", url: "/app/settings/me/appearance", name: "crm-appearance", ready: ".zs-look-grid" },
  { app: "admin", url: "/", name: "admin-overview", ready: ".owner-content" },
  { app: "admin", url: "/businesses", name: "admin-businesses", ready: ".owner-content" },
  { app: "admin", url: "/settings/profile/appearance", name: "admin-appearance", ready: ".owner-content" },
  { app: "public", url: "/app", name: "crm-sign-in", ready: "form", signedOut: true },
  { app: "public", url: "/r/" + "b".repeat(64), name: "public-reschedule", ready: "main" },
];

async function page(b, { theme, width, blockFonts = false, reducedMotion = "no-preference", signedOut = false }) {
  const ctx = await b.newContext({ viewport: { width, height: 900 }, reducedMotion });
  await ctx.addInitScript(({ u, theme, signedOut }) => {
    const enc = (o) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
    const exp = Math.floor(Date.now() / 1000) + 3600;
    if (!signedOut) localStorage.setItem("sb-example-auth-token", JSON.stringify({ access_token: `${enc({ alg: "HS256" })}.${enc({ sub: u.id, aal: "aal2", exp, role: "authenticated" })}.sig`, refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp, user: u }));
    for (const scope of ["crm", "admin"]) localStorage.setItem(`zella.appearance.${scope}`, JSON.stringify({ user: u.id, pref: { theme, background: "mountains", dim: 35 } }));
  }, { u: { ...user, user_metadata: { zella_appearance: { crm: { theme, background: "mountains", dim: 35 }, admin: { theme, background: "mountains", dim: 35 } } } }, theme, signedOut });
  const p = await ctx.newPage(); p.setDefaultTimeout(9000);
  const errors = []; p.on("pageerror", (e) => errors.push(e.message.slice(0, 160)));
  if (blockFonts) await p.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  await p.route("**/auth/v1/**", (r) => signedOut ? r.fulfill({ status: 401, json: { message: "no session" } }) : r.fulfill({ json: { currentLevel: "aal2", nextLevel: "aal2" } }));
  await p.route("**/auth/v1/user**", (r) => signedOut ? r.fulfill({ status: 401, json: { message: "no session" } })
    : r.fulfill({ json: { ...user, user_metadata: { zella_appearance: { crm: { theme, background: "mountains", dim: 35 }, admin: { theme, background: "mountains", dim: 35 } } } } }));
  await p.route("**/rest/v1/**", (r) => {
    const u = decodeURIComponent(r.request().url());
    const fn = u.includes("/rpc/") ? u.split("/rpc/")[1].split("?")[0] : null;
    if (fn === "zella_my_workspaces") return r.fulfill({ json: [ws, { ...ws, id: "20000000-0000-0000-0000-000000000002", name: "Glow Downtown" }] });
    if (fn === "zella_workspace_navigation") return r.fulfill({ json: NAV });
    if (fn === "zella_admin_role") return r.fulfill({ json: "zella_owner" });
    if (fn === "zella_business_settings") return r.fulfill({ json: { business: { name: ws.name, city: "Austin", country: "US" }, hours: [], closures: [] } });
    if (fn?.startsWith("zella_accept")) return r.fulfill({ json: fn.endsWith("v2") ? { accepted: 0, needs_email_link: 0, errors: [] } : 0 });
    if (u.includes("calls_view")) return r.fulfill({ json: CALLS });
    return r.fulfill({ json: fn ? null : [] });
  });
  await p.route("**/functions/v1/**", (r) => {
    const body = JSON.parse(r.request().postData() || "{}");
    if (body.action === "me_admin") return r.fulfill({ json: ME });
    if (body.action === "dashboard_data") return r.fulfill({ json: DASH });
    if (body.token) return r.fulfill({ json: { ok: false, reason: "invalid" } });
    return r.fulfill({ json: {} });
  });
  return { ctx, p, errors };
}

const summary = [];
(async () => {
  const b = await chromium.launch();
  for (const theme of ["zella", "classic", "glass"]) {
    for (const width of [1366, 820, 390]) {
      for (const pg of PAGES) {
        if (pg.app === "public" && theme === "glass") continue;   // sign-in and customer pages are not themed
        const { ctx, p, errors } = await page(b, { theme, width, signedOut: pg.signedOut });
        await p.goto(BASE + pg.url);
        await p.waitForSelector(pg.ready).catch(() => {});
        await p.waitForTimeout(1200);
        const shot = `${pg.name}-${theme}-${width}.png`;
        await p.screenshot({ path: path.join(OUT, shot) });
        await p.addScriptTag({ content: AXE });
        const axe = await p.evaluate(async () => {
          const r = await window.axe.run(document, { resultTypes: ["violations"], runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] } });
          return r.violations.map((v) => ({ id: v.id, impact: v.impact, n: v.nodes.length, sample: v.nodes.slice(0, 3).map((x) => x.target.join(" ") + (x.any?.[0]?.message ? " :: " + x.any[0].message.slice(0, 120) : "")) }));
        });
        const overflow = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        // keyboard: the first 8 Tab stops each show a visible focus indicator
        const focus = [];
        for (let i = 0; i < 8; i++) {
          await p.keyboard.press("Tab");
          focus.push(await p.evaluate(() => {
            const el = document.activeElement; if (!el || el === document.body) return null;
            const cs = getComputedStyle(el);
            const visible = (cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0) || (cs.boxShadow && cs.boxShadow !== "none");
            return { el: `${el.tagName.toLowerCase()}${el.className ? "." + String(el.className).split(" ")[0] : ""}`, name: (el.getAttribute("aria-label") || el.innerText || "").trim().slice(0, 30), visible };
          }));
        }
        summary.push({ page: pg.name, theme, width, shot, errors, overflow, axe, noFocusRing: focus.filter((f) => f && !f.visible) });
        await ctx.close();
      }
    }
  }
  // Google Fonts blocked: icons must not turn into their names
  for (const pg of [PAGES[0], PAGES[4]]) {
    const { ctx, p } = await page(b, { theme: "classic", width: 1366, blockFonts: true });
    await p.goto(BASE + pg.url); await p.waitForSelector(pg.ready).catch(() => {}); await p.waitForTimeout(4500);
    await p.screenshot({ path: path.join(OUT, `${pg.name}-nofonts.png`) });
    const iconText = await p.evaluate(() => {
      const icons = [...document.querySelectorAll(".ba-icon")].filter((e) => e.offsetParent);
      const iconFont = document.fonts.check('20px "Material Symbols Outlined"');
      const shown = icons.filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && getComputedStyle(e).fontSize !== "0px" && getComputedStyle(e).color !== "rgba(0, 0, 0, 0)" && getComputedStyle(e).visibility !== "hidden"; });
      return { icons: icons.length, iconFont, visibleAsText: iconFont ? 0 : shown.length, bodyFont: getComputedStyle(document.body).fontFamily };
    });
    summary.push({ page: `${pg.name} (Google Fonts blocked)`, ...iconText });
    await ctx.close();
  }
  // reduced motion: nothing keeps animating
  {
    const { ctx, p } = await page(b, { theme: "glass", width: 1366, reducedMotion: "reduce" });
    await p.goto(BASE + "/app"); await p.waitForSelector(".ba-content").catch(() => {}); await p.waitForTimeout(1500);
    const anim = await p.evaluate(() => document.getAnimations().filter((a) => a.playState === "running").map((a) => (a.animationName || a.constructor.name) + " " + (a.effect?.getComputedTiming?.().duration ?? "")));
    summary.push({ page: "reduced motion (CRM Today, Glass)", runningAnimations: anim.slice(0, 10), count: anim.length });
    await ctx.close();
  }
  await b.close();
  fs.writeFileSync(path.join(__dirname, "out", "visual-a11y.json"), JSON.stringify(summary, null, 1));
  // compact report
  const byRule = {};
  for (const s of summary) for (const v of s.axe ?? []) { const k = `${v.id} (${v.impact})`; (byRule[k] ??= new Set()).add(`${s.page}/${s.theme}/${s.width}`); }
  console.log("axe violations by rule:"); for (const [k, v] of Object.entries(byRule)) console.log(`  ${k}: ${v.size} views, e.g. ${[...v].slice(0, 3).join(", ")}`);
  console.log("page overflow > 2px:", summary.filter((s) => s.overflow > 2).map((s) => `${s.page}/${s.theme}/${s.width}:+${s.overflow}`).join(", ") || "none");
  console.log("no visible focus:", [...new Set(summary.flatMap((s) => (s.noFocusRing ?? []).map((f) => `${s.page}: ${f.el} "${f.name}"`)))].slice(0, 12).join(" | ") || "none");
  console.log("page errors:", summary.filter((s) => s.errors?.length).map((s) => `${s.page}/${s.theme}/${s.width}: ${s.errors[0]}`).join(" | ") || "none");
  for (const s of summary.filter((s) => s.page.includes("blocked") || s.page.includes("reduced"))) console.log(JSON.stringify(s));
})();
