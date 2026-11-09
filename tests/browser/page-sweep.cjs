// Every page, per role, against a STUBBED backend (no real data, nothing sent).
// Needs the app:  cd web && VITE_SUPABASE_URL=https://example.supabase.co npx vite --port 5199
// Run:  node tests/browser/page-sweep.cjs [crm|admin|public|all]      writes tests/browser/out/page-sweep.json
//
// The page list comes from the app itself: the CRM menu (web/src/navigation/navConfig.js), the admin menu, and the
// Settings trees as the app draws them (every category opened, every subpage link collected).
// Two backends:
//   empty  every database function answers an empty value of the type its live definition returns
//          (tests/browser/rpc-shapes.json, made from sql/baseline), tables answer [], admin actions answer {}
//   error  every call fails (HTTP 500)
// For each page it records: page errors (crashes), the error panel (crash caught by the boundary), "not available",
// and in error mode whether an error or retry message is shown and whether any success wording appears anyway.
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const BASE = process.env.APP_URL ?? "http://localhost:5199";
const SHAPES = JSON.parse(fs.readFileSync(path.join(__dirname, "rpc-shapes.json"), "utf8"));
const B1 = "20000000-0000-0000-0000-000000000001", B2 = "20000000-0000-0000-0000-000000000002";
const user = { id: "30000000-0000-0000-0000-000000000001", email: "person@glow.test", aud: "authenticated", role: "authenticated", factors: [] };
const empty = (fn) => ({ set: [], bool: false, num: 0, text: null, json: null, void: null }[SHAPES[fn] ?? "json"] ?? null);
const SUCCESS = /\b(saved|sent|done|updated successfully|all set)\b/i;
const ERRORISH = /couldn't|could not|went wrong|try again|failed|isn't available|not available|unavailable|error/i;

async function session(b, { role = "owner", mode = "empty", admin = null, width = 1300 } = {}) {
  const ctx = await b.newContext({ viewport: { width, height: 900 } });
  await ctx.addInitScript((u) => {
    const enc = (o) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
    const exp = Math.floor(Date.now() / 1000) + 3600;
    localStorage.setItem("sb-example-auth-token", JSON.stringify({ access_token: `${enc({ alg: "HS256" })}.${enc({ sub: u.id, aal: "aal2", exp, role: "authenticated" })}.sig`, refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp, user: u }));
  }, user);
  const p = await ctx.newPage(); p.setDefaultTimeout(6000);
  const errors = []; p.on("pageerror", (e) => errors.push(e.message.slice(0, 160)));
  await p.route("**/auth/v1/**", (r) => r.fulfill({ json: { currentLevel: "aal2", nextLevel: "aal2" } }));
  await p.route("**/auth/v1/user**", (r) => r.fulfill({ json: user }));
  await p.route("**/storage/v1/**", (r) => mode === "error" ? r.fulfill({ status: 500, json: { message: "boom" } }) : r.fulfill({ json: [] }));
  const ws = (id, name) => ({ id, name, industry: "Salon", role, timezone: "America/New_York", is_active: true, onboarding_status: "active", terminology: {}, modules: ["calendar", "calls", "automations", "ai-receptionist", "sms", "email"], receptionist: { name: "Ava", status: "active" } });
  const NAV = { role, configured: true, industry: { slug: "salon", name: "Salon" }, operations_label: "Salon operations",
    modules: ["ai-receptionist", "automations", "calendar", "calls", "sms", "email"].map((slug) => ({ slug, available: true, enabled: true })) };
  await p.route("**/rest/v1/**", (r) => {
    const u = decodeURIComponent(r.request().url());
    const fn = u.includes("/rpc/") ? u.split("/rpc/")[1].split("?")[0] : null;
    // what is needed to open the app at all always answers
    if (fn === "zella_my_workspaces") return r.fulfill({ json: [ws(B1, "Glow Salon"), ws(B2, "Glow Downtown")] });
    if (fn === "zella_workspace_navigation") return r.fulfill({ json: NAV });
    if (fn === "zella_admin_role") return r.fulfill({ json: admin?.role ?? null });
    if (fn?.startsWith("zella_accept")) return r.fulfill({ json: fn.endsWith("v2") ? { accepted: 0, needs_email_link: 0, errors: [] } : 0 });
    if (fn === "zella_platform_public_info" || fn === "zella_my_profile") return r.fulfill({ json: null });
    if (mode === "error") return r.fulfill({ status: 500, json: { message: "boom", code: "XX000" } });
    return r.fulfill({ json: fn ? empty(fn) : [] });
  });
  await p.route("**/functions/v1/**", (r) => {
    const body = JSON.parse(r.request().postData() || "{}");
    if (body.action === "me_admin" && admin) return r.fulfill({ json: admin });
    if (mode === "error") return r.fulfill({ status: 500, json: { error: "boom" } });
    return r.fulfill({ json: {} });
  });
  return { ctx, p, errors };
}

