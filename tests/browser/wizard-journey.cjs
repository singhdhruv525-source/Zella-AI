// Setup wizard journey in a real browser against the local Supabase stand-in (see local-backend.mjs and page-review.cjs):
// real owner-provision-business code, isolated test database, nothing sent.
// Checks: steps can't be skipped before the draft exists; unsaved changes ask Save / Discard / Stay (Escape = Stay,
// focus returns); Discard really reverts; Save really saves; checkmarks follow saved data, not position; leaving through
// the sidebar or reloading with unsaved changes asks first; a double click saves once; the server refuses to finish
// setup without saved hours.
// Usage: node tests/browser/wizard-journey.cjs     (env APP_URL, BACKEND_URL)
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const PG = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zella_ui", "-AtqX", "-c"];
const sql = (q) => { try { return execFileSync("psql", [...PG, q], { stdio: ["ignore", "pipe", "pipe"] }).toString().trim(); } catch (e) { throw new Error(e.stderr.toString()); } };
let fails = 0;
const check = (name, ok, detail = "") => { if (!ok) fails++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` - ${detail}` : ""}`); };

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const actions = [];
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const req = route.request();
    if (req.url().includes("/functions/v1/owner-provision-business") && req.method() === "POST") {
      try { actions.push(JSON.parse(req.postData() ?? "{}").action); } catch { /* not json */ }
    }
    const r = await fetch(req.url().replace("https://zlocal.supabase.co", BACKEND), { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  const page = await ctx.newPage();
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  const dialogs = []; page.on("dialog", async (d) => { dialogs.push(d.type()); await d.dismiss(); });

  await page.goto(APP + "/");
  await page.fill('input[type="email"]', "admin@zella.test");
  await page.fill('input[type="password"]', "Test-pass-1");
  await page.click('button[type="submit"]');
  await page.waitForTimeout(2500);
  await page.goto(APP + "/businesses/new");
  await page.waitForSelector(".wiz-stepper");

  const step = (label) => page.locator(".wiz-stepper button", { hasText: label });
  check("before the draft exists, later steps can't be opened", await step("Owner & verification").isDisabled());

  const run = Date.now();
  const name = `Wizard Test ${run}`;
  const ownerEmail = `pat.${run}@plumb.test`;
  await page.getByRole("textbox", { name: /^Business name/ }).fill(name);
  await page.getByRole("combobox", { name: /^Industry/ }).selectOption({ label: "Plumbing" });
  // double click: one draft only
  const before = actions.length;
  await page.getByRole("button", { name: /Create draft & continue/ }).dblclick();
  await page.waitForTimeout(3000);
  const creates = actions.slice(before).filter((a) => a === "setup_save_business").length;
  check("a double click on Create draft saves once", creates === 1, `${creates} saves`);
  check("one business row created", sql(`select count(*) from businesses where name = '${name}'`) === "1");
  check("the Owner step opens after the draft is saved", /Owner/.test(await page.locator(".wiz-progress small").innerText()));
  check("Business step shows complete (name and industry saved)", (await step("Business").getAttribute("aria-label")).includes("saved and complete"));
  check("Owner step not complete yet", !(await step("Owner & verification").getAttribute("aria-label")).includes("saved and complete"));
  check("Hours step not complete just for being after the current one", !(await step("Hours & services").getAttribute("aria-label")).includes("saved and complete"));

  // unsaved change, then try to switch steps
  const ownerName = page.getByRole("textbox", { name: /^Owner full name/ });
  await ownerName.fill("Pat Plumber");
  check("the unsaved notice shows", await page.locator(".wiz-unsaved").isVisible());
  await step("Business").click();
  const dlg = page.getByRole("dialog", { name: /Save changes to/ });
  check("switching steps with unsaved changes asks first", await dlg.isVisible());
  check("focus moves into the dialog", await page.evaluate(() => Boolean(document.activeElement?.closest('[role="dialog"]'))));
  await page.keyboard.press("Tab"); await page.keyboard.press("Tab"); await page.keyboard.press("Tab");
  check("Tab stays inside the dialog", await page.evaluate(() => Boolean(document.activeElement?.closest('[role="dialog"]'))));
  await page.keyboard.press("Escape");
  check("Escape means stay: dialog closes, still on Owner, text kept", !(await dlg.isVisible()) && (await ownerName.inputValue()) === "Pat Plumber");

  // leaving through the sidebar with unsaved changes: the browser asks; dismissing stays
  await page.locator(".owner-nav a, .owner-nav button", { hasText: "Overview" }).first().click().catch(() => {});
  await page.waitForTimeout(500);
  check("leaving through the sidebar asks first, and staying keeps the wizard", dialogs.includes("confirm") && /\/businesses\//.test(page.url()));

  // discard
  await step("Business").click();
  await dlg.getByRole("button", { name: "Discard changes" }).click();
  await page.waitForTimeout(400);
  check("Discard goes to the chosen step", /Business/.test(await page.locator(".wiz-progress small").innerText()));
  await step("Owner & verification").click();
  await page.waitForTimeout(300);
  check("Discard really reverted the change", (await page.getByRole("textbox", { name: /^Owner full name/ }).inputValue()) === "");

  // save from the dialog
  await page.getByRole("textbox", { name: /^Owner full name/ }).fill("Pat Plumber");
  await page.getByRole("textbox", { name: /Owner email/ }).fill(ownerEmail);
  await step("Hours & services").click();
  await dlg.getByRole("button", { name: "Save changes" }).click();
  await page.waitForTimeout(2500);
  if (process.env.DEBUG) console.log("after save:", await page.locator(".wiz-error, .wiz-unsaved").allInnerTexts(), await page.locator(".wiz-progress small").innerText());
  const saved = sql(`select i.email || '|' || i.role || '|' || i.status from business_invitations i join businesses b on b.id = i.business_id where b.name = '${name}'`);
  check("Save in the dialog saved the owner (owner role, pending)", saved === `${ownerEmail}|owner|pending`, saved);
  check("and moved to the chosen step", /Hours/.test(await page.locator(".wiz-progress small").innerText()));
  check("Owner step still not complete: verification documents missing", !(await step("Owner & verification").getAttribute("aria-label")).includes("saved and complete"));

  // reload with unsaved changes asks (beforeunload)
  await page.locator("textarea").first().fill("We fix pipes.").catch(() => {});
  dialogs.length = 0;
  await page.close({ runBeforeUnload: true });
  await new Promise((r) => setTimeout(r, 800));
  check("closing or reloading with unsaved changes asks first", dialogs.includes("beforeunload"), dialogs.join(","));

  // server-side: finishing without saved hours is refused even with documents in place
  const id = sql(`select id from businesses where name = '${name}'`);
  sql(`insert into business_verification_documents (business_id, kind, file_name, file_path, mime_type, size_bytes, status)
       select '${id}', k, k || '.pdf', '${id}/' || k, 'application/pdf', 1000, 'pending_review' from unnest(array['business_registration','owner_identity']) k`);
  const tok = await (await fetch(BACKEND + "/auth/v1/token?grant_type=password", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "admin@zella.test", password: "Test-pass-1" }) })).json();
  const finish = await fetch(BACKEND + "/functions/v1/owner-provision-business", { method: "POST", headers: { authorization: `Bearer ${tok.access_token}`, "content-type": "application/json" }, body: JSON.stringify({ action: "setup_finish", businessId: id }) });
  const body = await finish.json();
  check("the server refuses to finish setup without saved opening hours", finish.status === 400 && /opening hours/i.test(body.error ?? ""), `${finish.status} ${body.error ?? ""}`);
  check("and the business stays inactive", sql(`select is_active from businesses where id = '${id}'`) === "f");

  // a staff invitation newer than the owner's must not be taken for the owner's
  sql(`insert into business_hours (business_id, weekday, opens, closes) values ('${id}', 1, '09:00', '17:00')`);
  sql(`insert into business_invitations (business_id, email, owner_name, status, role, invited_by, created_at) values ('${id}', 'helper@plumb.test', 'Helper', 'pending', 'staff', 'a0000000-0000-0000-0000-000000000001', now() + interval '1 minute')`);
  const fin2 = await fetch(BACKEND + "/functions/v1/owner-provision-business", { method: "POST", headers: { authorization: `Bearer ${tok.access_token}`, "content-type": "application/json" }, body: JSON.stringify({ action: "setup_finish", businessId: id }) });
  const b2 = await fin2.json();
  const after = sql(`select string_agg(role || ':' || email || ':' || status, ',' order by role) from business_invitations where business_id = '${id}'`);
  check("finishing setup invites the owner, never a newer staff invitation", fin2.status === 200 && b2.invitationStatus === "sent" && after === `owner:${ownerEmail}:sent,staff:helper@plumb.test:pending`, `${fin2.status} ${JSON.stringify(b2).slice(0, 120)} | ${after}`);

  check("no page errors", errors.length === 0, errors.join("; "));
  await browser.close();
  console.log(fails ? `${fails} FAILED` : "ALL PASSED");
  process.exit(fails ? 1 : 0);
})();
