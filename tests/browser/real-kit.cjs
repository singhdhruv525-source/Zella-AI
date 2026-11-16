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
    const r = await fetch(target.href, { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  return ctx;
}

async function page(ctx) {
  const p = await ctx.newPage(); p.setDefaultTimeout(15000);
  p.errors = []; p.on("pageerror", (e) => p.errors.push(e.message));
  return p;
}

async function signIn(p, email) {
  await p.goto(APP + "/");
  await p.waitForSelector('input[type="email"]');
  await p.fill('input[type="email"]', email);
  if (!(await p.$('input[type="password"]'))) await p.click('button[type="submit"]');
  await p.fill('input[type="password"]', PASSWORD);
  await p.click('button[type="submit"]');
  await p.waitForSelector(".owner-nav-item, .app-nav, nav", { state: "attached" });
}

// The stand in's access token for a person, for calling the function directly.
async function token(email) {
  const r = await fetch(BACKEND + "/auth/v1/token?grant_type=password", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email, password: PASSWORD }) });
  return (await r.json()).access_token;
}
async function fn(tok, body) {
  const r = await fetch(BACKEND + "/functions/v1/owner-provision-business", { method: "POST", headers: { authorization: `Bearer ${tok}`, "content-type": "application/json" }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}

module.exports = { chromium, APP, BACKEND, DB, guard, sql, check, failures, context, page, signIn, token, fn };