async function visit(p, errors, url, { inApp = true } = {}) {
  errors.length = 0;
  if (inApp) await p.evaluate((to) => { history.pushState(null, "", to); dispatchEvent(new PopStateEvent("popstate")); }, url);
  else await p.goto(BASE + url);
  await p.waitForTimeout(900);
  const main = await p.locator("main, .owner-content").first().innerText().catch(() => "");
  return {
    url,
    crash: errors.length ? errors.join(" | ") : null,
    boundary: /Something went wrong/.test(main),
    unavailable: /isn't available|Not available|don't have access|no permission/i.test(main),
    notFound: /Page not found/.test(main),
    errorShown: ERRORISH.test(main),
    successWording: SUCCESS.test(main) ? (main.match(SUCCESS) || [""])[0] : null,
    loadingStuck: /^\s*(Loading|Loading…|Loading\.\.\.)\s*$/i.test(main.trim().split("\n").slice(-3).join(" ")),
    text: main.replace(/\s+/g, " ").slice(0, 140),
  };
}

async function settingsLinks(p, prefix) {
  await p.waitForSelector(".zs-tree", { timeout: 8000 }).catch(() => {});
  const cats = await p.locator(".zs-cat").count();
  for (let i = 0; i < cats; i++) {
    const c = p.locator(".zs-cat").nth(i);
    if ((await c.getAttribute("aria-expanded")) !== "true") await c.click();
  }
  return [...new Set(await p.$$eval(`.zs-tree a[href^="${prefix}"]`, (els) => els.map((e) => e.getAttribute("href"))))];
}

async function crm(b, report) {
  const nav = await import(path.join(__dirname, "../../web/src/navigation/navConfig.js"));
  const flat = (items) => items.flatMap((i) => i.children ? flat(i.children) : [i]);
  const all = flat(nav.NAV_ITEMS ?? nav.ITEMS ?? []).filter((i) => i.page && !i.page.startsWith("rec:"));
  const pages = [...new Map(all.map((i) => [i.page, i])).values()];
  for (const role of ["owner", "admin", "manager", "staff", "viewer"]) {
    for (const mode of ["empty", "error"]) {
      if (mode === "error" && !["owner", "staff"].includes(role)) continue;
      const { ctx, p, errors } = await session(b, { role, mode });
      await p.goto(BASE + "/app"); await p.waitForTimeout(1500);
      for (const item of pages) {
        const r = await visit(p, errors, item.page === "today" ? "/app" : `/app/${item.page}`);
        const allowed = !item.roles || item.roles.includes(role);
        report.push({ app: "crm", role, mode, page: item.page, allowed, ...r, roleLeak: !allowed && !r.unavailable });
      }
      if (role === "owner" || role === "viewer" || (role === "staff" && mode === "empty")) {
        // the tree is read on a settings page that needs no data, so one page failing can't hide the others
        await visit(p, errors, "/app/settings/me/appearance");
        for (const href of await settingsLinks(p, "/app/settings/")) {
          const r = await visit(p, errors, href);
          report.push({ app: "crm", role, mode, page: href.replace("/app/", ""), ...r });
        }
      }
      // switching business keeps the page and loads the other business
      if (mode === "empty") {
        await visit(p, errors, "/app/calendar");
        const sw = p.locator(".ba-switcher-btn");
        if (await sw.count()) {
          await sw.click(); await p.locator('.ba-menu-item:has-text("Glow Downtown")').click().catch(() => {});
          await p.waitForTimeout(900);
          report.push({ app: "crm", role, mode, page: "switch-business", url: p.url(), crash: errors.join(" | ") || null,
            switched: /Glow Downtown/.test(await p.locator(".ba-switcher-btn").innerText()), stayed: new URL(p.url()).pathname === "/app/calendar" });
        }
      }
      await ctx.close();
    }
  }
}

const ALL_PERMS = ["businesses.view", "businesses.manage", "businesses.lifecycle", "plans.manage", "billing.view", "billing.manage", "ai.configure", "telephony.manage",
  "integrations.manage", "comms.manage", "support.manage", "security.view", "security.manage", "audit.view", "analytics.view", "legal.manage", "platform.configure", "admins.manage", "roles.manage"];
