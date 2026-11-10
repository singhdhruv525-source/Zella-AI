// Batch 3 browser checks: the CRM against an ISOLATED database with the Batch 3 fixture (tests/batch3/fixture.sql),
// served by tests/browser/local-backend.mjs (real row security and functions; nothing is sent anywhere). Failures
// (a count, previews, names, integrations) are injected by answering those requests with an error in the browser.
// Setup: tests/batch3/browser.sh.   Run: node tests/browser/crm-batch3.cjs [screenshot dir]
const { chromium, devices } = require("playwright");
const APP = "http://localhost:5199", BACKEND = "http://localhost:54321", OUT = process.argv[2];
const ALPHA = "b3000000-0000-0000-0000-0000000000a1", BETA = "b3000000-0000-0000-0000-0000000000b1";
let pass = 0, fail = 0;
const check = (ok, name, extra = "") => { if (ok) { pass++; console.log("PASS " + name); } else { fail++; console.log("FAIL " + name + (extra ? ` (${extra})` : "")); } };

async function login(b, email, { business = ALPHA, path = "/app", mobile = false, block = [] } = {}) {
  const ctx = await b.newContext(mobile ? { ...devices["iPhone 13"] } : { viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript((id) => localStorage.setItem("zella.lastBusiness", id), business);
  const blocked = { rules: block, slow: [] };   // slow: [{ match(request), ms }] answers late, to test races
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const q = route.request();
    if (blocked.rules.some((r) => r(q))) return route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ message: "injected failure" }) });
    const lag = blocked.slow.find((x) => x.match(q));
    if (lag) await new Promise((res) => setTimeout(res, lag.ms));
    const r = await fetch(q.url().replace("https://zlocal.supabase.co", BACKEND), { method: q.method(), headers: q.headers(), body: ["GET", "HEAD"].includes(q.method()) ? undefined : q.postDataBuffer() });
    await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
  });
  const p = await ctx.newPage(); const errors = []; p.on("pageerror", (e) => errors.push(String(e)));
  await p.goto(APP + path); await p.fill('input[type="email"]', email);
  if (!(await p.$('input[type="password"]'))) await p.click('button[type="submit"]');
  await p.fill('input[type="password"]', "Test-pass-1"); await p.click('button[type="submit"]');
  await p.waitForTimeout(3000);
  return { ctx, p, errors, blocked };
}
const go = async (p, path) => { await p.goto(APP + path); await p.waitForTimeout(2200); };
const text = (p, sel) => p.locator(sel).first().innerText().catch(() => "");
const shot = (p, name) => OUT ? p.screenshot({ path: `${OUT}/${name}.png` }) : null;
const isAttentionCount = (q) => q.url().includes("/rest/v1/calls_view") && q.url().includes("needs_human=eq.true") && q.method() === "HEAD";

