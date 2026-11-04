// Browser checks for the 2026-11-04 security fixes, against a STUBBED backend (no real Supabase, no emails sent).
// Needs the app running locally:  cd web && VITE_SUPABASE_URL=https://example.supabase.co npx vite --port 5199
// Run:  node tests/browser/security-journeys.cjs
// Covers: malformed addresses (/app/%), unknown pages, a page that crashes (error boundary, recovers on navigation),
// Back/Forward between settings sections, a page the role can't see, business switching, and the invitation banner
// (waiting for an email link, failure with Try again, a named problem) while existing workspaces stay usable.
const { chromium } = require("playwright");
const BASE = process.env.APP_URL ?? "http://localhost:5199";
const B1 = "20000000-0000-0000-0000-000000000001", B2 = "20000000-0000-0000-0000-000000000002";
const ws = (id, name, role) => ({ id, name, industry: "Salon", role, timezone: "America/New_York", is_active: true, onboarding_status: "active",
  terminology: {}, modules: ["calendar", "calls"], receptionist: { name: "Ava", status: "active" }, phone_connected: true, voice_connected: true });
const nav = (role, pages) => ({ role, configured: true, industry: { slug: "salon", name: "Salon" }, operations_label: "Salon operations",
  modules: pages.map((slug) => ({ slug, available: true, enabled: true })), location: "Austin, US", phone: "+15551234567" });
const user = { id: "30000000-0000-0000-0000-000000000001", email: "owner@glow.test", aud: "authenticated", role: "authenticated", factors: [] };

let results = [];
const check = (name, ok, detail = "") => { results.push({ name, ok }); console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); };

async function session(b, scenario) {
  const ctx = await b.newContext({ viewport: { width: 1300, height: 900 } });
  await ctx.addInitScript((u) => {
    const enc = (o) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
    const exp = Math.floor(Date.now() / 1000) + 3600;
    const token = { access_token: `${enc({ alg: "HS256", typ: "JWT" })}.${enc({ sub: u.id, aal: "aal1", amr: [{ method: "password" }], exp, role: "authenticated" })}.sig`,
      refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp, user: u };
    for (const k of ["sb-example-auth-token", "sb-localhost-auth-token"]) localStorage.setItem(k, JSON.stringify(token));
  }, user);
  const p = await ctx.newPage();
  const errors = []; p.on("pageerror", (e) => errors.push(e.message));
  const calls = [];
  await p.route("**/auth/v1/**", (r) => {
    const u = r.request().url(); calls.push("auth:" + u.split("/auth/v1/")[1].split("?")[0]);
    if (u.includes("/otp")) return r.fulfill({ json: {} });
    return u.includes("/user") ? r.fulfill({ json: user }) : r.fulfill({ json: { currentLevel: "aal1", nextLevel: "aal1" } });
  });
  await p.route("**/rest/v1/**", (r) => {
    const u = decodeURIComponent(r.request().url());
    if (!u.includes("/rpc/")) return r.fulfill({ json: [] });
    const fn = u.split("/rpc/")[1].split("?")[0]; calls.push(fn);
    const body = r.request().postData() ? JSON.parse(r.request().postData()) : {};
    const s = scenario;
    if (fn === "zella_my_workspaces") return r.fulfill({ json: s.workspaces });
    if (fn === "zella_workspace_navigation") return r.fulfill({ json: s.nav(body.p_business_id) });
    if (fn === "zella_my_profile") return r.fulfill({ json: { first_name: "Sam", last_name: "Lee" } });
    if (fn === "zella_accept_my_invitations") return r.fulfill({ json: 0 });
    if (fn === "zella_accept_staff_invitations_v2") return s.staffInvites(r);
    // a broken answer (null) makes the settings page throw: used on purpose to test the error boundary
    if (fn === "zella_business_settings") return r.fulfill({ json: s.crashSettings ? null : { business: { name: "Glow Salon", city: "Austin", country: "US" }, hours: [], closures: [] } });
    return r.fulfill({ json: null });
  });
  return { ctx, p, errors, calls };
}

const owner = { workspaces: [ws(B1, "Glow Salon", "owner"), ws(B2, "Glow Downtown", "owner")],
  nav: () => nav("owner", ["calendar", "calls", "team", "inbox"]), staffInvites: (r) => r.fulfill({ json: { accepted: 0, needs_email_link: 0, expired: 0, errors: [] } }) };

