// OPS-12 and OPS-11: incident updates (internal unless Tell all active businesses is ticked), editing an open incident,
// the similar open incident warning, dialogs instead of browser prompts (no prefilled public text), and Load more.
// Real browser against the local stand in over an ISOLATED test database with sql/zella_admin_permissions.sql and
// sql/zella_incident_updates.sql applied. Desktop (1440x900) and phone (390 wide). Nothing is sent.
// Usage: ZDB=<test db> APP_URL=... BACKEND_URL=... SHOTS=<folder> node tests/browser/incident-updates.cjs
const path = require("path");
const k = require("./real-kit.cjs");
const SHOTS = process.env.SHOTS ?? path.join(__dirname, "out", "incident-updates");
const ADMIN = "admin@zella.test";
const notices = (kind) => Number(k.sql(`select count(*) from public.staff_notifications where kind = '${kind}'`));

(async () => {
  k.guard();
  require("fs").mkdirSync(SHOTS, { recursive: true });
  k.check("the test database has incident updates", k.sql("select to_regprocedure('public.zella_open_incident_checked(text,text,boolean)') is not null") === "t");
  const browser = await k.chromium.launch();
  for (const [width, tag] of [[1440, "desktop"], [390, "phone"]]) {
    k.sql("delete from public.platform_incidents");
    k.sql(`insert into public.platform_incidents (title, status, created_at, resolved_at) select 'Old incident ' || g, 'resolved', now() - (g || ' days')::interval, now() - (g || ' days')::interval from generate_series(1, 25) g`);
    // Old incidents 19 and 20 sit on both sides of the first page's end with the same time: the id decides the order
    k.sql(`update public.platform_incidents set created_at = (select created_at from public.platform_incidents where title = 'Old incident 19') where title = 'Old incident 20'`);
    const ctx = await k.context(browser, width);
    const p = await k.page(ctx);
    let prompts = 0; p.on("dialog", (d) => { prompts++; d.dismiss().catch(() => {}); });
    await k.signIn(p, ADMIN);
    await p.goto(k.APP + "/operations");
    const title = `Text messages delayed ${tag}`;
    await p.fill('input[aria-label="Incident title"]', title);
    await p.click('button:has-text("Open incident")');
    await p.click('[role="dialog"] button:has-text("Open incident")');
    await p.waitForSelector("text=Incident opened and owners notified.");
    const inc = k.sql(`select id from public.platform_incidents where title = '${title}'`);
    k.check(`${tag}: opening asks in a dialog, then opens`, /^[0-9a-f-]{36}$/.test(inc));
    // the same problem again
    await p.fill('input[aria-label="Incident title"]', `TEXT messages delayed ${tag}!`);
    await p.click('button:has-text("Open incident")');
    await p.click('[role="dialog"] button:has-text("Open incident")');
    await p.waitForSelector("text=This looks like an incident that's already open");
    k.check(`${tag}: a second one for the same problem shows the open one and opens nothing`, await p.isVisible(`[role="dialog"] >> text=${title}`) && k.sql("select count(*) from public.platform_incidents where status = 'open'") === "1");
    await p.waitForTimeout(500); await p.screenshot({ path: path.join(SHOTS, `similar-${tag}.png`) });
    await p.click('[role="dialog"] button:has-text("Cancel")');
    // updates
    const li = p.locator("li", { hasText: title }).first();
    await li.locator('button:has-text("Updates")').click();
    const before = notices("incident_update");
    await li.locator(`input[aria-label="Update for ${title}"]`).fill("Carrier confirmed the delay");
    await li.locator('button:has-text("Post update")').click();
    await p.waitForSelector("text=Update posted. No owner was told.");
    await li.locator("text=Carrier confirmed the delay").waitFor();
    const saved = k.sql(`select count(*) from public.platform_incident_updates where incident_id = '${inc}' and body = 'Carrier confirmed the delay' and notified_businesses = 0`);
    k.check(`${tag}: an update is internal by default, and is saved and shown on the timeline`, notices("incident_update") === before && saved === "1", `saved ${saved}`);
    await li.locator(`input[aria-label="Update for ${title}"]`).fill("Messages are flowing again");
    await li.locator("text=Tell all active businesses").click();
    await li.locator('button:has-text("Post update")').click();
    await p.waitForSelector("text=/Update posted\\. The owners of [0-9,]+ business(es)? were told in the app\\./");
    k.check(`${tag}: with Tell all active businesses ticked, owners are told`, notices("incident_update") > before, `${before} to ${notices("incident_update")}`);
    await p.waitForSelector("text=Messages are flowing again");
    // edit
    await li.locator('button:has-text("Edit")').click();
    await p.locator("li").filter({ has: p.locator('button:has-text("Save")') }).locator('input[aria-label="Incident title"]').fill(`${title} (one carrier)`);
    await p.click('button:has-text("Save")');
    await p.waitForSelector("text=Incident updated. Nobody was notified.");
    k.check(`${tag}: an open incident is edited and the edit audited`, k.sql(`select count(*) from public.audit_logs where action = 'platform.incident_edited' and entity_id = '${inc}'`) === "1");
    // public text: a dialog with nothing prefilled
    const li2 = p.locator("li", { hasText: `${title} (one carrier)` }).first();
    await li2.locator('button:has-text("Show on status page")').click();
    const box = p.locator('[role="dialog"] textarea');
    k.check(`${tag}: the public status text starts empty (nothing internal is prefilled)`, (await box.inputValue()) === "");
    await box.fill("Some text messages are delayed. We are working on it.");
    await p.waitForTimeout(400); await p.screenshot({ path: path.join(SHOTS, `public-text-${tag}.png`) });
    await p.click('[role="dialog"] button:has-text("Show on status page")');
    await p.waitForSelector("text=Shown on the public status page");
    // resolve
    await li2.locator('button:has-text("Resolve")').click();
    await p.click('[role="dialog"] button:has-text("Resolve")');
    await p.waitForSelector("text=Incident resolved and owners told.");
    // paging: the notice shows before the list reloads, so wait for the reloaded list (the incident shown as Resolved,
    // Load more enabled again) before adding the fixture, which must not be part of page one
    await li2.getByText("Resolved", { exact: true }).waitFor();
    await p.waitForSelector('button:has-text("Load more"):not([disabled])');
    const firstPage = await p.locator(".op-card li").filter({ hasText: "Opened" }).count();
    k.check(`${tag}: 20 incidents first, then Load more`, firstPage === 20, String(firstPage));
    // a new incident opened meanwhile must not shift the next page (it shows after a refresh, not as a repeat)
    k.sql(`insert into public.platform_incidents (title, status, created_at) values ('Opened while paging ${tag}', 'open', now())`);
    await p.click('button:has-text("Load more")');
    await p.waitForSelector("text=Old incident 25");
    const titles = await p.locator(".op-card li .inc-title").allTextContents();
    const old = titles.filter((t) => /^Old incident \d+$/.test(t));
    k.check(`${tag}: Load more appends the 6 older ones, each once (the tie at the page end decided by id)`, titles.length === 26 && new Set(titles).size === 26 && old.length === 25 && !titles.some((t) => t.startsWith("Opened while paging")),
      `${titles.length} rows, ${new Set(titles).size} unique`);
    k.sql(`delete from public.platform_incidents where title = 'Opened while paging ${tag}'`);
    // open the timeline only if it is closed (the button toggles), then wait for a known update before the screenshot
    const toggle = li2.locator('button[aria-expanded]').first();
    if ((await toggle.getAttribute("aria-expanded")) !== "true") await toggle.click();
    await li2.locator("text=Messages are flowing again").waitFor();
    await p.waitForTimeout(600); await p.screenshot({ path: path.join(SHOTS, `incidents-${tag}.png`), fullPage: true });
    k.check(`${tag}: no browser prompts or confirms were used`, prompts === 0, String(prompts));
    k.check(`${tag}: no page errors`, p.errors.length === 0, p.errors.join(" | "));
    await ctx.close();
  }
  await browser.close();
  console.log(k.failures() ? `${k.failures()} FAILED` : "ALL PASSED");
  process.exit(k.failures() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
