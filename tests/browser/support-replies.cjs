// OPS-25 (and OPS-27 filters): a business opens a support request, Zella Voice support replies from Support tickets,
// the business reads the reply in Settings and answers; staff can read but not answer; internal notes never reach the
// business. Real browser against the local stand in over an ISOLATED test database with sql/zella_support_notes.sql
// and sql/zella_support_replies.sql applied. Desktop (1440x900) and phone (390 wide). Nothing is sent.
// Usage: ZDB=<test db> APP_URL=... BACKEND_URL=... SHOTS=<folder> node tests/browser/support-replies.cjs
const path = require("path");
const k = require("./real-kit.cjs");
const SHOTS = process.env.SHOTS ?? path.join(__dirname, "out", "support-replies");
const ADMIN = "admin@zella.test", OWNER = "own-a@b3.test", STAFF = "staff-a@b3.test";
const BIZ = "b3000000-0000-0000-0000-0000000000a1";

(async () => {
  k.guard();
  require("fs").mkdirSync(SHOTS, { recursive: true });
  k.check("the test database has support replies", k.sql("select to_regclass('public.support_ticket_messages') is not null") === "t");
  const browser = await k.chromium.launch();
  for (const [width, tag] of [[1440, "desktop"], [390, "phone"]]) {
    const subject = `Calls drop after 10 seconds ${tag} ${Date.now().toString(36)}`;
    // 1. the business opens an urgent request from Settings
    let ctx = await k.context(browser, width); let p = await k.page(ctx);
    await k.signIn(p, OWNER);
    await p.goto(k.APP + "/app/settings/help/tickets");
    await p.locator("label:has-text('Type') select, .zs-field:has-text('Type') select").first().selectOption("issue");
    await p.locator(".zs-field:has-text('Subject') input, label:has-text('Subject') input").first().fill(subject);
    await p.locator("text=Urgent: calls or bookings").click();
    await p.click('button:has-text("Send")');
    await p.waitForSelector(`text=${subject}`);
    const ticket = k.sql(`select id from public.support_tickets where subject = '${subject}'`);
    k.check(`${tag}: the request is a ticket`, /^[0-9a-f-]{36}$/.test(ticket));
    k.check(`${tag}: an urgent request raises a platform alert`, k.sql(`select count(*) from public.platform_alerts where kind = 'support_urgent_ticket' and dedupe_key = '${ticket}'`) === "1");
    const ownerErrors = p.errors.slice(); await ctx.close();

    // 2. Zella Voice support replies, and adds an internal note
    ctx = await k.context(browser, width); p = await k.page(ctx);
    await k.signIn(p, ADMIN);
    await p.goto(k.APP + "/support");
    // a ticket that has waited three days without a reply is overdue; the request just opened isn't yet
    const overdue = `Overdue fixture ${tag} ${Date.now().toString(36)}`;
    const overdueId = k.sql(`insert into public.support_tickets (business_id, subject, status, priority, category, created_at) values ('${BIZ}', '${overdue}', 'open', 'normal', 'issue', now() - interval '3 days') returning id`);
    try {   // the fixture goes by its id, even when a wait below fails
      await p.reload(); await p.waitForSelector(`text=${subject}`);
      await p.click('button[role="tab"]:has-text("Waiting too long")');
      await p.waitForSelector(`text=${overdue}`);
      k.check(`${tag}: Waiting too long shows the overdue ticket and not the new one`, await p.isVisible(`text=${overdue}`) && !(await p.isVisible(`text=${subject}`)));
    } finally {
      k.sql(`delete from public.support_tickets where id = '${overdueId}'`);
    }
    await p.click('button[role="tab"]:has-text("Open & in progress")');
    await p.click(`button:has-text("${subject}")`);
    // the detail panel of the ticket just opened says it has no reply yet
    await p.locator("aside.st-detail").filter({ hasText: subject }).locator("text=No reply yet").waitFor();
    await p.fill('textarea[aria-label="Reply to the business"]', "We are looking at your phone line now.");
    await p.click('button:has-text("Send reply")');
    await p.waitForSelector("text=We are looking at your phone line now.");
    await p.fill('textarea[placeholder="Add a note for the Zella Voice team"]', "Internal: carrier issue suspected");
    await p.click('button:has-text("Add note")');
    await p.waitForSelector("text=Internal: carrier issue suspected");
    await p.waitForSelector("text=First reply:");
    k.check(`${tag}: the reply sets the first response time`, k.sql(`select first_response_at is not null from public.support_tickets where id = '${ticket}'`) === "t");
    k.check(`${tag}: the ticket_update audit entry records the reply`, k.sql(`select count(*) from public.audit_logs where action = 'ticket.updated' and new_data ->> 'reply_added' = 'true' and entity_id = '${ticket}'`) !== "0");
    k.check(`${tag}: the owner is told in the app only`, k.sql(`select delivery_status || ':' || sms_status from public.staff_notifications where kind = 'support_reply' and entity_id = '${ticket}'`) === "skipped:skipped");
    await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `admin-reply-${tag}.png`), fullPage: true });
    const adminErrors = p.errors.slice(); await ctx.close();

    // 3. the owner reads the reply and answers
    ctx = await k.context(browser, width); p = await k.page(ctx);
    await k.signIn(p, OWNER);
    await p.goto(k.APP + "/app/settings/help/tickets");
    await p.locator("tr", { hasText: subject }).locator('button:has-text("Conversation")').click();
    await p.waitForSelector("text=We are looking at your phone line now.");
    k.check(`${tag}: the owner reads Zella Voice's reply`, true);
    k.check(`${tag}: and never the internal note`, !(await p.isVisible("text=carrier issue suspected")));
    await p.fill('textarea[maxlength="4000"]', "Thanks, it happens on every call.");
    await p.click('button:has-text("Send answer")');
    await p.waitForSelector("text=Thanks, it happens on every call.");
    await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `business-thread-${tag}.png`), fullPage: true });
    const owner2Errors = p.errors.slice(); await ctx.close();

    // 4. staff read but can't answer; the database refuses them too
    ctx = await k.context(browser, width); p = await k.page(ctx);
    await k.signIn(p, STAFF);
    await p.goto(k.APP + "/app/settings/help/tickets");
    await p.locator("tr", { hasText: subject }).locator('button:has-text("Conversation")').click();
    await p.waitForSelector("text=Thanks, it happens on every call.");
    k.check(`${tag}: staff read the conversation, with no answer box`, await p.isVisible("text=Owners, admins and managers can answer.") && !(await p.isVisible('button:has-text("Send answer")')));
    const staffErrors = p.errors.slice(); await ctx.close();
    const tok = await k.token(STAFF);
    const r = await fetch(k.BACKEND + "/rest/v1/rpc/zella_business_ticket_reply", { method: "POST", headers: { authorization: `Bearer ${tok}`, apikey: "sb_publishable_local_test_only", "content-type": "application/json" }, body: JSON.stringify({ p_ticket: ticket, p_body: "sneaky" }) });
    k.check(`${tag}: a staff member calling the database directly is refused`, r.status >= 400 && /NOT_ALLOWED/.test(await r.text()), String(r.status));
    k.check(`${tag}: no page errors`, [...ownerErrors, ...adminErrors, ...owner2Errors, ...staffErrors].length === 0, [...ownerErrors, ...adminErrors, ...owner2Errors, ...staffErrors].join(" | "));
  }
  await browser.close();
  console.log(k.failures() ? `${k.failures()} FAILED` : "ALL PASSED");
  process.exit(k.failures() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
