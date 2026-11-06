// Batch 1: admin dashboard permission states and the Security & Abuse controls, in a real browser against a STUBBED
// backend (canned answers; no database, nothing sent). Desktop and phone width.
//   cd web && VITE_SUPABASE_URL=https://example.supabase.co VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_stub npx vite build --outDir /tmp/zella-b1
//   npx vite preview --outDir /tmp/zella-b1 --port 5199 &        then:  node tests/browser/admin-permissions.cjs
const { chromium } = require("playwright");
const BASE = process.env.APP_URL ?? "http://localhost:5199";
const OWNER = { id: "30000000-0000-0000-0000-0000000000a1", email: "admin@zella.test" };
const LIMITED = { id: "30000000-0000-0000-0000-0000000000a2", email: "readonly@zella.test" };
const ALL = ["businesses.view", "businesses.manage", "billing.view", "security.view", "security.manage", "platform.configure", "audit.view", "support.manage", "analytics.view"];
const ME = {
  [OWNER.id]: { role: "zella_owner", roleLabel: "Zella owner", permissions: ALL, mfa: true, aal: "aal2" },
  [LIMITED.id]: { role: "read_only_admin", roleLabel: "Read-only admin", permissions: ["businesses.view", "security.view"], mfa: true, aal: "aal2" },
};
const DASH = { businesses: [], industries: [], stats: { totalBusinesses: 0, activeWorkspaces: 0, pendingInvitations: 0, provisioningIssues: 0 } };
const SPAM = { available: true, totals: {}, policy: { review_score: 40, block_score: 80 }, automation: {}, top_businesses: [], by_channel: [], coverage: [] };

const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const token = (u) => { const exp = Math.floor(Date.now() / 1000) + 3600;
  return { access_token: `${enc({ alg: "HS256" })}.${enc({ sub: u.id, aal: "aal2", exp, role: "authenticated" })}.sig`, refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp,
    user: { id: u.id, email: u.email, aud: "authenticated", role: "authenticated", factors: [] } }; };
const subOf = (req) => { try { return JSON.parse(Buffer.from((req.headers().authorization ?? "").split(".")[1], "base64url").toString()).sub; } catch { return null; } };

let pass = 0, fail = 0;
const check = (ok, name) => { if (ok) { pass++; console.log("PASS " + name); } else { fail++; console.log("FAIL " + name); } };

// meMode(sub, n): "ok" | "fail" | "403" | { delay } for the n-th me_admin call
async function open(b, { user = OWNER, width = 1366, meMode = () => "ok" } = {}) {
  const ctx = await b.newContext({ viewport: { width, height: 900 } });
  await ctx.addInitScript((t) => { if (!sessionStorage.getItem("b1-seeded")) { localStorage.setItem("sb-example-auth-token", JSON.stringify(t)); sessionStorage.setItem("b1-seeded", "1"); } }, token(user));
  const p = await ctx.newPage(); p.setDefaultTimeout(8000);
  const log = { errors: [], actions: [], meCalls: 0 };
  p.on("pageerror", (e) => log.errors.push(e.message.slice(0, 200)));
  await p.route("**/auth/v1/**", (r) => r.fulfill({ json: { currentLevel: "aal2", nextLevel: "aal2" } }));
  await p.route("**/auth/v1/user**", (r) => { const sub = subOf(r.request()); const u = [OWNER, LIMITED].find((x) => x.id === sub) ?? OWNER;
    return r.fulfill({ json: { id: u.id, email: u.email, aud: "authenticated", role: "authenticated", factors: [], user_metadata: {} } }); });
  await p.route("**/rest/v1/**", (r) => {
    const u = decodeURIComponent(r.request().url()); const fn = u.includes("/rpc/") ? u.split("/rpc/")[1].split("?")[0] : null;
    if (fn === "zella_admin_role") return r.fulfill({ json: "zella_owner" });
    if (fn === "is_platform_admin") return r.fulfill({ json: true });
    return r.fulfill({ json: fn ? null : [] });
  });
  await p.route("**/functions/v1/**", async (r) => {
    const body = JSON.parse(r.request().postData() || "{}");
    log.actions.push(body.action);
    if (body.action === "me_admin") {
      const mode = meMode(subOf(r.request()), ++log.meCalls);
      if (mode?.delay) await new Promise((res) => setTimeout(res, mode.delay));
      if (mode === "fail") return r.fulfill({ status: 500, json: { error: "Something went wrong" } });
      if (mode === "403") return r.fulfill({ status: 403, json: { error: "Platform admin access required" } });
      return r.fulfill({ json: ME[subOf(r.request())] ?? ME[OWNER.id] });
    }
    if (body.action === "dashboard_data") return r.fulfill({ json: DASH });
    if (body.action === "spam_admin_overview") return r.fulfill({ json: SPAM });
    if (body.action === "spam_admin_rules") return r.fulfill({ json: { rules: [] } });
    return r.fulfill({ json: {} });
  });
  return { ctx, p, log };
}
const navLabels = (p) => p.$$eval(".owner-nav-item", (els) => els.map((e) => e.innerText.trim().split("\n").pop().trim()));
const text = (p) => p.evaluate(() => document.body.innerText);

