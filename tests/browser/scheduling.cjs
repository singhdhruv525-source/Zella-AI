// Release 2: Dispatch, Resources and Recurring visits in a real browser against the local Supabase stand-in
// (tests/browser/local-backend.mjs) on an ISOLATED database with sql/zella_scheduling.sql applied: real sign-in, row
// security, functions and booking guards. Test people only, nothing sent.
//   Setup:  the zrel_ui copy used by people-consent.cjs, plus sql/zella_scheduling.sql; the stand-in and app as there
//   Run:    ZDB=zrel_ui node tests/browser/scheduling.cjs
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

const BIZ = "c0000000-0000-0000-0000-000000000014";        // Test HVAC (dispatch on), America/Chicago
const ANA = "c9000000-0000-0000-0000-0000000005a1", BEN = "c9000000-0000-0000-0000-0000000005a2", PAT = "c9000000-0000-0000-0000-0000000001a1";
let fails = 0;
const check = (name, ok, detail = "") => { if (!ok) fails++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` - ${detail}` : ""}`); };
const tz = "America/Chicago";
const ymd = (offset) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(Date.now() + offset * 86400000));
const CHANGE = /^(Assign|Reassign|On the way|Arrived|Complete|Pause|Resume|Checklist|Needs a return visit|Book the return visit)$/;

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

(async () => {
  requireIsolated();
  // a clean slate for this business's Release 2 data, then two technicians and a customer (synthetic)
  sql(`delete from job_dispatch where business_id = '${BIZ}'; delete from recurring_visits where business_id = '${BIZ}'; delete from recurring_plans where business_id = '${BIZ}';
       delete from resource_needs where business_id = '${BIZ}'; delete from followup_tasks where business_id = '${BIZ}' and appointment_id in (select id from appointments where business_id = '${BIZ}' and title like 'R2 %');
       delete from appointments where business_id = '${BIZ}' and title like 'R2 %'; delete from blocked_times where business_id = '${BIZ}' and resource_id is not null; delete from resources where business_id = '${BIZ}';
       insert into staff_members (id, business_id, name, is_active) values ('${ANA}', '${BIZ}', 'Ana Tech', true), ('${BEN}', '${BIZ}', 'Ben Tech', true) on conflict (id) do update set is_active = true;
       insert into customers (id, business_id, first_name, last_name, phone) values ('${PAT}', '${BIZ}', 'Pat', 'Homeowner', '+15125550901') on conflict (id) do nothing`);
  const tomorrow = ymd(1);
  const browser = await chromium.launch();

  // owner: resources, a booking that uses one, the same resource refused, dispatch steps, a recurring plan
  {
    const { ctx, page, errors } = await open(browser, "owner@glow.test");
    check("the sidebar offers Dispatch, Resources and Recurring visits", await page.isVisible("nav >> text=Dispatch") && await page.isVisible("nav >> text=Resources") && await page.isVisible("nav >> text=Recurring visits"));
    await page.goto(APP + "/app/resources"); await page.waitForSelector("text=No resources yet");
    for (const name of ["Bay 1", "Bay 2"]) {
      await page.click("text=Add a resource");
      const f = page.locator("form#ba-resource");
      await f.getByLabel("Name").fill(name);
      await f.getByLabel("Kind").selectOption("bay");
      await page.getByRole("button", { name: "Save" }).click();
      await page.waitForSelector(`[data-resources] >> text=${name}`);
    }
    check("a manager adds resources", sql(`select count(*) from resources where business_id = '${BIZ}'`) === "2");

    const book = async (title) => {
      await page.click("button[title^='New ']");
      const f = page.locator("form#ba-book");
      await f.getByLabel("Title").fill(title);
      await f.getByLabel("Date").fill(tomorrow);
      await f.getByLabel("Start time").fill("10:00");
      await f.locator("select").filter({ has: page.locator("option[value='60']") }).selectOption("60");
      await f.getByLabel("Bay 1").check();
      await page.getByRole("button", { name: "Book", exact: true }).click();
    };
    await book("R2 Tune-up");
    await page.waitForSelector("form#ba-book", { state: "detached" });
    check("a booking can use a resource", sql(`select resource_ids::text from appointments where business_id = '${BIZ}' and title = 'R2 Tune-up'`) === `{${sql(`select id from resources where business_id = '${BIZ}' and name = 'Bay 1'`)}}`);
    await book("R2 Second tune-up");
    await page.waitForSelector("form#ba-book >> text=Bay 1 is booked, full or blocked then");
    check("the same bay at the same time is refused, named, with no 'Book it anyway'",
      (await page.locator("form#ba-book >> text=Book it anyway").count()) === 0 && sql(`select count(*) from appointments where business_id = '${BIZ}' and title = 'R2 Second tune-up'`) === "0");
    await page.getByRole("button", { name: "Cancel" }).click();

    // dispatch: assign, steps, checklist, complete
    await page.goto(APP + "/app/dispatch"); await page.waitForSelector("[data-dispatch=ready]");
    await page.getByRole("button", { name: "Next day" }).click();
    const unassigned = page.locator("section[aria-label='Unassigned jobs']");
    await unassigned.locator("li", { hasText: "R2 Tune-up" }).waitFor();
    check("the job shows as unassigned with its arrival time", /Unassigned/.test(await unassigned.locator("li", { hasText: "R2 Tune-up" }).innerText()));
    await unassigned.locator("li", { hasText: "R2 Tune-up" }).getByRole("button", { name: "Assign" }).click();
    await page.locator("form#ba-assign").getByLabel("Lead technician").selectOption(ANA);
    await page.locator("form#ba-assign").getByRole("checkbox", { name: "Ben Tech" }).check();
    await page.getByRole("button", { name: "Assign", exact: true }).last().click();
    const anaCol = page.locator("section[aria-label='Ana Tech']");
    await anaCol.locator("li", { hasText: "R2 Tune-up" }).waitFor();
    check("assigned to Ana with Ben on the crew, shown in both columns",
      await page.locator("section[aria-label='Ben Tech'] li", { hasText: "R2 Tune-up" }).isVisible()
      && sql(`select staff_id || ' ' || crew_staff_ids::text from appointments where business_id = '${BIZ}' and title = 'R2 Tune-up'`) === `${ANA} {${BEN}}`);
    const job = () => anaCol.locator("li", { hasText: "R2 Tune-up" });
    await job().getByRole("button", { name: "On the way" }).click(); await job().locator(".ba-pill, [class*=pill]", { hasText: "On the way" }).waitFor();
    await job().getByRole("button", { name: "Arrived" }).click();
    try { await job().locator(".ba-pill, [class*=pill]", { hasText: "On site" }).waitFor(); }
    catch (e) { console.log("DEBUG", await page.locator("[role=alert]").allInnerTexts(), await job().innerText()); throw e; }
    await job().getByRole("button", { name: "Checklist" }).click();
    await page.getByLabel("Add an item").fill("Photos of the unit");
    await page.getByRole("button", { name: "Add", exact: true }).click();
    await page.locator(".ba-check-list li").getByLabel("Required").check();
    await page.getByRole("button", { name: "Save checklist" }).click();
    await job().locator("text=1 required left").waitFor();
    await job().getByRole("button", { name: "Complete" }).click();
    await page.waitForSelector("text=Tick the required checklist items before completing the job.");
    check("completing with a required item open is refused, in plain words", sql(`select status from job_dispatch where appointment_id = (select id from appointments where business_id = '${BIZ}' and title = 'R2 Tune-up')`) === "on_site");
    await job().getByRole("button", { name: "Checklist" }).click();
    await page.locator(".ba-check-list li").getByLabel("Photos of the unit").check();
    await page.getByRole("button", { name: "Save checklist" }).click();
    await job().locator("text=1 of 1 done").waitFor();
    await job().getByRole("button", { name: "Complete" }).click();
    await job().locator("text=Completed").waitFor();
    check("then it completes: the appointment is completed and the times are kept",
      sql(`select a.status || ' ' || d.status || ' ' || (d.en_route_at is not null and d.on_site_at is not null and d.finished_at is not null) from appointments a join job_dispatch d on d.appointment_id = a.id where a.business_id = '${BIZ}' and a.title = 'R2 Tune-up'`) === "completed completed true");

    // a job that moved on behind the screen
    sql(`insert into appointments (business_id, customer_id, title, start_time, end_time, timezone, status, staff_id)
         values ('${BIZ}', '${PAT}', 'R2 Leak check', ('${tomorrow} 14:00'::timestamp at time zone '${tz}'), ('${tomorrow} 15:00'::timestamp at time zone '${tz}'), '${tz}', 'scheduled', '${BEN}')`);
    await page.reload(); await page.waitForSelector("[data-dispatch=ready]");
    await page.getByRole("button", { name: "Next day" }).click();
    const leak = page.locator("section[aria-label='Ben Tech'] li", { hasText: "R2 Leak check" });
    await leak.waitFor();
    sql(`insert into job_dispatch (appointment_id, business_id, status) select id, business_id, 'en_route' from appointments where business_id = '${BIZ}' and title = 'R2 Leak check'`);
    await leak.getByRole("button", { name: "On the way" }).click();
    await page.waitForSelector("text=This job changed while you were looking at it");
    check("a step from an out-of-date screen is refused and the board shows the job as it is now", await leak.locator("text=On the way").first().isVisible() && await leak.getByRole("button", { name: "Arrived" }).isVisible());

    // recurring: a weekly plan with Ben, booked 4 weeks ahead as planned visits
    await page.goto(APP + "/app/recurring"); await page.waitForSelector("text=No recurring plans yet");
    await page.click("text=Add a plan");
    const pf = page.locator("form#ba-plan");
    await pf.locator("label:has(> span:text-is('Title')) input").fill("R2 Filter service");
    const wd = new Date(`${ymd(2)}T12:00:00Z`).getUTCDay();
    await pf.locator("label:has(> span:text-is('On')) select").selectOption(String(wd));
    await pf.locator("label:has(> span:text-is('At')) input").fill("08:00");
    await pf.locator("label:has(> span:text-is('With (optional)')) select").selectOption(BEN);
    check("the plan is described before saving", /Every week on \w+day at 8:00 AM/.test(await page.locator(".ba-modal, [role=dialog]").first().innerText()));
    await page.getByRole("button", { name: "Save plan" }).click();
    await page.waitForSelector("[data-plan='R2 Filter service']");
    await page.locator("[data-plan='R2 Filter service']").getByRole("button", { name: "Book the next 4 weeks" }).click();
    await page.locator("[data-plan='R2 Filter service']").getByText(/^\d+ upcoming visits? booked/).waitFor();   // not "No upcoming visits booked yet"
    const n = Number(sql(`select count(*) from appointments where business_id = '${BIZ}' and title = 'R2 Filter service' and booking_state = 'tentative' and hold_expires_at is null and staff_id = '${BEN}'`));
    check("booking the plan creates planned visits (4 or 5 in four weeks), held for Ben", n >= 4 && n <= 5, String(n));
    check("and queues no customer message", sql(`select count(*) from followup_tasks f join appointments a on a.id = f.appointment_id where a.business_id = '${BIZ}' and a.title = 'R2 Filter service'`) === "0");
    await page.locator("[data-plan='R2 Filter service']").getByRole("button", { name: "Book the next 4 weeks" }).click();
    await page.waitForTimeout(1200);
    check("booking it again adds nothing", Number(sql(`select count(*) from appointments where business_id = '${BIZ}' and title = 'R2 Filter service'`)) === n);
    await page.goto(APP + "/app/dispatch"); await page.waitForSelector("[data-dispatch=ready]");
    await page.getByRole("button", { name: "Next day" }).click(); await page.getByRole("button", { name: "Next day" }).click();
    await page.locator("section[aria-label='Ben Tech'] li", { hasText: "R2 Filter service" }).waitFor();
    check("a planned visit shows on the board as Planned", await page.locator("section[aria-label='Ben Tech'] li", { hasText: "R2 Filter service" }).locator("text=Planned").isVisible());
    // the calendar names planned visits (screen readers too); Confirm visit sets both fields, and an out-of-date one does nothing
    await page.goto(APP + "/app/calendar");
    const plannedEv = page.getByRole("button", { name: /^Planned: R2 Filter service/ });
    await page.waitForTimeout(1500);
    if (!(await plannedEv.count())) { await page.getByRole("button", { name: "Next", exact: true }).click(); await page.waitForTimeout(1500); }
    check("the calendar's label for a planned visit says Planned", (await plannedEv.count()) >= 1, String(await plannedEv.count()));
    const [firstId, secondId] = sql(`select string_agg(id::text, ',' order by start_time) from (select id, start_time from appointments where business_id = '${BIZ}' and title = 'R2 Filter service' order by start_time limit 2) x`).split(",");
    await plannedEv.first().click();
    await page.locator("[data-planned=true]").getByRole("button", { name: "Confirm visit" }).click();
    await page.getByText("Visit confirmed.").waitFor();
    check("Confirm visit confirms both the booking and its status", sql(`select booking_state || '/' || status from appointments where id = '${firstId}'`) === "confirmed/confirmed");
    await page.keyboard.press("Escape"); await page.waitForTimeout(800);
    await page.getByRole("button", { name: "Next", exact: true }).click();   // the next weekly visit
    await page.getByRole("button", { name: /^Planned: R2 Filter service/ }).first().click();
    await page.locator("[data-planned=true]").waitFor();
    sql(`update appointments set status = 'cancelled', updated_at = now() where id = '${secondId}'`);   // someone else cancels it meanwhile
    await page.locator("[data-planned=true]").getByRole("button", { name: "Confirm visit" }).click();
    await page.waitForTimeout(1500);
    check("confirming a visit someone else cancelled changes nothing and says so", sql(`select booking_state || '/' || status from appointments where id = '${secondId}'`) === "tentative/cancelled"
      && (await page.getByText(/Nothing was confirmed: this visit changed meanwhile/).isVisible()), sql(`select booking_state || '/' || status from appointments where id = '${secondId}'`));
    check("owner: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // viewer: sees everything, can change nothing
  {
    const { ctx, page, errors } = await open(browser, "viewer@glow.test");
    await page.goto(APP + "/app/dispatch"); await page.waitForSelector("[data-dispatch=ready]");
    await page.getByRole("button", { name: "Next day" }).click();
    await page.locator("li", { hasText: "R2 Tune-up" }).first().waitFor();
    check("viewer sees the board and is told why it's read-only", await page.isVisible("text=You can view the board. Changes need a staff member or above."));
    check("viewer has no job buttons (the owner had them)", (await page.locator("[data-dispatch] button").filter({ hasText: CHANGE }).count()) === 0);
    await page.goto(APP + "/app/resources"); await page.waitForSelector("[data-resources=ready]");
    check("viewer sees resources but can't add or edit", (await page.locator("text=Add a resource").count()) === 0 && (await page.getByRole("button", { name: "Edit" }).count()) === 0);
    check("viewer: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // phone width
  {
    const { ctx, page, errors } = await open(browser, "owner@glow.test", 390);
    await page.goto(APP + "/app/dispatch"); await page.waitForSelector("[data-dispatch=ready]");
    await page.getByRole("button", { name: "Next day" }).click(); await page.locator("li", { hasText: "R2 Tune-up" }).first().waitFor();
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    check("dispatch at 390px: no sideways scrolling", overflow <= 1, `${overflow}px`);
    await page.goto(APP + "/app/recurring"); await page.waitForSelector("[data-recurring=ready]");
    const overflow2 = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    check("recurring visits at 390px: no sideways scrolling", overflow2 <= 1, `${overflow2}px`);
    check("phone: no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }
  await browser.close();
  console.log(fails ? `\n${fails} FAILED` : "\nALL PASSED");
  process.exit(fails ? 1 : 0);
})();
