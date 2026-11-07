// Release 3: approvals, checklists, problems, dates and credits on records, the Follow-through page and the record-type
// workflow setting, in a real browser against the local Supabase stand-in (tests/browser/local-backend.mjs) on an
// ISOLATED database with sql/zella_record_workflows.sql applied: real sign-in, row security and functions. Test people
// only, nothing sent.
//   Setup:  the zrel_ui copy used by people-consent.cjs and scheduling.cjs, plus sql/zella_record_workflows.sql
//   Run:    ZDB=zrel_ui node tests/browser/workflows.cjs
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const PG = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zrel_ui", "-AtqX", "-c"];
// libpq settings that could send psql somewhere other than the socket named with -h are left out of its environment
const PSQL_ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !["PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE", "PGHOST", "PGPORT", "PGDATABASE"].includes(k)));
const sql = (q) => execFileSync("psql", [...PG, q], { stdio: ["ignore", "pipe", "pipe"], env: PSQL_ENV }).toString().trim();
// Refuse anything but the isolated local test server (same rule as tests/lib/isolated_guard.sh): a Unix socket, a test
// database name, and a server whose data directory is exactly the throwaway cluster's (fixed; no setting widens it).
// Runs before any other SQL.
function requireIsolated() {
  const [host, port, db] = [PG[1], PG[3], PG[7]], WANT = "/var/lib/postgresql/zella-sec/data";
  if (!host.startsWith("/")) throw new Error(`REFUSED: ${host} is not a local socket directory`);
  if (!/^z[a-z0-9_]{1,40}$/.test(db)) throw new Error(`REFUSED: '${db}' is not a test database name (z..., lower case)`);
  let data = "";
  try { data = execFileSync("psql", ["-h", host, "-p", port, "-U", "postgres", "-d", "postgres", "-AtqX", "-c", "select case when inet_server_addr() is null then current_setting('data_directory') end"], { stdio: ["ignore", "pipe", "pipe"], env: PSQL_ENV }).toString().trim(); }
  catch { throw new Error(`REFUSED: could not confirm the server at ${host}:${port} is the isolated test server`); }
  if (!data) throw new Error(`REFUSED: the connection to ${host}:${port} is not over a Unix socket`);
  if (data !== WANT) throw new Error(`REFUSED: the server keeps its data in '${data}', not in the isolated test cluster (${WANT})`);
}