(async () => {
  const b = await chromium.launch();
  for (const width of [1366, 390]) {
    const w = width === 390 ? " (phone)" : "";
    const menu = async (p) => { if (width === 390) await p.click(".owner-menu-btn"); };

    // owner: every page; Security & Abuse saves
    { const { ctx, p, log } = await open(b, { width });
      await p.goto(BASE + "/"); await p.waitForSelector(".owner-nav-item", { state: "attached" }); await menu(p);
      const nav = await navLabels(p);
      check(["Overview", "Businesses", "Plans & Subscriptions", "Security & Abuse", "Audit Logs", "Settings"].every((x) => nav.includes(x)), `owner sees every page${w}`);
      await p.goto(BASE + "/security-abuse"); await p.waitForSelector("text=Platform defaults"); await p.click("text=Platform defaults");
      check(await p.isVisible("text=Save defaults"), `owner can save Security & Abuse defaults${w}`);
      check(log.errors.length === 0, `owner: no page errors${w} ${log.errors.join(" | ")}`);
      await ctx.close(); }

    // restricted admin: only permitted pages; direct links denied; read-only controls
    { const { ctx, p, log } = await open(b, { width, user: LIMITED });
      await p.goto(BASE + "/"); await p.waitForSelector(".owner-nav-item", { state: "attached" }); await menu(p);
      const nav = await navLabels(p);
      check(nav.includes("Security & Abuse") && nav.includes("Businesses"), `restricted admin sees permitted pages${w}`);
      check(!["Plans & Subscriptions", "Audit Logs", "Support", "Verification", "Offers & Promotions"].some((x) => nav.includes(x)), `restricted admin doesn't see other pages${w}: ${nav.join(", ")}`);
      for (const url of ["/audit-logs", "/plans", "/support", "/verification", "/businesses/new"]) {
        await p.goto(BASE + url); await p.waitForSelector("[data-access], .owner-page");
        check(await p.isVisible("[data-access=denied]"), `restricted admin: ${url} shows access denied${w}`);
      }
      check(!log.actions.some((a) => ["plans_list", "tickets_list", "audit_list", "verification_queue"].includes(a)), `restricted admin: denied pages loaded no data${w}`);
      await p.goto(BASE + "/security-abuse"); await p.waitForSelector("text=Platform defaults"); await p.click("text=Platform defaults");
      check(!(await p.isVisible("text=Save defaults")) && await p.isVisible("text=Your role can view these but not change them"), `restricted admin: Security & Abuse defaults read-only${w}`);
      await p.click("text=Global block rules"); await p.waitForTimeout(300);
      check(!(await p.isVisible("button:has-text('Add rule')")) && !(await p.isVisible("button:has-text('Add')")), `restricted admin: no block-rule add${w}`);
      check(log.errors.length === 0, `restricted: no page errors${w} ${log.errors.join(" | ")}`);
      await ctx.close(); }

    // slow lookup: nothing protected while loading
    { const { ctx, p, log } = await open(b, { width, meMode: () => ({ delay: 2500 }) });
      await p.goto(BASE + "/security-abuse"); await p.waitForSelector("[data-access=loading]");
      await menu(p);
      check((await p.$$(".owner-nav-item")).length === 0, `loading: no navigation items${w}`);
      check(!(await p.isVisible(".owner-search")) && !(await text(p)).includes("Security & Abuse\nSpam"), `loading: no search box, no protected page${w}`);
      check(!log.actions.some((a) => a !== "me_admin"), `loading: no protected data requested${w} (${log.actions.join(",")})`);
      await p.waitForSelector(".owner-nav-item", { state: "attached" });
      check(await p.isVisible("text=Platform defaults"), `loading then authorized: page appears${w}`);
      await ctx.close(); }

    // failed lookup: error and Retry; nothing protected; retry recovers
    { const { ctx, p, log } = await open(b, { width, meMode: (_s, n) => (n === 1 ? "fail" : "ok") });
      await p.goto(BASE + "/businesses"); await p.waitForSelector("[data-access=failed]");
      await menu(p);
      check((await p.$$(".owner-nav-item")).length === 0, `failed: no navigation items${w}`);
      check(!(await p.isVisible("text=Create business")) && !(await p.isVisible(".owner-search")), `failed: no protected actions${w}`);
      check(!log.actions.includes("dashboard_data"), `failed: no protected data requested${w}`);
      if (width === 390) await p.keyboard.press("Escape");
      await p.click("button:has-text('Retry')"); await p.waitForSelector(".owner-nav-item", { state: "attached" });
      check(await p.isVisible("text=Create business"), `retry after a temporary failure loads the permissions${w}`);
      await ctx.close(); }

    // refused lookup: no admin access
    { const { ctx, p } = await open(b, { width, meMode: () => "403" });
      await p.goto(BASE + "/"); await p.waitForSelector("[data-access=unauthorized]");
      check((await p.$$(".owner-nav-item")).length === 0 && await p.isVisible("[data-access=unauthorized] button:has-text('Sign out')"), `403: no admin access, only sign out${w}`);
      await ctx.close(); }
  }

  // account switch in another tab: the new account's permissions replace the old ones
  { const { ctx, p } = await open(b);
    await p.goto(BASE + "/"); await p.waitForSelector(".owner-nav-item", { state: "attached" });
    check((await navLabels(p)).includes("Audit Logs"), "switch: owner's pages before the switch");
    const other = await ctx.newPage();
    await other.goto(BASE + "/status").catch(() => {});
    // what the sign-in library in another tab sends when a different account signs in there
    await other.evaluate((t) => { localStorage.setItem("sb-example-auth-token", JSON.stringify(t));
      new BroadcastChannel("sb-example-auth-token").postMessage({ event: "SIGNED_IN", session: t }); }, token(LIMITED));
    // the old account's menu goes away, then (after the new account's permissions load) the new account's appears
    await p.waitForFunction(() => { const items = [...document.querySelectorAll(".owner-nav-item")].map((e) => e.innerText);
      return items.some((t) => t.includes("Security & Abuse")) && !items.some((t) => t.includes("Audit Logs")); }, null, { timeout: 8000 }).catch(() => {});
    const nav = await navLabels(p);
    check(!nav.includes("Audit Logs") && nav.includes("Security & Abuse"), `switch: restricted account's pages after the switch (${nav.join(", ")})`);
    await ctx.close(); }

  // sign-out: the dashboard and its permissions are gone
  { const { ctx, p } = await open(b);
    await p.goto(BASE + "/"); await p.waitForSelector(".owner-nav-item", { state: "attached" });
    await p.click(".owner-signout"); await p.waitForTimeout(600);
    check((await p.$$(".owner-nav-item")).length === 0, "sign-out: no admin navigation remains");
    await ctx.close(); }

  await b.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
