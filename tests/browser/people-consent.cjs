// Release 1: People & consent in a real browser against the local Supabase stand-in (tests/browser/local-backend.mjs)
// on an ISOLATED database with sql/zella_relationships.sql applied: real sign-in, real row security, real functions.
// Test people only, nothing sent.
//   Setup:  createdb from zella_ui (e.g. zrel_ui), apply sql/zella_relationships.sql, then
//           ZDB=zrel_ui ZFUNCTIONS='{}' node tests/browser/local-backend.mjs &   and build/serve the app as in README.md
//   Run:    ZDB=zrel_ui node tests/browser/people-consent.cjs
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const PG = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zrel_ui", "-AtqX", "-c"];
const sql = (q) => execFileSync("psql", [...PG, q], { stdio: ["ignore", "pipe", "pipe"] }).toString().trim();
const BIZ = "c0000000-0000-0000-0000-000000000003";        // Test Childcare (a sensitive industry)
const GRACE = "c7000000-0000-0000-0000-00000000aa01";
const CHILD_TITLE = "Mia Test Child";
const CHANGE_BUTTONS = /(Link a person|Verify|Edit|Revoke|Record consent|Withdrawn)$/;   // button text ends with its label (an icon may come first)
let fails = 0;
const check = (name, ok, detail = "") => { if (!ok) fails++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` - ${detail}` : ""}`); };

async function open(browser, email, width = 1280) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 } });
  await ctx.addInitScript((id) => localStorage.setItem("zella.lastBusiness", id), BIZ);
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const req = route.request();
    const r = await fetch(req.url().replace("https://zlocal.supabase.co", BACKEND), { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  const page = await ctx.newPage(); page.setDefaultTimeout(10000);
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  page.on("dialog", (d) => d.accept(d.type() === "prompt" ? "Test: no longer collects" : undefined));
  await page.goto(APP + "/app");
  await page.fill('input[type="email"]', email);
  if (!(await page.$('input[type="password"]'))) await page.click('button[type="submit"]');
  await page.fill('input[type="password"]', "Test-pass-1");
  await page.click('button[type="submit"]');
  await page.waitForTimeout(2500);
  return { ctx, page, errors };
}
async function openChild(page) {
  await page.goto(APP + "/app/records/children"); await page.waitForSelector("text=Show");
  await page.locator("select:has(option[value=closed])").selectOption("all");   // the test child isn't in the default "Open" view
  await page.waitForSelector(`text=${CHILD_TITLE}`);
  await page.click(`text=${CHILD_TITLE}`); await page.waitForSelector("[data-people=ready]");
}
const authorized = (perm) => sql(`select public.zella_is_authorized('${BIZ}', null, (select id from crm_records where title = '${CHILD_TITLE}' and business_id = '${BIZ}'), '${GRACE}', '${perm}')`);

(async () => {
  sql(`delete from customer_consents where business_id = '${BIZ}'; delete from customer_relationships where business_id = '${BIZ}'`);
  // one child record with a unique name, so the browser and the database checks look at the same record
  sql(`insert into customers (id, business_id, first_name, last_name, phone) values ('${GRACE}', '${BIZ}', 'Grace', 'Gran', '+15125550401') on conflict (id) do nothing`);
  const CHILD = sql(`update crm_records set title = '${CHILD_TITLE}', archived_at = null where id = (select id from crm_records where business_id = '${BIZ}' and type_key = 'children' and customer_id is not null order by created_at limit 1) returning id`);
  if (!CHILD) throw new Error('no child record to test with');
  const START = sql("select now()");
  const browser = await chromium.launch();

  // owner: link, verify, consent, revoke
  {
    let { ctx, page, errors } = await open(browser, "owner@glow.test");
    await openChild(page);
    check("record window shows People & consent with nobody linked", await page.isVisible("text=Nobody is linked yet."));
    check("owner sees the change buttons (the same check the viewer must fail)", (await page.locator("[data-people] button").filter({ hasText: CHANGE_BUTTONS }).count()) >= 2);
    check("the record's primary contact is named", await page.isVisible("text=Primary contact:"));
    await page.click("text=Link a person");
    const form = page.locator("form[aria-label='Link a person']");
    await form.locator("input").first().fill("Grace");
    await page.click("text=Grace Gran");
    check("suggested relationship for a child is Parent first", (await form.locator("select").first().inputValue()) === "parent");
    await form.locator("select").first().selectOption("guardian");
    await form.getByLabel("Collect / pick up").check();
    await form.getByRole("button", { name: "Link person" }).click();
    await page.waitForSelector("[data-relationship=unverified]");
    check("new link shows 'Not verified: grants nothing yet'", await page.isVisible("text=Not verified: grants nothing yet"));
    check("database: an unverified guardian may not pick up", authorized("pickup") === "f", authorized("pickup"));

    // someone widens the link while the Verify form is open: confirming must verify nothing
    await page.click("[data-relationship=unverified] >> text=Verify");
    sql(`update customer_relationships set permissions = array['approve', 'pickup'] where business_id = '${BIZ}' and related_customer_id = '${GRACE}' and revoked_at is null`);
    await page.locator("form[aria-label^='Verify'] select").selectOption("id_checked");
    await page.locator("form[aria-label^='Verify']").getByRole("button", { name: "Mark verified" }).click();
    await page.waitForSelector("text=changed while you were looking");
    check("a link changed while the Verify form was open is not verified, and the screen says why",
      sql(`select count(*) from customer_relationships where business_id = '${BIZ}' and verified_at is not null`) === "0" && await page.isVisible("[data-relationship=unverified]"));
    sql(`update customer_relationships set permissions = array['pickup'], valid_until = '2027-03-06' where business_id = '${BIZ}' and related_customer_id = '${GRACE}' and revoked_at is null`);
    await page.close(); page = await ctx.newPage(); page.setDefaultTimeout(10000); page.on("pageerror", (e) => errors.push(e.message)); page.on("dialog", (d) => d.accept(d.type() === "prompt" ? "Test: no longer collects" : undefined));
    await openChild(page);
    check("an end date shows on its own day (no time-zone shift)", await page.isVisible("[data-relationship=unverified] >> text=until Sat, Mar 6"));

    await page.click("[data-relationship=unverified] >> text=Verify");
    const vf = page.locator("form[aria-label^='Verify']");
    check("Mark verified is disabled until a method is chosen", await vf.getByRole("button", { name: "Mark verified" }).isDisabled());
    await vf.locator("select").selectOption("id_checked");
    await vf.getByRole("button", { name: "Mark verified" }).click();
    await page.waitForSelector("[data-relationship=active]");
    check("after verifying: 'Verified' with the method", await page.isVisible("[data-relationship=active] >> text=Photo ID checked in person"));
    check("database: the verified guardian may pick up, but not approve", authorized("pickup") === "t" && authorized("approve") === "f");

    await page.click("text=Record consent");
    const cf = page.locator("form[aria-label='Record consent']");
    const givers = await cf.locator("select").nth(2).locator("option").allInnerTexts();
    check("consent can be given by the primary contact, not by a guardian without 'approve'", givers.length === 1 && /primary contact/.test(givers[0]), givers.join(" | "));
    await cf.locator("select").first().selectOption("photo_media");
    await cf.getByPlaceholder("e.g. class photos only").fill("Class photos only");
    await cf.getByRole("button", { name: "Record" }).click();
    await page.waitForSelector("[data-consent=active]");
    check("consent shows as given, with its scope", await page.isVisible("[data-consent=active] >> text=Class photos only"));

    await page.click("[data-relationship=active] >> text=Revoke");
    await page.waitForSelector("text=Revoked (1)");
    check("revoked link moves to the history", await page.isVisible("text=Nobody is linked yet.") && authorized("pickup") === "f");
    const audit = sql(`select string_agg(action, ',' order by created_at) from audit_logs where business_id = '${BIZ}' and entity_type in ('customer_relationship', 'customer_consent') and created_at >= '${START}'`);
    check("every step is in the audit log", audit === "relationship_added,relationship_verified,consent_recorded,relationship_revoked", audit);
    check("owner: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // a fresh verified link, then the person's own profile and the viewer
  sql(`insert into customer_relationships (business_id, record_id, related_customer_id, kind, permissions, verified_at, verification_method)
       select '${BIZ}', id, '${GRACE}', 'authorized_contact', array['pickup'], now(), 'known_to_team' from crm_records where business_id = '${BIZ}' and title = '${CHILD_TITLE}'`);
  {
    const { ctx, page, errors } = await open(browser, "viewer@glow.test");
    await openChild(page);
    check("viewer sees the links", await page.isVisible("[data-relationship=active]"));
    check("viewer has no Link, Verify, Edit, Revoke or Record buttons",
      (await page.locator("[data-people] button").filter({ hasText: CHANGE_BUTTONS }).count()) === 0);
    check("viewer is told why", await page.isVisible("text=You can view this. Changes need a staff member or above."));
    check("viewer: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }
  for (const width of [1280, 390]) {
    const { ctx, page, errors } = await open(browser, "owner@glow.test", width);
    await page.goto(APP + "/app/customers"); await page.waitForTimeout(1500);
    const search = page.getByPlaceholder(/Search/i).first();
    if (await search.isVisible().catch(() => false)) { await search.fill("Grace"); await page.waitForTimeout(800); }
    await page.click("text=Grace Gran");
    await page.click("role=tab[name='People & consent']");
    await page.waitForSelector("[data-people=ready]");
    check(`person profile (${width}px): 'Grace Gran is linked to' the child`, await page.isVisible("text=Grace Gran is linked to") && await page.isVisible(`text=${CHILD_TITLE}`));
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    check(`person profile (${width}px): no sideways scrolling`, overflow <= 1, `${overflow}px`);
    check(`person profile (${width}px): no page errors`, errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  sql(`delete from customer_consents where business_id = '${BIZ}'; delete from customer_relationships where business_id = '${BIZ}'`);
  await browser.close();
  console.log(fails ? `\n${fails} FAILED` : "\nALL PASSED");
  process.exit(fails ? 1 : 0);
})();