(async () => {
  const b = await chromium.launch();

  // 1. Malformed and unknown addresses
  {
    const { ctx, p, errors } = await session(b, owner);
    // A malformed address straight to the dev server is refused by Vite itself (404 before the app loads), so the
    // app is loaded first and the address changed in place, as a link or Back/Forward would.
    await p.goto(BASE + "/app"); await p.waitForTimeout(1500);
    for (const path of ["/app/%", "/app/%E0%A4%A", "/app/settings/%zz", "/app/no-such-page"]) {
      await p.evaluate((to) => { history.pushState(null, "", to); dispatchEvent(new PopStateEvent("popstate")); }, path);
      await p.waitForTimeout(700);
      const text = await p.locator("main").innerText().catch(() => "");
      check(`address ${path} shows a page, not a crash`, errors.length === 0 && /Page not found|isn't available|Settings/i.test(text) && !/Something went wrong/.test(text), (errors.join("; ") || text.slice(0, 80)).replace(/\n/g, " | "));
      errors.length = 0;
    }
    await p.goto(BASE + "/%"); await p.waitForTimeout(1200);
    check("address /% (admin area) does not crash", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 2. Role-restricted page, business switching, Back/Forward
  {
    const scenario = { ...owner, workspaces: [ws(B1, "Glow Salon", "staff"), ws(B2, "Glow Downtown", "owner")],
      nav: (id) => id === B1 ? nav("staff", ["calendar", "calls"]) : nav("owner", ["calendar", "calls", "team"]) };
    const { ctx, p, errors } = await session(b, scenario);
    await p.goto(BASE + "/app/access"); await p.waitForTimeout(1500);
    const t1 = await p.locator("main").innerText();
    check("staff opening /app/access (owners/admins only) sees 'not available'", /isn't available/i.test(t1), t1.slice(0, 120).replace(/\n/g, " | "));
    // direct links + refresh + Back/Forward across settings sections
    await p.goto(BASE + "/app/settings/profile/info"); await p.waitForTimeout(1200);
    await p.goto(BASE + "/app/settings/profile/hours"); await p.waitForTimeout(1200);
    await p.goBack(); await p.waitForTimeout(900);
    const backUrl = new URL(p.url()).pathname;
    await p.goForward(); await p.waitForTimeout(900);
    const fwdUrl = new URL(p.url()).pathname;
    await p.reload(); await p.waitForTimeout(1500);
    check("settings pages render (no error panel)", !/Something went wrong/.test(await p.locator("main").innerText()));
    check("settings: direct link, Back, Forward, refresh", backUrl === "/app/settings/profile/info" && fwdUrl === "/app/settings/profile/hours" && new URL(p.url()).pathname === fwdUrl && errors.length === 0, `${backUrl} ${fwdUrl} ${errors.join("; ")}`);
    // in-app navigation then Back
    await p.goto(BASE + "/app"); await p.waitForTimeout(1500);
    await p.locator("nav >> text=Calendar").first().click(); await p.waitForTimeout(700);
    const cal = new URL(p.url()).pathname;
    await p.goBack(); await p.waitForTimeout(700);
    check("in-app link then Back returns to Today", cal === "/app/calendar" && new URL(p.url()).pathname === "/app", `${cal} -> ${new URL(p.url()).pathname}`);
    errors.length = 0;
    await ctx.close();
  }

  // 2a. Business switching changes what the role allows; unsaved changes are guarded
  {
    const scenario = { ...owner, workspaces: [ws(B1, "Glow Salon", "staff"), ws(B2, "Glow Downtown", "owner")],
      nav: (id) => id === B1 ? nav("staff", ["calendar", "calls"]) : nav("owner", ["calendar", "calls"]) };
    const { ctx, p, errors } = await session(b, scenario);
    await p.goto(BASE + "/app/access"); await p.waitForTimeout(1500);
    const staffSees = await p.locator("main").innerText();
    await p.click(".ba-switcher-btn"); await p.click('.ba-menu-item:has-text("Glow Downtown")'); await p.waitForTimeout(1500);
    const ownerSees = await p.locator("main").innerText();
    check("switching business re-checks the role (staff: not available, owner: Team access)", /isn't available/i.test(staffSees) && !/isn't available/i.test(ownerSees) && !/Something went wrong/.test(ownerSees), ownerSees.slice(0, 80).replace(/\n/g, " | "));
    await p.goto(BASE + "/app/settings/profile/info"); await p.waitForTimeout(1500);
    const input = p.locator(".zs-page input").first();
    await input.fill("Changed name");
    let asked = 0; p.on("dialog", (d) => { asked++; d.dismiss(); });
    await p.locator("nav >> text=Calendar").first().click(); await p.waitForTimeout(600);
    const stayed = new URL(p.url()).pathname === "/app/settings/profile/info";
    await p.evaluate(() => history.back()); await p.waitForTimeout(800);
    check("unsaved changes: leaving by link and by Back asks, and staying keeps the page", asked >= 2 && stayed && new URL(p.url()).pathname === "/app/settings/profile/info", `asked ${asked}, at ${new URL(p.url()).pathname}`);
    check("no page errors (switching, guard)", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 2b. A page that throws is contained: menu still works, and moving to another page recovers
  {
    const { ctx, p, errors } = await session(b, { ...owner, crashSettings: true });
    await p.goto(BASE + "/app/settings/profile/info"); await p.waitForTimeout(1500);
    const t = await p.locator("main").innerText();
    const sidebar = await p.locator("nav >> text=Calendar").count();
    check("a crashing page shows the error panel inside the app, menu still there", /Something went wrong on this page/.test(t) && sidebar > 0 && errors.length === 0, t.slice(0, 80).replace(/\n/g, " | "));
    await p.locator("nav >> text=Calendar").first().click(); await p.waitForTimeout(1000);
    check("moving to another page clears the error panel", !/Something went wrong/.test(await p.locator("main").innerText()) && new URL(p.url()).pathname === "/app/calendar");
    await ctx.close();
  }

  // 3. Invitation banner: waiting for an email link -> sends a link; existing workspace still opens
  {
    const scenario = { ...owner, staffInvites: (r) => r.fulfill({ json: { accepted: 0, needs_email_link: 1, expired: 0, errors: [{ reason: "TEAM_LIMIT_REACHED" }] } }) };
    const { ctx, p, errors, calls } = await session(b, scenario);
    await p.goto(BASE + "/app"); await p.waitForTimeout(1800);
    const text = await p.locator("body").innerText();
    check("invitation waiting: banner shown and workspace still open", /team invitation is waiting/i.test(text) && /Glow Salon/.test(text), text.slice(0, 160).replace(/\n/g, " | "));
    check("invitation problem named, no success message", /couldn't be accepted/i.test(text) && !/you've joined|accepted!/i.test(text));
    await p.click('button:has-text("Email me a sign-in link")'); await p.waitForTimeout(800);
    check("Email me a sign-in link calls sign-in by email (stubbed) and confirms", calls.includes("auth:otp") && /We sent a sign-in link/i.test(await p.locator("body").innerText()));
    check("no page errors (invitation waiting)", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 4. Invitation failure -> Try again succeeds; the workspace is usable throughout
  {
    let n = 0;
    const scenario = { ...owner, staffInvites: (r) => (++n === 1 ? r.fulfill({ status: 500, json: { message: "boom", code: "XX000" } }) : r.fulfill({ json: { accepted: 1, needs_email_link: 0, expired: 0, errors: [] } })) };
    const { ctx, p, errors } = await session(b, scenario);
    await p.goto(BASE + "/app"); await p.waitForTimeout(1800);
    const t = await p.locator("body").innerText();
    check("invitation failure: banner with Try again, workspace still open", /couldn't finish adding you/i.test(t) && /Glow Salon/.test(t));
    await p.click('button:has-text("Try again")'); await p.waitForTimeout(1500);
    check("Try again clears the banner after success", !/couldn't finish adding you/i.test(await p.locator("body").innerText()) && n >= 2);
    check("no page errors (failure + retry)", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 5. Database not yet updated (v2 missing) falls back to the previous function without a banner
  {
    const scenario = { ...owner, staffInvites: (r) => r.fulfill({ status: 404, json: { code: "PGRST202", message: "Could not find the function public.zella_accept_staff_invitations_v2" } }) };
    const { ctx, p, errors, calls } = await session(b, scenario);
    await p.goto(BASE + "/app"); await p.waitForTimeout(1800);
    const t = await p.locator("body").innerText();
    check("old database: falls back, no false failure", calls.includes("zella_accept_staff_invitations") && !/couldn't finish adding you/i.test(t) && /Glow Salon/.test(t));
    check("no page errors (fallback)", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  await b.close();
  const failed = results.filter((r) => !r.ok).length;
  console.log(failed ? `${failed} FAILED of ${results.length}` : `ALL ${results.length} PASSED`);
  process.exit(failed ? 1 : 0);
})();