(async () => {
  const b = await chromium.launch();

  // ---------------- B3-01 escalation count
  let s = await login(b, "own-a@b3.test");
  const banner = await text(s.p, ".ba-banner.alert");
  check(/3 callers need a person/.test(banner), "B3-01 three unresolved escalations show three", banner);
  check((await text(s.p, ".ba-nav-item .ba-count")) === "3", "B3-01 the sidebar badge says 3");
  await s.ctx.close();

  s = await login(b, "own-a@b3.test");
  s.blocked.rules.push(isAttentionCount);
  await s.p.waitForTimeout(61500);                              // the 60-second check runs, and fails
  const stale = await s.p.locator('[data-attention="stale"]').count();
  check(stale === 1 && /3 callers need a person/.test(await text(s.p, ".ba-banner.alert")), "B3-01 a failed refresh keeps 3 and marks it out of date");
  s.blocked.rules.length = 0;
  await s.p.locator('[data-attention="stale"] button', { hasText: "Try again" }).click(); await s.p.waitForTimeout(1200);
  check(await s.p.locator("[data-attention]").count() === 0 && /3 callers/.test(await text(s.p, ".ba-banner.alert")), "B3-01 Try again restores the current count");
  await s.ctx.close();

  s = await login(b, "own-a@b3.test", { block: [isAttentionCount] });
  check(await s.p.locator('[data-attention="unavailable"]').count() === 1 && await s.p.locator(".ba-banner.alert").count() === 0
    && await s.p.locator(".ba-nav-item .ba-count").count() === 0, "B3-01 a first failure says the count can't be checked, with no number");
  await shot(s.p, "b3-01-unavailable");
  await s.ctx.close();

  // valid zero: Beta has no escalations
  s = await login(b, "own-b@b3.test", { business: BETA });
  check(await s.p.locator(".ba-banner.alert").count() === 0 && await s.p.locator("[data-attention]").count() === 0, "B3-01 a real zero shows no escalations and no warning");
  await s.ctx.close();

  // switching businesses: Alpha's 3 never shows on Beta
  s = await login(b, "multi@b3.test");
  check(/3 callers/.test(await text(s.p, ".ba-banner.alert")), "B3-01 switching: Alpha shows 3");
  let switched = false;
  const sw = s.p.locator("select").filter({ has: s.p.locator("option", { hasText: "B3 Beta" }) }).first();
  if (await sw.count()) { await sw.selectOption({ label: "B3 Beta" }); switched = true; }
  else {
    const btn = s.p.locator("button", { hasText: /B3 Alpha/ }).first();
    if (await btn.count()) { await btn.click(); await s.p.waitForTimeout(300); const opt = s.p.locator("button, [role=menuitem], [role=option]", { hasText: "B3 Beta" }).first(); if (await opt.count()) { await opt.click(); switched = true; } }
  }
  await s.p.waitForTimeout(2500);
  check(switched && await s.p.locator(".ba-banner.alert").count() === 0 && await s.p.locator(".ba-nav-item .ba-count").count() === 0,
    "B3-01 switching to Beta shows no Alpha count", switched ? "" : "no business switcher found");
  await s.ctx.close();

  // ---------------- B3-03 leads
  s = await login(b, "own-a@b3.test", { path: "/app/leads" });
  await go(s.p, "/app/leads");
  const head = await text(s.p, ".ba-page-head p");
  check(/leads are overdue/.test(head), "B3-03 overdue total across all leads", head);
  const colCounts = await s.p.locator(".ba-board-col header span").allInnerTexts();
  check(colCounts.reduce((a, n) => a + Number(n), 0) === 1201, "B3-03 pipeline column totals add up to all 1,201 leads", colCounts.join(","));
  await shot(s.p, "b3-03-pipeline");
  await s.p.locator(".ba-segment button", { hasText: "List" }).click(); await s.p.waitForTimeout(1500);
  check(/1201 leads · page 1 of 49/.test(await text(s.p, ".ba-table-foot")), "B3-03 the list counts 1,201 leads in 49 pages", await text(s.p, ".ba-table-foot"));
  const first = await s.p.locator(".ba-table tbody tr").first().innerText();
  await s.p.locator(".ba-table-foot button", { hasText: "Next" }).click(); await s.p.waitForTimeout(1200);
  check(/page 2 of 49/.test(await text(s.p, ".ba-table-foot")) && (await s.p.locator(".ba-table tbody tr").first().innerText()) !== first, "B3-03 Next loads the second page");
  const searchBox = s.p.locator('header input[type="search"], .ba-search input').first();
  await searchBox.fill("Zephyrine"); await s.p.waitForTimeout(1800);
  check((await s.p.locator(".ba-table tbody tr").count()) === 1 && /Zephyrine/.test(await text(s.p, ".ba-table tbody tr")), "B3-03 search finds the lead older than the newest 1,000");
  await s.p.locator(".ba-table tbody tr").first().click(); await s.p.waitForTimeout(1200);
  check(await s.p.locator(".ba-modal, .ba-drawer, [role=dialog]").count() > 0, "B3-03 the lead's panel opens");
  await s.p.keyboard.press("Escape");
  await searchBox.fill(""); await s.p.waitForTimeout(1200);
  await s.p.locator(".ba-segment button", { hasText: /^Overdue/ }).click(); await s.p.waitForTimeout(1500);
  const od = await text(s.p, ".ba-table-foot");
  check(/leads? ·/.test(od) && !/^1201/.test(od), "B3-03 the overdue filter pages over all overdue leads", od);
  check(s.errors.length === 0, "B3-03 no page errors", s.errors.join(" | "));
  await s.ctx.close();

  // ---------------- B3-04 records and B3-07 links
  s = await login(b, "own-a@b3.test", { path: "/app/records/b3jobs" });
  await go(s.p, "/app/records/b3jobs");
  const sel = s.p.locator(".ba-toolbar select").first();
  await sel.selectOption("all"); await s.p.waitForTimeout(1500);
  check(/611 jobs · page 1 of 25/.test(await text(s.p, ".ba-table-foot")), "B3-04 all 611 jobs (more than 500) are counted and paged", await text(s.p, ".ba-table-foot"));
  const cells = await s.p.locator(".ba-table tbody tr td:nth-child(3)").allInnerTexts();
  check(cells.length === 25 && cells.every((c) => /^Property \d+$/.test(c)), "B3-07 linked property titles resolve on the page", cells.slice(0, 3).join(","));
  await shot(s.p, "b3-04-records");
  for (let i = 0; i < 24; i++) { await s.p.locator(".ba-table-foot button", { hasText: "Next" }).click(); await s.p.waitForTimeout(350); }
  await s.p.waitForTimeout(800);
  check(/page 25 of 25/.test(await text(s.p, ".ba-table-foot")) && (await s.p.locator(".ba-table-foot button", { hasText: "Next" }).isDisabled()), "B3-04 the last page is reachable and Next stops there");
  const lastTitles = await s.p.locator(".ba-table tbody tr td:first-child").allInnerTexts();
  check(lastTitles.includes("Needle in the haystack"), "B3-04 the oldest record is on the last page");
  const needleRow = s.p.locator(".ba-table tbody tr", { hasText: "Needle in the haystack" });
  check(/Unavailable record/.test(await needleRow.innerText()), "B3-07 a link to another business's record shows 'Unavailable record'");
  await s.p.locator('header input[type="search"], .ba-search input').first().fill("brass valve"); await s.p.waitForTimeout(1800);
  check((await s.p.locator(".ba-table tbody tr").count()) === 1, "B3-04 search finds the oldest record by its details");
  await s.p.locator(".ba-table tbody tr").first().click(); await s.p.waitForTimeout(1000);
  check(await s.p.locator(".ba-modal").count() === 1, "B3-04 the record opens");
  await s.p.keyboard.press("Escape"); await s.p.waitForTimeout(300);
  check(s.errors.length === 0, "B3-04 no page errors", s.errors.join(" | "));
  await s.ctx.close();

  // links whose lookup fails say so
  s = await login(b, "own-a@b3.test", { path: "/app/records/b3jobs", block: [(q) => q.url().includes("/rest/v1/crm_records") && q.url().includes("select=id%2Ctitle")] });
  await go(s.p, "/app/records/b3jobs");
  check(/Couldn't load/.test(await text(s.p, ".ba-table tbody tr td:nth-child(3)")), "B3-07 a failed title lookup shows 'Couldn't load', not a wrong title");
  await s.ctx.close();

  // ---------------- B3-05 calls
  s = await login(b, "own-a@b3.test", { path: "/app/calls" });
  await go(s.p, "/app/calls");
  check(/360 calls · page 1 of 15/.test(await text(s.p, ".ba-table-foot")), "B3-05 all 360 calls (more than 300) are counted", await text(s.p, ".ba-table-foot"));
  await s.p.locator(".ba-segment button", { hasText: "Needs a person" }).click(); await s.p.waitForTimeout(1500);
  check(/^3 calls$/.test(await text(s.p, ".ba-table-foot")), "B3-05 needs-a-person covers the whole history (3, including the 341st call)", await text(s.p, ".ba-table-foot"));
  await s.p.locator(".ba-segment button", { hasText: "Missed" }).click(); await s.p.waitForTimeout(1500);
  check(/^120 calls/.test(await text(s.p, ".ba-table-foot")), "B3-05 missed covers the whole history (120)", await text(s.p, ".ba-table-foot"));
  check(await s.p.locator(".ba-table tbody tr", { hasText: "Follow-up set" }).count() > 0, "B3-05 linked follow-ups show on their calls");
  await s.p.locator(".ba-segment button", { hasText: "All" }).click(); await s.p.waitForTimeout(1500);
  const ownerIcons = await s.p.locator(".ba-table tbody .ba-actions .ba-icon").allInnerTexts();
  check(ownerIcons.filter((t) => t === "subject").length === 5 && ownerIcons.includes("graphic_eq"), "B3-05 the owner's list marks calls with a transcript (5 of 25) and a recording", ownerIcons.join(","));
  await s.p.locator(".ba-table tbody tr").nth(4).click(); await s.p.waitForTimeout(1500);   // the 5th newest has a transcript (i % 5 = 0)
  check(/secret words 5/.test(await text(s.p, ".ba-modal")), "B3-05 the owner opens a call and reads its transcript");
  await shot(s.p, "b3-05-call");
  // a late answer for the call opened first must not replace (or close) the call opened second
  await s.p.keyboard.press("Escape"); await s.p.waitForTimeout(400);
  s.blocked.slow.push({ match: (q) => q.url().includes("/rest/v1/calls_view") && q.url().includes("id=eq.") && !q.url().includes("needs_human") && !s.blocked.slowUsed && (s.blocked.slowUsed = true), ms: 2500 });
  await s.p.locator(".ba-table tbody tr").nth(0).click(); await s.p.waitForTimeout(150);
  await s.p.keyboard.press("Escape"); await s.p.waitForTimeout(150);
  await s.p.locator(".ba-table tbody tr").nth(4).click();
  await s.p.waitForTimeout(3500);
  check(/secret words 5/.test(await text(s.p, ".ba-modal")) && await s.p.locator(".ba-modal").count() === 1, "B3-05 a late answer for an earlier call doesn't replace or close the call opened now");
  check(s.errors.length === 0, "B3-05 no page errors", s.errors.join(" | "));
  await s.ctx.close();
  s = await login(b, "staff-a@b3.test", { path: "/app/calls" });
  await go(s.p, "/app/calls");
  const staffIcons = await s.p.locator(".ba-table tbody .ba-actions .ba-icon").allInnerTexts();
  await s.p.locator(".ba-table tbody tr").nth(4).click(); await s.p.waitForTimeout(1500);
  check(!/secret words/.test(await text(s.p, ".ba-modal")) && !staffIcons.some((t) => /subject|graphic_eq/.test(t)), "B3-05 staff without call-content permission see no transcript, in the list or the call");
  await s.ctx.close();

  // ---------------- B3-02 inbox and B3-06 partial failures
  s = await login(b, "own-a@b3.test", { path: "/app/inbox" });
  await go(s.p, "/app/inbox");
  check(/600 items · page 1 of 12/.test(await text(s.p, ".ba-inbox-list .ba-table-foot")), "B3-02 the inbox counts all 600 calls and conversations", await text(s.p, ".ba-inbox-list .ba-table-foot"));
  const times = await s.p.locator(".ba-inbox-row time").evaluateAll((ts) => ts.map((t) => t.getAttribute("title")));
  check(times.length === 50, "B3-02 a page holds 50 items");
  const kinds = await s.p.locator(".ba-inbox-row .ba-thread-icon").evaluateAll((xs) => xs.map((x) => x.innerText.trim()));
  check(new Set(kinds).size > 1, "B3-02 calls and conversations are interleaved on one page", [...new Set(kinds)].join(","));
  check(await s.p.locator(".ba-inbox-row small", { hasText: /^Message 5 / }).count() > 0, "B3-06 previews show the latest message");
  for (let i = 0; i < 5; i++) { await s.p.locator(".ba-inbox-list .ba-table-foot button", { hasText: "Next" }).click(); await s.p.waitForTimeout(700); }
  check(/page 6 of 12/.test(await text(s.p, ".ba-inbox-list .ba-table-foot")), "B3-02 items past the first 200 are reachable (page 6)");
  await s.p.locator(".ba-segment button", { hasText: /^Unread/ }).click(); await s.p.waitForTimeout(1500);
  const unreadFoot = await text(s.p, ".ba-inbox-list .ba-table-foot");
  check(!/600/.test(unreadFoot) && await s.p.locator(".ba-inbox-row.unread").count() === await s.p.locator(".ba-inbox-row").count(), "B3-02 the unread filter lists only unread, from the whole inbox", unreadFoot);
  await s.p.locator(".ba-segment button", { hasText: /^All/ }).click(); await s.p.waitForTimeout(1500);
  await s.p.locator(".ba-inbox-row", { hasText: /Message 5/ }).first().click(); await s.p.waitForTimeout(1500);
  check(await s.p.locator(".ba-thread .ba-msg").count() > 0, "B3-02 a conversation opens with its thread");
  await shot(s.p, "b3-02-inbox");
  check(s.errors.length === 0, "B3-02 no page errors", s.errors.join(" | "));
  await s.ctx.close();

  // previews fail: the list still shows, with a warning and "Preview unavailable"
  s = await login(b, "own-a@b3.test", { path: "/app/inbox", block: [(q) => q.url().includes("/rpc/zella_inbox_previews")] });
  await go(s.p, "/app/inbox");
  check(await s.p.locator(".ba-inbox-row").count() === 50 && /message previews/.test(await text(s.p, '[data-partial="inbox"]'))
    && await s.p.locator(".ba-inbox-row small", { hasText: "Preview unavailable" }).count() > 0, "B3-06 failed previews: full list, a warning, 'Preview unavailable'");
  s.blocked.rules.length = 0;
  await s.p.locator('[data-partial="inbox"] button', { hasText: "Try again" }).click(); await s.p.waitForTimeout(1500);
  check(await s.p.locator('[data-partial="inbox"]').count() === 0 && await s.p.locator(".ba-inbox-row small", { hasText: /^Message 5 / }).count() > 0, "B3-06 Try again restores the previews");
  await s.ctx.close();

  // integrations fail: not shown as "not connected"; replying is paused
  s = await login(b, "own-a@b3.test", { path: "/app/inbox", block: [(q) => q.url().includes("/rest/v1/integrations")] });
  await go(s.p, "/app/inbox");
  await s.p.locator(".ba-inbox-row", { hasText: /Message 5/ }).first().click(); await s.p.waitForTimeout(1500);
  const blockedText = await text(s.p, ".ba-blocked");
  check(/Couldn't check whether (text messaging|email) is connected/.test(blockedText) && !/isn't connected yet/.test(blockedText), "B3-06 failed integrations: 'couldn't check', not 'not connected'", blockedText);
  check(/connected channels/.test(await text(s.p, '[data-partial="inbox"]')), "B3-06 the warning names connected channels");
  await s.ctx.close();

  // people (contact preferences) fail: replying is paused, never allowed
  s = await login(b, "own-a@b3.test", { path: "/app/inbox", block: [(q) => q.url().includes("/rest/v1/customers") && q.url().includes("do_not_contact")] });
  await go(s.p, "/app/inbox");
  await s.p.locator(".ba-inbox-row", { hasText: /Message 5/ }).first().click(); await s.p.waitForTimeout(1500);
  check(/contact preferences/.test(await text(s.p, ".ba-blocked")) && await s.p.locator('.ba-composer textarea').count() === 0, "B3-06 failed consent lookup: no reply box");
  await shot(s.p, "b3-06-consent-paused");
  s.blocked.rules.length = 0;
  await s.p.locator(".ba-blocked button", { hasText: "Try again" }).click(); await s.p.waitForTimeout(1800);
  check(await s.p.locator(".ba-blocked button", { hasText: "Try again" }).count() === 0, "B3-06 Try again re-checks contact preferences");
  await s.ctx.close();

  // A retained conversation still needs its contact after paging away, including consent checks.
  for (const optedOut of [false, true]) {
    s = await login(b, "own-a@b3.test", { path: "/app/inbox" });
    await s.ctx.route("**/rest/v1/integrations?**", (route) => route.fulfill({ json: [{ provider: "telnyx", status: "active" }, { provider: "email", status: "active" }] }));
    let contactName;
    let failPeople = false;
    const lookups = [];
    await s.ctx.route("**/rest/v1/customers?**", async (route) => {
      const q = route.request();
      if (!q.url().includes("do_not_contact")) return route.fallback();
      lookups.push(new URL(q.url()).searchParams.get("id"));
      if (failPeople) return route.fulfill({ status: 500, json: { message: "injected contact failure" } });
      const response = await fetch(q.url().replace("https://zlocal.supabase.co", BACKEND), { headers: q.headers() });
      const rows = await response.json();
      return route.fulfill({ json: rows.map((row) => ({ ...row, do_not_contact: optedOut, do_not_sms: false, do_not_email: false })) });
    });
    await go(s.p, "/app/inbox");
    const row = s.p.locator(".ba-inbox-row", { hasText: /Message 5/ }).first();
    const name = await row.locator("strong").innerText();
    await row.click();
    await s.p.waitForTimeout(1500);
    contactName = await s.p.locator(".ba-inbox-head .ba-namebtn").innerText();
    const replyCorrect = async () => optedOut
      ? /asked not to be contacted/.test(await text(s.p, ".ba-blocked")) && await s.p.locator(".ba-composer textarea").count() === 0
      : await s.p.locator(".ba-composer textarea").count() === 1;
    check(contactName === name && await replyCorrect(), `retained contact: initial reply state (opt-out ${optedOut})`);
    failPeople = true;
    await s.p.locator(".ba-inbox-list .ba-table-foot button", { hasText: "Next" }).click();
    await s.p.waitForTimeout(1500);
    check(await s.p.locator(".ba-inbox-row strong", { hasText: name }).count() === 0
      && /contact preferences/.test(await text(s.p, ".ba-blocked")) && await s.p.locator(".ba-composer textarea").count() === 0,
      `retained contact: page change and failed lookup pause replies (opt-out ${optedOut})`);
    failPeople = false;
    await s.p.locator(".ba-blocked button", { hasText: "Try again" }).click();
    await s.p.waitForTimeout(1800);
    check(await text(s.p, ".ba-inbox-head .ba-namebtn") === name
      && await s.p.locator(".ba-inbox-row strong", { hasText: new RegExp(`^${name}$`) }).count() === 0 && await replyCorrect(),
      `retained contact: retry restores contact and respects opt-out ${optedOut}`, lookups.join(" | "));
    check(s.errors.length === 0, "retained contact: no page errors", s.errors.join(" | "));
    await s.ctx.close();
  }

  // ---------------- phone: inbox list -> conversation -> back
  s = await login(b, "own-a@b3.test", { path: "/app/inbox", mobile: true });
  await go(s.p, "/app/inbox");
  await s.p.locator(".ba-inbox-row").first().click(); await s.p.waitForTimeout(1200);
  const back = s.p.locator(".ba-inbox-back").first();
  check(await back.isVisible(), "phone: the open item shows Back");
  await back.click(); await s.p.waitForTimeout(600);
  check(await s.p.locator(".ba-inbox-row").first().isVisible(), "phone: Back returns to the list");
  const wide = await s.p.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  check(!wide, "phone: no sideways scrolling on the inbox");
  await shot(s.p, "b3-phone-inbox");
  await go(s.p, "/app/leads");
  check(!(await s.p.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)), "phone: no sideways scrolling on leads");
  await s.ctx.close();

  await b.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