const BIZ = "c0000000-0000-0000-0000-000000000014";        // Test HVAC, America/Chicago
const PAT = "c9000000-0000-0000-0000-0000000001a1";
const JOB = "R3 Furnace repair", PLAN = "R3 Care plan";
let fails = 0;
const check = (name, ok, detail = "") => { if (!ok) fails++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` - ${detail}` : ""}`); };
const tz = "America/Chicago";
const ymd = (offset) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(Date.now() + offset * 86400000));
const CHANGE = /^(Ask for approval|Record the answer|Withdraw|Add a date|Done|Change|Start service checklist|Continue|Flag a problem|Resolved|Use|Give back|Add visits|Expire)$/;

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

async function openRecord(page, typeKey, title) {
  await page.goto(`${APP}/app/records/${typeKey}`); await page.waitForSelector("text=Show");
  const all = page.locator("select:has(option[value=closed])");
  if (await all.count()) await all.selectOption("all");
  await page.locator(`text=${title}`).first().click();
  await page.waitForSelector("[data-workflow=ready]");
}
const modal = (page) => page.locator(".ba-modal, [role=dialog]").last();

(async () => {
  requireIsolated();
  // a clean slate for this business's Release 3 data; one job and one care plan with unique names, linked to Pat
  sql(`delete from record_credits where business_id = '${BIZ}'; delete from record_exceptions where business_id = '${BIZ}'; delete from record_inspections where business_id = '${BIZ}';
       delete from record_milestones where business_id = '${BIZ}'; delete from record_approvals where business_id = '${BIZ}';
       update crm_record_types t set workflow = p.config from record_workflow_presets p where t.business_id = '${BIZ}' and p.preset_key = t.preset_key and p.type_key = t.key`);
  sql(`insert into customers (id, business_id, first_name, last_name, phone) values ('${PAT}', '${BIZ}', 'Pat', 'Homeowner', '+15125550801') on conflict (id) do nothing`);
  const jobId = sql(`update crm_records set title = '${JOB}', status = 'assessed', customer_id = '${PAT}', archived_at = null where id = (select id from crm_records where business_id = '${BIZ}' and type_key = 'jobs' order by created_at limit 1) returning id`);
  const planId = sql(`update crm_records set title = '${PLAN}', status = 'active', customer_id = '${PAT}', archived_at = null where id = (select id from crm_records where business_id = '${BIZ}' and type_key = 'agreements' order by created_at limit 1) returning id`);
  if (!jobId || !planId) throw new Error("no job or agreement record to test with");
  const browser = await chromium.launch();

  // owner: the whole flow
  {
    const { ctx, page, errors } = await open(browser, "owner@glow.test");
    await openRecord(page, "jobs", JOB);
    for (const s of ["Approvals", "Milestones and deadlines", "Inspections", "Exceptions"]) check(`a job shows ${s}`, await page.locator(`section[aria-label="${s}"]`).isVisible());
    check("a job doesn't count credits", (await page.locator('section[aria-label="Credits"]').count()) === 0);

    // ask for approval of an estimate, with an amount; the customer approves by phone
    await page.getByRole("button", { name: "Ask for approval" }).click();
    await modal(page).locator("label:has(> span:text-is('Title')) input").fill("Replace igniter");
    await modal(page).locator("label:has(> span:text-matches('^Amount')) input").fill("180.00");
    await modal(page).getByRole("button", { name: "Save" }).click();
    // asking for an estimate's approval can move the job's status, so the record panel closes and the list reloads
    await page.waitForSelector("[data-workflow=ready]", { state: "detached" });
    check("asking for the estimate's approval moves the job to its \"estimate\" step when it has one (HVAC jobs don't: unchanged)", sql(`select status from crm_records where id = '${jobId}'`) === "assessed");
    await openRecord(page, "jobs", JOB);
    await page.locator("[data-approval='Replace igniter']").waitFor();
    check("the approval request shows as waiting, with its amount", /Waiting/.test(await page.locator("[data-approval='Replace igniter']").innerText()) && /180\.00/.test(await page.locator("[data-approval='Replace igniter']").innerText()));
    check("stored in minor units", sql(`select amount_minor || ' ' || currency from record_approvals where record_id = '${jobId}' and title = 'Replace igniter'`).startsWith("18000 "));
    // a second request stays waiting for the follow-through page
    await page.getByRole("button", { name: "Ask for approval" }).click();
    await modal(page).locator("label:has(> span:text-is('What for')) select").selectOption("additional_work");
    await modal(page).locator("label:has(> span:text-is('Title')) input").fill("Duct cleaning");
    await modal(page).getByRole("button", { name: "Save" }).click();
    await page.locator("[data-approval='Duct cleaning']").waitFor();
    await page.locator("[data-approval='Replace igniter']").getByRole("button", { name: "Record the answer" }).click();
    const who = modal(page).locator("label:has(> span:text-is('Who answered')) select");
    await who.locator("option", { hasText: "Pat" }).first().waitFor({ state: "attached" });
    await who.selectOption({ label: (await who.locator("option", { hasText: "Pat" }).first().innerText()).trim() });
    await modal(page).getByRole("button", { name: "Save the answer" }).click();
    await page.waitForSelector("[data-workflow=ready]", { state: "detached" });   // the record panel closes and the list reloads
    check("approved: who, how and when are stored", sql(`select status || ' ' || method || ' ' || (approver_customer_id = '${PAT}') from record_approvals where record_id = '${jobId}' and title = 'Replace igniter'`) === "approved phone true");
    await openRecord(page, "jobs", JOB);
    check("reopened, the approval reads Approved", /Approved/.test(await page.locator("[data-approval='Replace igniter']").innerText()));
    check("the record's history names it", await page.locator("text=Approved: Replace igniter").first().isVisible());

    // the service checklist: finishing needs every item; one fails, which flags a problem
    await page.getByRole("button", { name: "Start service checklist" }).click();
    check("Finish waits until every item is answered", await modal(page).getByRole("button", { name: "Finish" }).isDisabled());
    for (const label of ["Filters", "Refrigerant level", "Electrical connections", "Thermostat", "Condensate drain"]) await modal(page).locator(`[data-item="${label}"] label:has-text("Pass") input`).check();
    await modal(page).locator('[data-item="Airflow"] label:has-text("Fail") input').check();
    await modal(page).locator('[data-item="Airflow"] input[aria-label="Airflow note"]').fill("Weak at the back bedroom");
    await modal(page).getByRole("button", { name: "Finish" }).click();
    await page.locator("[data-inspection=failed]").waitFor();
    check("a failed item fails the checklist and flags a problem naming it", await page.locator("[data-exception=inspection_failed]").isVisible()
      && /Airflow/.test(await page.locator("[data-exception=inspection_failed]").innerText()));

    // flag a problem by hand, then resolve it
    await page.getByRole("button", { name: "Flag a problem" }).click();
    await modal(page).locator("label:has(> span:text-is('Details (optional)')) input").fill("Igniter on back order");
    await modal(page).locator("label:has(> span:text-matches('^Expected')) input").fill(ymd(5));
    await modal(page).getByRole("button", { name: "Flag it" }).click();
    await page.locator("[data-exception=waiting_parts]").waitFor();
    await page.locator("[data-exception=waiting_parts]").getByRole("button", { name: "Resolved" }).click();
    await modal(page).locator("label:has(> span:text-matches('^How it was sorted')) input").fill("Arrived");
    await modal(page).getByRole("button", { name: "Mark resolved" }).click();
    await page.locator("[data-exception=waiting_parts]").waitFor({ state: "detached" });
    check("a problem is flagged with an expected date, then resolved", sql(`select count(*) from record_exceptions where record_id = '${jobId}' and kind = 'waiting_parts' and resolved_at is not null and resolution = 'Arrived'`) === "1");

    // a renewal, done and rolled forward a year
    await page.getByRole("button", { name: "Add a date" }).click();
    await modal(page).locator("label:has(> span:text-is('What')) input").fill("Warranty renewal");
    await modal(page).locator("label:has(> span:text-is('Kind')) select").selectOption("renewal");
    await modal(page).locator("label:has(> span:text-is('Due')) input").fill(ymd(3));
    await modal(page).getByRole("button", { name: "Save" }).click();
    await page.locator("[data-milestone='Warranty renewal']").waitFor();
    check("a date shows how far off it is", /Due in 3 days/.test(await page.locator("[data-milestone='Warranty renewal']").innerText()));
    await page.locator("[data-milestone='Warranty renewal']").getByRole("button", { name: "Done" }).click();
    await modal(page).getByRole("button", { name: "Mark done" }).click();
    await page.waitForTimeout(800);
    check("done, and the next one is added a year on", sql(`select count(*) filter (where done_at is not null) || '/' || count(*) filter (where done_at is null and next_of is not null and due_on > current_date + 300) from record_milestones where record_id = '${jobId}'`) === "1/1");

    // the care plan counts visits
    await openRecord(page, "agreements", PLAN);
    check("a care plan counts visits", await page.locator("[data-balance='0']").isVisible());
    await page.getByRole("button", { name: "Add visits" }).click();
    await modal(page).locator("label:has(> span:text-is('How many')) input").fill("2");
    await modal(page).getByRole("button", { name: "Save" }).click();
    await page.locator("[data-balance='2']").waitFor();
    await page.getByRole("button", { name: "Use", exact: true }).click();
    await modal(page).getByRole("button", { name: "Save" }).click();
    await page.waitForSelector("[data-workflow=ready]", { state: "detached" });
    check("using one leaves one", sql(`select coalesce(sum(case when kind in ('grant','refund') then units else -units end), 0) from record_credits where record_id = '${planId}'`) === "1");

    // follow-through
    await page.goto(APP + "/app/follow"); await page.waitForSelector("[data-follow=ready] .ba-follow-grid");
    const follow = await page.locator("[data-follow=ready]").innerText();
    check("follow-through lists the approval still waiting", /Duct cleaning/.test(follow) && /Waiting for approval \(1\)/.test(follow), follow.slice(0, 300));
    check("and the problem still holding the job up", /Inspection failed/.test(follow) && new RegExp(JOB).test(follow));

    // the record type's workflow setting: the owner turns off "additional work" approvals for jobs
    await page.goto(APP + "/app/record-settings"); await page.waitForTimeout(1500);
    await page.locator("tr", { hasText: "Jobs" }).first().getByRole("button", { name: "Edit" }).click();
    await page.locator("[data-workflow-settings=jobs]").waitFor();
    await page.locator("[data-workflow-settings=jobs] label:has-text('Additional work') input").uncheck();
    await page.locator("[data-workflow-settings=jobs]").getByRole("button", { name: "Save workflow" }).click();
    await page.waitForTimeout(1200);
    check("the setting is saved as the business's own", sql(`select (workflow -> 'approvals')::text || ' ' || (workflow ->> 'custom') from crm_record_types where business_id = '${BIZ}' and key = 'jobs'`) === '["estimate"] true');
    check("owner: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // viewer: reads dates, checklists and problems; sees no amounts and no buttons
  {
    const { ctx, page, errors } = await open(browser, "viewer@glow.test");
    await openRecord(page, "jobs", JOB);
    check("viewer sees no approvals (amounts)", (await page.locator('section[aria-label="Approvals"]').count()) === 0);
    check("viewer reads the problems and checklists", await page.locator("[data-exception=inspection_failed]").isVisible() && await page.locator("[data-inspection=failed]").isVisible());
    const buttons = await page.locator("[data-workflow=ready] button").allInnerTexts();
    check("viewer has no workflow buttons", !buttons.some((b) => CHANGE.test(b.trim())), buttons.join(", "));
    await page.goto(APP + "/app/follow"); await page.waitForSelector("[data-follow=ready] .ba-follow-grid");
    check("follow-through for a viewer: no approvals, told it's read-only", !(await page.locator("text=Waiting for approval").count()) && await page.locator("text=You can see this list but not change it").isVisible());
    check("viewer: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // phone width
  {
    const { ctx, page, errors } = await open(browser, "owner@glow.test", 390);
    await page.goto(APP + "/app/follow"); await page.waitForSelector("[data-follow=ready] .ba-follow-grid");
    const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    check("follow-through at 390px: no sideways scrolling", over <= 1, `${over}px`);
    await openRecord(page, "jobs", JOB);
    const over2 = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    check("a job's workflow at 390px: no sideways scrolling", over2 <= 1, `${over2}px`);
    check("phone: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }
  await browser.close();
  console.log(fails ? `\n${fails} FAILED` : "\nALL PASSED");
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
