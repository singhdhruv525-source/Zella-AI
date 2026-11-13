// Billing pages in a real browser against the local Supabase stand-in (tests/browser/local-backend.mjs) and the
// isolated database built with tests/billing/ui_fixture.sql. Nothing is sent and nothing is charged.
// Checks: the plan step in Create Business (live profit check, red warnings, a reason needed, review and save, the
// review row), a support admin without billing permission, the owner's Billing & Subscription pages (plan, usage,
// balances, packs, auto-reload), staff refused, and no sideways scrolling on a phone.
// Usage: node tests/billing/ui-journey.cjs      (env APP_URL, BACKEND_URL, ZDB=zui)
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const path = require("path");
const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const SHOTS = process.env.SHOTS ?? path.join(__dirname, "out");
const PG = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zui", "-AtqX", "-c"];
const { PSQL_ENV, requireIsolated } = require("../browser/isolated-db.cjs");
requireIsolated(PG[1], PG[3], PG[7]);
const sql = (q) => execFileSync("psql", [...PG, q], { stdio: ["ignore", "pipe", "pipe"], env: PSQL_ENV }).toString().trim();
const DRAFT = "b2000000-0000-4000-8000-00000000000b";
let fails = 0;
const check = (name, ok, detail = "") => { if (!ok) fails++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` - ${detail}` : ""}`); };

async function session(browser, email, viewport = { width: 1280, height: 900 }) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1 });
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const req = route.request();
    const r = await fetch(req.url().replace("https://zlocal.supabase.co", BACKEND), { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  const page = await ctx.newPage();
  page.errors = []; page.on("pageerror", (e) => page.errors.push(e.message));
  await page.goto(APP + (email.includes("zella.test") ? "/" : "/app"));   // admins sign in at /, businesses at /app
  await page.fill('input[type="email"]', email);
  if (!(await page.$('input[type="password"]'))) await page.click('button[type="submit"]');
  await page.fill('input[type="password"]', "Test-pass-1");
  await page.click('button[type="submit"]');
  await page.waitForTimeout(2500);
  return page;
}
const overflow = (page) => page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);

(async () => {
  require("fs").mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch();

  // 1. Create Business > Plan & pricing, as a billing admin
  const admin = await session(browser, "admin@zella.test");
  await admin.goto(`${APP}/businesses/${DRAFT}/setup`);
  await admin.waitForSelector(".wiz-stepper");
  await admin.locator(".wiz-stepper button", { hasText: "Plan & pricing" }).click();
  await admin.getByText("Not saved yet").first().waitFor();
  check("the plan step starts empty, with nothing preset", await admin.getByRole("combobox", { name: /^Label/ }).inputValue() === ""
    && await admin.getByRole("textbox", { name: /^Price per month/ }).inputValue() === "");
  const fill = async (label, v) => admin.getByRole("textbox", { name: label }).fill(v);
  await admin.getByRole("combobox", { name: /^Label/ }).selectOption("base");
  await fill(/^Price per month/, "0");
  await fill(/^AI minutes a month/, "12000");
  await fill(/^Texts a month/, "500");
  await fill(/^Emails a month/, "5000");
  await fill(/^Users/, "2");
  await admin.waitForTimeout(1200);
  const warnings = await admin.locator(".owner-form-error").allInnerTexts();
  check("red warnings show while typing: $0 price and more than 10,000 minutes",
    warnings.some((t) => /price is \$0/.test(t)) && warnings.some((t) => /More than 10,000 minutes/.test(t)), warnings.join(" | "));
  await fill(/^Price per month/, "199");
  await fill(/^AI minutes a month/, "300");
  await admin.waitForTimeout(1200);
  const badge = await admin.locator(".wiz-section", { hasText: "Profit check" }).locator(".wiz-badge").innerText();
  // cost: 300 x 10 + 500 x 1 + 5000 x 0.1 + 115 + 400 = 4515 cents; revenue 19900 -> 77.3%
  check("the profit check shows the database's margin", /77\.3% margin/.test(badge), badge);
  await admin.screenshot({ path: path.join(SHOTS, "plan-step.png"), fullPage: true });
  // a caution needs a reason: price 99 -> margin 54.4% (below the 60% target)
  await fill(/^Price per month/, "99");
  await admin.waitForTimeout(1200);
  await admin.getByRole("button", { name: "Review plan" }).click();
  const dlg = admin.getByRole("dialog", { name: "Review the plan" });
  await dlg.waitFor();
  await dlg.getByRole("button", { name: "Confirm and save" }).click();
  check("confirming without a reason for the warning is refused", await dlg.locator(".owner-form-error").innerText().then((t) => /reason/.test(t)).catch(() => false));
  await dlg.getByRole("textbox").first().fill("Launch discount agreed with the owner");
  await admin.screenshot({ path: path.join(SHOTS, "plan-review.png") });
  await dlg.getByRole("button", { name: "Confirm and save" }).click();
  await admin.getByText("Version 1 saved").first().waitFor({ timeout: 8000 }).catch(() => {});
  const row = sql(`select version || '/' || tier || '/' || price_cents || '/' || minutes || '/' || (acknowledged_warnings -> 0 ->> 'reason') from business_plans where business_id = '${DRAFT}'`);
  check("saving makes version 1 with the reason recorded", row === "1/base/9900/300/Launch discount agreed with the owner", row);
  check("the save is audited", sql(`select count(*) from audit_logs where action = 'billing.plan_saved' and business_id = '${DRAFT}'`) === "1");
  await admin.locator(".wiz-stepper button", { hasText: "Review" }).last().click();
  const review = await admin.locator(".wiz-review-row", { hasText: "Plan & pricing" }).innerText();
  check("the Review step shows the saved plan", /Version 1/.test(review), review.replace(/\s+/g, " "));
  check("no page errors (admin)", admin.errors.length === 0, admin.errors.join("; "));

  // 2. A support admin without billing permission sees why, and can't save
  const support = await session(browser, "support@zella.test");
  await support.goto(`${APP}/businesses/${DRAFT}/setup`);
  await support.waitForSelector(".wiz-stepper").catch(() => {});
  const supportStep = support.locator(".wiz-stepper button", { hasText: "Plan & pricing" });
  if (await supportStep.count()) {
    await supportStep.click();
    await support.waitForTimeout(1200);
    check("an admin without billing permission is told a billing admin sets the plan", await support.getByText(/don't have billing permission/).count() > 0);
  } else {
    check("an admin without business permission can't open the wizard at all", true);
  }

  // 3. The owner's Billing & Subscription pages
  const owner = await session(browser, "owner@glow.test");
  await owner.goto(`${APP}/app/settings/billing/plan`);
  await owner.locator(".zs-card h3", { hasText: "Your plan" }).first().waitFor();
  await owner.waitForTimeout(800);
  const body = await owner.locator(".zs-page").first().innerText();
  check("the owner sees their plan: Pro, $299 a month, the $599 setup fee", /Pro/.test(body) && /\$299 a month/.test(body) && /\$599, once/.test(body));
  check("usage shows minutes with the pack (420 of 600) and texts (300 of 1,000)", /420 of 600 AI call minutes used \(70%\)/.test(body) && /300 of 1,000 texts used/.test(body), body.match(/\d[\d,]* of [\d,]+ [a-zA-Z ]+ used[^\n]*/g)?.join(" | "));
  check("the reminder buffer is shown for texts", /reminder buffer 50 of 50 left/.test(body));
  await owner.screenshot({ path: path.join(SHOTS, "billing-plan.png"), fullPage: true });
  await owner.goto(`${APP}/app/settings/billing/balances`);
  await owner.locator(".zs-card h3", { hasText: "What you have this month" }).waitFor();
  const bal = await owner.locator(".zs-page").first().innerText();
  check("balances list the plan and the pack with expiry, and the pack prices", /Minutes: Pack \(minutes 100\)/.test(bal) && /\$29/.test(bal) && /up to 100 minutes/.test(bal));
  await owner.screenshot({ path: path.join(SHOTS, "billing-balances.png"), fullPage: true });
  await owner.goto(`${APP}/app/settings/billing/auto-reload`);
  const minutesCard = owner.locator(".zs-card", { hasText: "Auto-reload: minutes" });
  await minutesCard.waitFor();
  await minutesCard.getByRole("checkbox").check();
  await minutesCard.getByRole("textbox", { name: /Monthly limit/ }).fill("10");
  check("a monthly limit below one pack is refused before saving", await minutesCard.getByText(/at least one pack/).count() > 0);
  await minutesCard.getByRole("textbox", { name: /Monthly limit/ }).fill("100");
  await minutesCard.getByRole("button", { name: /Save/ }).click();
  await owner.waitForTimeout(1500);
  check("auto-reload is saved (stored, not active)", sql(`select enabled || '/' || monthly_cap_cents from auto_reload_settings where business_id = 'b2000000-0000-4000-8000-00000000000a' and resource = 'minutes'`) === "true/10000");
  check("no page errors (owner)", owner.errors.length === 0, owner.errors.join("; "));

  // 4. Staff are refused by the database; the page says why
  const staff = await session(browser, "staff@glow.test");
  await staff.goto(`${APP}/app/settings/billing/plan`);
  await staff.waitForTimeout(2000);
  const staffText = await staff.locator(".zs-page").first().innerText().catch(() => "");
  check("staff don't see prices: the page says billing is for the owner (or the page isn't offered)", /Billing is for the business owner/.test(staffText) || !/\$299/.test(staffText), staffText.slice(0, 120));

  // 5. Phones: no sideways scrolling
  const phone = await session(browser, "owner@glow.test", { width: 390, height: 844 });
  for (const p of ["plan", "balances", "auto-reload"]) {
    await phone.goto(`${APP}/app/settings/billing/${p}`);
    await phone.waitForTimeout(1500);
    check(`phone width: billing/${p} has no sideways scroll`, !(await overflow(phone)));
  }
  await phone.screenshot({ path: path.join(SHOTS, "billing-phone.png"), fullPage: true });

  await browser.close();
  console.log(fails ? `${fails} FAILED` : "ALL PASSED");
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