const ADMIN_NAV = [
  ["/", "businesses.view"], ["/businesses", "businesses.view"], ["/businesses/new", "businesses.manage"], ["/verification", "businesses.manage"], ["/industries", "businesses.view"], ["/modules", "businesses.view"],
  ["/plans", "billing.view"], ["/offers", "billing.view"], ["/agents", "businesses.view"], ["/voice", "businesses.view"], ["/messaging", "businesses.view"],
  ["/operations", "businesses.view"], ["/automations", "businesses.view"], ["/integrations", "businesses.view"], ["/support", "support.manage"],
  ["/security-abuse", "security.view"], ["/users", "security.view"], ["/audit-logs", "audit.view"], ["/settings", null],
];
async function admin(b, report) {
  const roles = {
    zella_owner: { role: "zella_owner", roleLabel: "Zella Voice owner", permissions: ALL_PERMS, mfa: true, aal: "aal2" },
    read_only_admin: { role: "read_only_admin", roleLabel: "Read-only admin", permissions: ["businesses.view", "billing.view", "security.view", "audit.view", "analytics.view"], mfa: true, aal: "aal2" },
    support_admin: { role: "support_admin", roleLabel: "Support admin", permissions: ["businesses.view", "support.manage"], mfa: true, aal: "aal2" },
  };
  for (const [name, me] of Object.entries(roles)) {
    for (const mode of ["empty", "error"]) {
      if (mode === "error" && name !== "zella_owner") continue;
      const { ctx, p, errors } = await session(b, { mode, admin: me });
      await p.goto(BASE + "/"); await p.waitForTimeout(1800);
      for (const [url, perm] of ADMIN_NAV) {
        const r = await visit(p, errors, url);
        const allowed = !perm || me.permissions.includes(perm);
        report.push({ app: "admin", role: name, mode, page: url, allowed, ...r, roleLeak: !allowed && !r.unavailable });
      }
      if (name !== "support_admin") {
        await visit(p, errors, "/settings/profile/appearance");
        for (const href of await settingsLinks(p, "/settings/")) {
          const r = await visit(p, errors, href);
          report.push({ app: "admin", role: name, mode, page: href, ...r });
        }
      }
      await ctx.close();
    }
  }
}

async function publicLinks(b, report) {
  const hex = (n) => "a".repeat(n);
  const cases = [
    ["/r/" + hex(64), "reschedule link"], ["/r/notatoken", "broken reschedule link"], ["/u/" + hex(32), "unsubscribe link"], ["/u/bad", "broken unsubscribe link"],
    ["/w/" + hex(64), "waitlist offer link"], ["/w/123", "broken waitlist link"], ["/status", "status page"], ["/welcome", "welcome without a code"],
    ["/welcome#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired", "expired email link"],
    ["/continue-plan", "continue plan without a code"],
  ];
  for (const mode of ["empty", "error"]) {
    for (const [url, what] of cases) {
      const ctx = await b.newContext({ viewport: { width: 420, height: 860 } });
      const p = await ctx.newPage(); const errors = []; p.on("pageerror", (e) => errors.push(e.message.slice(0, 160)));
      await p.route("**/rest/v1/**", (r) => mode === "error" ? r.fulfill({ status: 500, json: { message: "boom" } }) : r.fulfill({ json: null }));
      // as the functions answer: an unknown code is { ok: false, reason: "invalid" }; a server problem is a 500 with a message
      await p.route("**/functions/v1/**", (r) => mode === "error" ? r.fulfill({ status: 500, json: { error: "This link can't be used right now. Please contact the business." } }) : r.fulfill({ json: { ok: false, reason: "invalid" } }));
      await p.route("**/auth/v1/**", (r) => r.fulfill({ status: 400, json: { error: "invalid", error_description: "invalid" } }));
      await p.goto(BASE + url); await p.waitForTimeout(1500);
      const text = (await p.locator("body").innerText()).replace(/\s+/g, " ");
      report.push({ app: "public", mode, page: what, url, crash: errors.join(" | ") || null, adminSignIn: /OWNER ACCESS|Sign in to your Zella Voice platform/i.test(text),
        errorShown: ERRORISH.test(text) || /expired|not valid|invalid/i.test(text), text: text.slice(0, 140) });
      await ctx.close();
    }
  }
}

(async () => {
  const which = process.argv[2] ?? "all";
  const b = await chromium.launch();
  const report = [];
  if (which === "all" || which === "public") await publicLinks(b, report);
  if (which === "all" || which === "crm") await crm(b, report);
  if (which === "all" || which === "admin") await admin(b, report);
  await b.close();
  fs.mkdirSync(path.join(__dirname, "out"), { recursive: true });
  fs.writeFileSync(path.join(__dirname, "out", `page-sweep-${which}.json`), JSON.stringify(report, null, 1));
  const bad = report.filter((r) => r.crash || r.boundary || r.roleLeak || r.adminSignIn || (r.mode === "error" && r.app !== "public" && !r.errorShown && !r.unavailable && !r.notFound)
    || (r.mode === "error" && r.successWording));
  console.log(`${report.length} page visits, ${bad.length} to look at`);
  for (const r of bad) console.log(JSON.stringify({ app: r.app, role: r.role, mode: r.mode, page: r.page, crash: r.crash, boundary: r.boundary, roleLeak: r.roleLeak, adminSignIn: r.adminSignIn, success: r.successWording, text: r.text }));
})();
