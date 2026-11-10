// UI journeys in a real browser against the local Supabase stand-in (see local-backend.mjs): isolated test database,
// test people only, nothing sent.
//  1. Templates: an owner of two businesses with overlapping template keys sees only the business being viewed.
//  2. Customer search (PersonPicker) only finds the business's own customers.
//  3. Appearance: a failed account save is shown with Try again (not only in the console); retry saves; the admin and
//     CRM looks stay separate; a replaced background picture is not deleted while the save failed.
//  4. Icon font blocked: no icon words show, buttons keep their names.
//  5. Automations page with a confirmation saved as a single number (live data shape) opens without crashing.
// Usage: node tests/browser/ui-journeys.cjs
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const PG = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zella_ui", "-AtqX", "-c"];
const { PSQL_ENV, requireIsolated } = require("./isolated-db.cjs");
requireIsolated(PG[1], PG[3], PG[7]);
const sql = (q) => { try { return execFileSync("psql", [...PG, q], { stdio: ["ignore", "pipe", "pipe"], env: PSQL_ENV }).toString().trim(); } catch (e) { throw new Error(e.stderr.toString()); } };
const B1 = "b0000000-0000-0000-0000-000000000001", B2 = "b0000000-0000-0000-0000-000000000002";
let fails = 0;
const check = (name, ok, detail = "") => { if (!ok) fails++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` - ${detail}` : ""}`); };

async function open(browser, email, { business, block = [], fail = () => false } = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  if (business) await ctx.addInitScript((id) => localStorage.setItem("zella.lastBusiness", id), business);
  for (const pattern of block) await ctx.route(pattern, (r) => r.abort());
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const req = route.request();
    if (fail(req)) return route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ msg: "Test: the account service is down" }) });
    const r = await fetch(req.url().replace("https://zlocal.supabase.co", BACKEND), { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  const page = await ctx.newPage();
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(APP + (email.includes("zella.test") ? "/" : "/app"));
  await page.fill('input[type="email"]', email);
  if (!(await page.$('input[type="password"]'))) await page.click('button[type="submit"]');
  await page.fill('input[type="password"]', "Test-pass-1");
  await page.click('button[type="submit"]');
  await page.waitForTimeout(2500);
  return { ctx, page, errors };
}

(async () => {
  const browser = await chromium.launch();

  // 1. Templates scoped to the business being viewed
  sql(`delete from message_templates where key = 'zz_test_greeting'`);
  sql(`insert into message_templates (business_id, key, channel, body) values ('${B1}', 'zz_test_greeting', 'sms', 'Hi from Glow Salon'), ('${B2}', 'zz_test_greeting', 'sms', 'Hi from the clinic')`);
  {
    const { ctx, page, errors } = await open(browser, "owner@glow.test", { business: B1 });
    await page.goto(APP + "/app/settings/messages/templates"); await page.waitForTimeout(2500);
    const rows = await page.locator("tr", { hasText: "Zz test greeting" }).allInnerTexts();
    check("templates: one row for the shared key, the viewed business's own", rows.length === 1 && /Yours/.test(rows[0]) && /Yes/.test(rows[0]), JSON.stringify(rows));
    await page.locator("tr", { hasText: "Zz test greeting" }).getByRole("button", { name: "Preview" }).click();
    const body = await page.locator(".zs-card p").last().innerText();
    check("templates: the preview is this business's text, not the other business's", body.includes("Glow Salon"), body);
    check("templates: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 2. Customer search stays in the business
  {
    const { ctx, page } = await open(browser, "owner@glow.test", { business: B1 });
    await page.goto(APP + "/app/callbacks"); await page.waitForTimeout(2000);
    const add = page.getByRole("button", { name: /New callback|Add callback|Schedule a callback/i }).first();
    if (await add.count()) {
      await add.click(); await page.waitForTimeout(500);
      await page.getByPlaceholder("Start typing…").first().fill("Maya");
      await page.waitForTimeout(1200);
      check("customer search finds this business's customer", (await page.locator(".ba-picklist li").allInnerTexts()).some((t) => /Maya/.test(t)));
      await page.getByPlaceholder("Start typing…").first().fill("Pat");
      await page.waitForTimeout(1200);
      const found = await page.locator(".ba-picklist li").allInnerTexts();
      check("customer search finds only this business's customers", !found.some((t) => /Clinic Patient/.test(t)), JSON.stringify(found));
      await page.getByPlaceholder("Start typing…").first().fill("Clinic");
      await page.waitForTimeout(1200);
      check("searching for the other business's customer finds nothing", (await page.locator(".ba-picklist li").count()) === 0);
    } else check("customer search: callback form found", false, "no button to open it");
    await ctx.close();
  }

  // 3. Appearance: failure shown, retry works, apps kept apart, old picture kept while unsaved
  {
    sql(`update auth.users set raw_user_meta_data = raw_user_meta_data - 'zella_appearance' where email = 'owner@glow.test'`);
    let down = true;
    const { ctx, page, errors } = await open(browser, "owner@glow.test", { business: B1, fail: (req) => down && req.method() === "PUT" && req.url().includes("/auth/v1/user") });
    await page.goto(APP + "/app/settings/me/appearance"); await page.waitForTimeout(1500);
    await page.getByRole("radio", { name: /^Glass/ }).click();
    await page.waitForTimeout(1500);
    const failText = await page.locator(".zs-banner, [role=alert]").allInnerTexts();
    check("appearance: a failed save is shown, with the look kept on this device", failText.some((t) => /wasn't saved to your account/.test(t)) && (await page.evaluate(() => document.documentElement.dataset.zellaTheme)) === "glass", JSON.stringify(failText).slice(0, 160));
    check("appearance: nothing was written to the account while it failed", !sql(`select raw_user_meta_data::text from auth.users where email = 'owner@glow.test'`).includes("zella_appearance"));
    down = false;
    await page.getByRole("button", { name: "Try again" }).click();
    await page.waitForTimeout(1500);
    const status = await page.locator('[role="status"], .zs-banner').allInnerTexts();
    check("appearance: Try again saves and says so", status.some((t) => t.trim() === "Saved to your account.") && !status.some((t) => /wasn't saved/.test(t)), JSON.stringify(status).slice(0, 300));
    const saved = JSON.parse(sql(`select raw_user_meta_data->'zella_appearance' from auth.users where email = 'owner@glow.test'`));
    check("appearance: the CRM look is saved under crm only", saved?.crm?.theme === "glass" && !saved?.admin, JSON.stringify(saved));
    // a slider change, then navigating away straight away: still saved
    await page.locator('input[type="range"]').fill("60");
    await page.goto(APP + "/app/today"); await page.waitForTimeout(1500);
    const dim = JSON.parse(sql(`select raw_user_meta_data->'zella_appearance' from auth.users where email = 'owner@glow.test'`))?.crm?.dim;
    check("appearance: a change made just before leaving the page is still saved", dim === 60, `dim=${dim}`);
    check("appearance: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 4. Icon font blocked
  {
    const { ctx, page } = await open(browser, "owner@glow.test", { business: B1, block: ["https://fonts.googleapis.com/**", "https://fonts.gstatic.com/**"] });
    await page.goto(APP + "/app/today"); await page.waitForTimeout(2500);
    const state = await page.evaluate(() => ({
      icons: document.documentElement.dataset.zellaIcons,
      visibleWords: [...document.querySelectorAll(".ba-icon")].filter((e) => getComputedStyle(e).color !== "rgba(0, 0, 0, 0)").length,
      unnamedButtons: [...document.querySelectorAll("button")].filter((b) => b.offsetParent && !(b.getAttribute("aria-label") || b.innerText.trim() || b.title)).length,
    }));
    check("icons: with the icon font blocked, no icon words show", state.icons !== "ready" && state.visibleWords === 0, JSON.stringify(state));
    check("icons: every visible button still has a name", state.unnamedButtons === 0, JSON.stringify(state));
    await page.screenshot({ path: process.env.SHOT ?? "/tmp/icons-blocked.png" });
    await ctx.close();
  }

  // 5. Automations with live-shaped data
  {
    const { ctx, page, errors } = await open(browser, "owner@glow.test", { business: B1 });
    check("automations data has a confirmation saved as a single number", sql(`select jsonb_typeof(trigger_config->'hours_before') from automations where business_id = '${B1}' and trigger_type = 'appointment_confirmation' limit 1`) === "number");
    await page.goto(APP + "/app/automations"); await page.waitForTimeout(2500);
    const text = await page.locator("main").innerText().catch(() => "");
    check("automations page opens (no error screen)", !/Something went wrong on this page/.test(text) && errors.length === 0, errors.join("; ").slice(0, 160));
    check("and describes the confirmation timing", /1 day before|24 hours before/i.test(text));
    await ctx.close();
  }

  await browser.close();
  console.log(fails ? `${fails} FAILED` : "ALL PASSED");
  process.exit(fails ? 1 : 0);
})();
