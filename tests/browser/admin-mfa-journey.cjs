// Two step sign in for every admin (ACC-01), in a real browser against the local stand in (local-backend.mjs) over an
// ISOLATED test database with sql/zella_admin_mfa.sql applied. Nothing is sent. The stand in's only working
// authenticator code is 123456.
// Usage: ZDB=<test db> node tests/browser/admin-mfa-journey.cjs     (env APP_URL, BACKEND_URL)
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const { PSQL_ENV, requireIsolated } = require("./isolated-db.cjs");
const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const HOST = process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", PORT = process.env.ZPG_PORT ?? "55433", DB = process.env.ZDB ?? "zella_ui";
requireIsolated(HOST, PORT, DB);
if (!["localhost", "127.0.0.1"].includes(new URL(BACKEND).hostname)) { console.error("BACKEND_URL must be the local stand in"); process.exit(2); }
const sql = (q) => execFileSync("psql", ["-h", HOST, "-p", PORT, "-U", "postgres", "-d", DB, "-AtqX", "-c", q], { env: PSQL_ENV }).toString().trim();
const EMAIL = "admin@zella.test", PASSWORD = "Test-pass-1";
let fails = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); if (!ok) fails++; };
const fn = async (token, action) => {
  const r = await fetch(BACKEND + "/functions/v1/owner-provision-business", { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify({ action }) });
  return { status: r.status, body: await r.json().catch(() => ({})) };
};

(async () => {
  check("the test database has the admin two step rule", sql("select position('public.platform_admins' in pg_get_functiondef('public.zella_mfa_satisfied()'::regprocedure)) > 0") === "t");
  sql(`delete from auth.mfa_factors where user_id = (select id from auth.users where email = '${EMAIL}')`);

  // the server, before any authenticator is set up
  const tok = (await (await fetch(BACKEND + "/auth/v1/token?grant_type=password", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: EMAIL, password: PASSWORD }) })).json()).access_token;
  const me = await fn(tok, "me_admin");
  check("an admin without an authenticator may read their own role, marked as not set up", me.status === 200 && me.body.mfa === false, `${me.status} ${JSON.stringify(me.body).slice(0, 80)}`);
  const dash = await fn(tok, "dashboard_data");
  check("and nothing else (MFA_SETUP_REQUIRED)", dash.status === 403 && dash.body.code === "MFA_SETUP_REQUIRED", `${dash.status} ${dash.body.code ?? dash.body.error}`);
  const rpcAs = (t) => fetch(BACKEND + "/rest/v1/rpc/zella_admin_role", { method: "POST", headers: { authorization: `Bearer ${t}`, apikey: "sb_publishable_local_test_only", "content-type": "application/json" }, body: "{}" });
  const rpc = await rpcAs(tok); const rpcBody = await rpc.json().catch(() => ({}));
  check("the database refuses them too, with its two step sign in refusal (MFA_REQUIRED)", rpc.status === 403 && /MFA_REQUIRED/.test(JSON.stringify(rpcBody)), `${rpc.status} ${JSON.stringify(rpcBody).slice(0, 100)}`);

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 } });
  await ctx.route((url) => ["http:", "https:"].includes(url.protocol), async (route) => {
    const req = route.request(); const url = new URL(req.url());
    if (url.hostname !== "zlocal.supabase.co") { return ["localhost", "127.0.0.1", "fonts.googleapis.com", "fonts.gstatic.com"].includes(url.hostname) ? route.continue() : route.fulfill({ status: 200, body: "" }); }
    const target = new URL(BACKEND); target.pathname = url.pathname; target.search = url.search;
    const r = await fetch(target.href, { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  const page = await ctx.newPage();
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  const signIn = async () => {
    await page.goto(APP + "/");
    await page.waitForSelector('input[type="email"]');
    await page.fill('input[type="email"]', EMAIL);
    if (!(await page.$('input[type="password"]'))) await page.click('button[type="submit"]');
    await page.fill('input[type="password"]', PASSWORD);
    await page.click('button[type="submit"]');
  };

  await signIn();
  await page.waitForSelector("text=Set up two step sign in", { timeout: 15000 }).catch(() => {});
  check("signing in without an authenticator opens the set up screen", await page.isVisible("text=Set up two step sign in"));
  await page.waitForSelector('img[alt^="QR code"]', { timeout: 10000 }).catch(() => {});
  check("with a code to scan and the key to type", await page.isVisible('img[alt^="QR code"]') && await page.isVisible("text=TESTSECRET123456"));
  check("the dashboard isn't shown yet", !(await page.isVisible("nav >> text=Businesses")));
  await page.fill("#mfa-setup-code", "000000");
  await page.click('button[type="submit"]');
  await page.waitForSelector(".login-message.error", { timeout: 10000 }).catch(() => {});
  check("a wrong code is refused with a message", await page.isVisible(".login-message.error"), await page.textContent(".login-message").catch(() => ""));
  await page.fill("#mfa-setup-code", "123456");
  await page.click('button[type="submit"]');
  await page.waitForSelector("nav >> text=Businesses", { timeout: 15000 }).catch(() => {});
  check("the right code turns it on and opens the dashboard", await page.isVisible("nav >> text=Businesses"));
  const saved = sql(`select string_agg(f.status::text, ',' order by f.status) from auth.mfa_factors f join auth.users u on u.id = f.user_id where u.email = '${EMAIL}'`);
  check("the authenticator is saved as verified (and nothing half set up is left)", saved === "verified", saved);
  // control: the same database call works once the session is verified with a code
  const t2 = await page.evaluate(() => { const k = Object.keys(localStorage).find((x) => x.includes("auth-token")); return k ? JSON.parse(localStorage.getItem(k)).access_token : null; });
  const ok2 = t2 ? await rpcAs(t2) : null;
  check("with the verified session the database answers the same call", Boolean(ok2) && ok2.status === 200, ok2 ? String(ok2.status) : "no session token");

  await page.goto(APP + "/settings/profile/security");
  await page.waitForSelector("text=Two step sign in", { timeout: 15000 }).catch(() => {});
  check("Account security says it's required, with no Remove button for the only authenticator", await page.isVisible("text=Required for admins") && !(await page.isVisible("button:has-text('Remove')")),
    (await page.textContent("main").catch(() => "")).replace(/\s+/g, " ").slice(0, 300));

  // a new sign in asks for the code
  await page.evaluate(() => localStorage.clear());
  await ctx.clearCookies();
  await signIn();
  await page.waitForSelector("text=Enter your code", { timeout: 15000 }).catch(() => {});
  check("signing in again asks for the code", await page.isVisible("text=Enter your code"));
  await page.fill("#mfa-code", "123456");
  await page.click('button[type="submit"]');
  await page.waitForSelector("nav >> text=Businesses", { timeout: 15000 }).catch(() => {});
  check("and opens the dashboard after it", await page.isVisible("nav >> text=Businesses"));

  check("no page errors", errors.length === 0, errors.join("; "));
  await browser.close();
  sql(`delete from auth.mfa_factors where user_id = (select id from auth.users where email = '${EMAIL}')`);
  console.log(fails ? `${fails} FAILED` : "ALL PASSED");
  process.exit(fails ? 1 : 0);
})();
