// Shared set up for journeys against the local stand in (local-backend.mjs) over an ISOLATED test database: the
// database guard, psql, the reroute of zlocal.supabase.co to the stand in, sign in, page error capture and
// screenshots. Nothing is sent.
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const { PSQL_ENV, requireIsolated } = require("./isolated-db.cjs");

const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const HOST = process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", PORT = process.env.ZPG_PORT ?? "55433", DB = process.env.ZDB ?? "zella_ui";
const PASSWORD = "Test-pass-1";

function guard() {
  requireIsolated(HOST, PORT, DB);
  if (!["localhost", "127.0.0.1"].includes(new URL(BACKEND).hostname)) throw new Error("BACKEND_URL must be the local stand in");
}
const sql = (q) => execFileSync("psql", ["-h", HOST, "-p", PORT, "-U", "postgres", "-d", DB, "-AtqX", "-v", "ON_ERROR_STOP=1", "-c", q], { env: PSQL_ENV }).toString().trim();

let fails = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); if (!ok) fails++; };
const failures = () => fails;

// A browser context whose Supabase calls go to the stand in. deviceScaleFactor 1, as the brief's screenshots need.
async function context(browser, width, height = 900) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1 });
  await ctx.route((url) => ["http:", "https:"].includes(url.protocol), async (route) => {
    const req = route.request(); const url = new URL(req.url());
    if (url.hostname !== "zlocal.supabase.co") return ["localhost", "127.0.0.1", "fonts.googleapis.com", "fonts.gstatic.com"].includes(url.hostname) ? route.continue() : route.fulfill({ status: 200, body: "" });
    const target = new URL(BACKEND); target.pathname = url.pathname; target.search = url.search;
    // redirect: "error": the stand in never redirects, so a redirect is refused rather than followed elsewhere
    const r = await fetch(target.href, { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer(), redirect: "error" });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  return ctx;
}

async function page(ctx) {
  const p = await ctx.newPage(); p.setDefaultTimeout(15000);
  p.errors = []; p.on("pageerror", (e) => p.errors.push(e.message));
  return p;
}

// Admins sign in at /, business members at /app.
async function signIn(p, email, root = /@zella\.test$|@lanea\.test$/.test(email) ? "/" : "/app") {
  await p.goto(APP + root);
  await p.waitForSelector('input[type="email"]');
  await p.fill('input[type="email"]', email);
  if (!(await p.$('input[type="password"]'))) await p.click('button[type="submit"]');
  await p.fill('input[type="password"]', PASSWORD);
  await p.click('button[type="submit"]');
  // the admin dashboard has its sidebar; the business app leaves the sign in page
  await p.waitForSelector('input[type="password"]', { state: "detached" });
  await p.waitForLoadState("networkidle").catch(() => {});
}

// The stand in's session for a person (access and refresh token), for calling the function directly. A failed sign in
// stops the journey: it never carries on as if anonymous.
async function signInApi(email) {
  const r = await fetch(BACKEND + "/auth/v1/token?grant_type=password", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email, password: PASSWORD }), redirect: "error" });
  const s = await r.json().catch(() => ({}));
  if (!r.ok || typeof s.access_token !== "string" || !s.access_token) throw new Error(`test sign in failed for ${email} (${r.status})`);
  return s;
}
async function token(email) { return (await signInApi(email)).access_token; }
// A token with a code entered just now (the stand in's /factors/<id>/verify with 123456), for fresh code actions.
async function freshToken(email) {
  const tok = await token(email);
  const id = sql(`select f.id from auth.mfa_factors f join auth.users u on u.id = f.user_id where u.email = '${email}' and f.status = 'verified' limit 1`);
  const r = await fetch(`${BACKEND}/auth/v1/factors/${id}/verify`, { method: "POST", headers: { authorization: `Bearer ${tok}`, "content-type": "application/json" }, body: JSON.stringify({ code: "123456", challenge_id: "c" }), redirect: "error" });
  const s = await r.json().catch(() => ({}));
  if (!r.ok || typeof s.access_token !== "string" || !s.access_token) throw new Error(`test code check failed for ${email} (${r.status})`);
  return s.access_token;
}
// A refresh with the stand in, as the app does: { status, body }.
async function refresh(refreshToken) {
  const r = await fetch(BACKEND + "/auth/v1/token?grant_type=refresh_token", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ refresh_token: refreshToken }), redirect: "error" });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}
// The session id in the page's own access token (the app keeps the session in localStorage).
async function pageSessionId(p) {
  return p.evaluate(() => {
    const key = Object.keys(localStorage).find((k) => /^sb-.*-auth-token$/.test(k));
    const t = key && JSON.parse(localStorage.getItem(key))?.access_token;
    return t ? JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).session_id ?? null : null;
  });
}
// fn(null, ...) is an explicit anonymous call; any other token must be a real one
async function fn(tok, body, extra = {}) {
  if (tok !== null && (typeof tok !== "string" || !tok)) throw new Error("fn: no token (a failed test sign in?)");
  const headers = { "content-type": "application/json", ...(tok ? { authorization: `Bearer ${tok}` } : {}), ...extra };
  const r = await fetch(BACKEND + "/functions/v1/owner-provision-business", { method: "POST", headers, body: JSON.stringify(body), redirect: "error" });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}

// ACC-19: when Users & access asks for a new authenticator code, enter the stand in's working code (123456).
// Returns true when it was asked.
async function freshCode(p, code = "123456") {
  const form = p.locator('form[aria-label="Confirm with your authenticator"]');
  if (!(await form.waitFor({ timeout: 4000 }).then(() => true).catch(() => false))) return false;
  await form.getByLabel("Authenticator code", { exact: true }).fill(code);
  await form.locator('button[type="submit"]').click();
  return true;
}

module.exports = { freshCode, freshToken, chromium, APP, BACKEND, DB, guard, sql, check, failures, context, page, signIn, signInApi, token, refresh, pageSessionId, fn };
