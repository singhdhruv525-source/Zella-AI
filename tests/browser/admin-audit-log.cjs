// ACC-12: audit log filters (person, dates, action, record), the (created_at, id) cursor and the audited CSV export,
// against the local stand in over an ISOLATED test database, in a real browser at 1440x900 and 390 wide. Nothing is
// sent. Test rows only (entity type lanea_test, with this run's own record id; only those, and this run's own exports,
// are removed afterwards, whether the journey passes or not).
// Usage: ZDB=<test db> APP_URL=... BACKEND_URL=... SHOTS=<folder> node tests/browser/admin-audit-log.cjs
const fs = require("fs");
const path = require("path");
const k = require("./real-kit.cjs");
const SHOTS = process.env.SHOTS ?? path.join(__dirname, "out", "admin-audit-log");
const OWNER = "admin@zella.test", READONLY = "readonly@zella.test";
const ENTITY = require("crypto").randomUUID();   // this run's record id: every fixture and export of this run carries it
const catalog = JSON.parse(fs.readFileSync(path.join(__dirname, "../../web/supabase/functions/_shared/catalog.json"), "utf8"));
const OTHER = require("crypto").randomUUID();    // a second record of this run, which the record filter must leave out
const STARTED = new Date().toISOString();
const DECOY_ACTION = "admin.sessions_ended";   // the other record's rows; this run's own record's rows are admin.updated
const MEMBER = "staff-a@b3.test";
// the business member's refused call sends this run's own browser name, which the refusal records (user_agent)
const RUN_AGENT = `lanea-audit-journey ${ENTITY}`;
// this run's rows only: its fixtures, its exports, and the refusal its business member call records
const cleanUp = () => k.sql(`delete from public.audit_logs where (entity_type = 'lanea_test' and entity_id in ('${ENTITY}', '${OTHER}'))
  or (action = 'audit.exported' and new_data -> 'filters' ->> 'entityId' = '${ENTITY}')
  or (action = 'security.admin_refused' and user_agent = '${RUN_AGENT}' and created_at >= '${STARTED}'
      and user_id = (select id from auth.users where email = '${MEMBER}'))`);

(async () => {
  k.guard();
  fs.mkdirSync(SHOTS, { recursive: true });
  const owner = k.sql(`select id from auth.users where email = '${OWNER}'`), ro = k.sql(`select id from auth.users where email = '${READONLY}'`);
  try {
  // 60 entries at exactly the same time (the old cursor skipped ties), 5 by another person, 3 last month
  k.sql(`insert into public.audit_logs (user_id, action, entity_type, entity_id, new_data, user_agent, created_at)
    select '${owner}', 'admin.updated', 'lanea_test', '${ENTITY}', jsonb_build_object('n', g), '=HYPERLINK("x")', '2026-11-15 12:00:00.123456+00' from generate_series(1, 60) g`);
  k.sql(`insert into public.audit_logs (user_id, action, entity_type, entity_id, created_at) select '${ro}', 'admin.updated', 'lanea_test', '${ENTITY}', '2026-11-15 12:00:00.123456+00' from generate_series(1, 5)`);
  k.sql(`insert into public.audit_logs (user_id, action, entity_type, entity_id, created_at) select '${owner}', 'admin.updated', 'lanea_test', '${ENTITY}', '2026-10-10 09:00:00+00' from generate_series(1, 3)`);

  const tok = await k.token(OWNER);
  // at most 10 pages, as a guard; a cursor still there after them fails the check (seen is then null)
  const pages = async (filters) => {
    const seen = []; let before = null, n = 0;
    do { const r = await k.fn(tok, { action: "audit_logs", ...filters, before }); if (r.status !== 200) return { error: r }; seen.push(...r.body.logs.map((l) => l.id)); before = r.body.nextCursor; n++; } while (before && n < 10);
    return before ? { seen: null, n, capped: true } : { seen, n };
  };
  let p1 = await pages({ entityType: "lanea_test", entityId: ENTITY });
  k.check("paging through 68 entries, 65 of them at the same instant, shows each exactly once", p1.seen?.length === 68 && new Set(p1.seen).size === 68, `${p1.seen?.length} rows, ${new Set(p1.seen ?? []).size} unique, ${p1.n} pages`);
  p1 = await pages({ entityType: "lanea_test", entityId: ENTITY, actorId: ro });
  k.check("the person filter", p1.seen?.length === 5, String(p1.seen?.length));
  p1 = await pages({ entityType: "lanea_test", entityId: ENTITY, from: "2026-11-01", to: "2026-11-15" });
  k.check("the date filter (the end date counts the whole day)", p1.seen?.length === 65, String(p1.seen?.length));
  p1 = await pages({ entityType: "lanea_test", entityId: ENTITY, to: "2026-10-31" });
  k.check("and an earlier range", p1.seen?.length === 3, String(p1.seen?.length));
  const bad = await k.fn(tok, { action: "audit_logs", from: "yesterday" });
  k.check("a malformed filter is refused, never widened", bad.status === 400, `${bad.status} ${bad.body.error}`);
  const badCursor = await k.fn(tok, { action: "audit_logs", before: "2026-11-15),id.gt.(" });
  k.check("a malformed page marker is refused", badCursor.status === 400, String(badCursor.status));

  // export
  let r = await k.fn(await k.token(READONLY), { action: "audit_export", entityType: "lanea_test" });
  k.check("a read only admin (audit.view, not owner or super admin) can't export", r.status === 403, `${r.status} ${r.body.error}`);
  r = await k.fn(await k.token(MEMBER), { action: "audit_export" }, { "user-agent": RUN_AGENT });
  k.check("a business member can't", r.status === 403, String(r.status));
  r = await k.fn(null, { action: "audit_export" });
  k.check("nor anonymous", r.status === 401, String(r.status));
  const exportsBefore = Number(k.sql(`select count(*) from public.audit_logs where action = 'audit.exported' and user_id = '${owner}' and new_data -> 'filters' ->> 'entityId' = '${ENTITY}'`));
  r = await k.fn(tok, { action: "audit_export", entityType: "lanea_test", entityId: ENTITY, from: "2026-11-01" });
  const lines = (r.body.csv ?? "").trimEnd().split("\r\n");
  k.check("the owner exports the filtered entries as CSV", r.status === 200 && r.body.rows === 65 && lines.length === 66 && lines[0].startsWith("When (UTC),Action,"), `${r.status} ${r.body.rows} ${lines.length}`);
  k.check("a cell that would run as a formula (a browser name starting with =) starts with an apostrophe", lines.slice(1).every((l) => !/,"?=HYPERLINK/.test(l)) && lines.filter((l) => l.includes(`"'=HYPERLINK(""x"")"`)).length === 60, lines[1]?.slice(0, 200));
  // this export's own entry: by the owner, for this run's record id; exactly one, with its filters and row count
  const where = `action = 'audit.exported' and user_id = '${owner}' and new_data -> 'filters' ->> 'entityId' = '${ENTITY}'`;
  const exportsAfter = Number(k.sql(`select count(*) from public.audit_logs where ${where}`));
  const audit = k.sql(`select (new_data ->> 'rows') || '|' || (new_data -> 'filters' ->> 'entityType') || '|' || (new_data -> 'filters' ->> 'from') from public.audit_logs where ${where} limit 1`);
  k.check("the export is audited once, with its filters and row count", exportsBefore === 0 && exportsAfter === 1 && audit === "65|lanea_test|2026-11-01T00:00:00.000Z", `${exportsBefore} before, ${exportsAfter} after, ${audit}`);
  // a second record for the same person and record type, which the browser's record filter must leave out
  // (another action, so its rows can be told apart on screen too)
  k.sql(`insert into public.audit_logs (user_id, action, entity_type, entity_id, created_at) select '${ro}', '${DECOY_ACTION}', 'lanea_test', '${OTHER}', '2026-11-15 12:00:00.123456+00' from generate_series(1, 2)`);

  const browser = await k.chromium.launch();
  for (const [width, tag] of [[1440, "desktop"], [390, "phone"]]) {
    const ctx = await k.context(browser, width);
    const p = await k.page(ctx);
    await k.signIn(p, OWNER);
    await p.goto(k.APP + "/audit-logs");
    await p.waitForSelector("text=Export CSV");
    if (await p.isVisible(".al-filters-toggle")) await p.click(".al-filters-toggle"); // phones fold the filters away
    const values = await p.locator('label:has-text("Action") select option').evaluateAll((os) => os.map((o) => o.value).filter(Boolean));
    k.check(`${tag}: the Action filter lists every catalog action, each once`, JSON.stringify([...values].sort()) === JSON.stringify(Object.keys(catalog.audit_actions).sort()), `${values.length} options`);
    await p.locator('label:has-text("Person") select').selectOption({ label: READONLY });
    // the list read with the person and record type filters (no record id yet): this run's other record is in it
    // (other runs' rows may be too, so its own rows are checked, not a total)
    const listRead = (want) => p.waitForResponse((res) => { const d = res.request().postData() ?? ""; return res.url().includes("/functions/v1/owner-provision-business") && d.includes('"audit_logs"') && d.includes("lanea_test") && want(d) && res.status() === 200; }).then((res) => res.json());
    const unfiltered = listRead((d) => !d.includes(ENTITY));
    await p.fill('input[placeholder="for example platform_admin"]', "lanea_test");
    const before = (await unfiltered).logs ?? [];
    k.check(`${tag}: before the record filter, this run's other record is listed`, before.filter((l) => l.entity_id === OTHER).length === 2 && before.filter((l) => l.entity_id === ENTITY).length === 5, `${before.filter((l) => l.entity_id === OTHER).length} other, ${before.filter((l) => l.entity_id === ENTITY).length} this run's`);
    // the record filter: wait for the list read with it, then only this run's record is shown
    const filtered = listRead((d) => d.includes(ENTITY));
    await p.fill('input[placeholder="The record\'s id"]', ENTITY);
    const after = (await filtered).logs ?? [];
    await p.waitForSelector("text=5 entries shown");
    // and on screen: five rows of this run's record, none of the other record's
    const shown = await p.locator("tbody tr.al-row .al-action").allTextContents();
    k.check(`${tag}: person and record filters narrow the list to this run's 5 (the other record is left out)`, after.length === 5 && after.every((l) => l.entity_id === ENTITY) && !(await p.isVisible('[data-load="stale"]'))
      && shown.length === 5 && shown.every((s) => s === catalog.audit_actions["admin.updated"]) && !shown.includes(catalog.audit_actions[DECOY_ACTION]), `${after.length} rows; on screen ${shown.join(" / ")}`);
    await p.locator("tbody tr").first().locator('button:has-text("Details")').click().catch(() => {});
    await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `audit-filters-${tag}.png`), fullPage: true });
    const [dl] = await Promise.all([p.waitForEvent("download"), p.click('button:has-text("Export CSV")')]);
    const file = path.join(SHOTS, `export-${tag}.csv`);
    await dl.saveAs(file);
    k.check(`${tag}: Export CSV downloads the filtered entries`, fs.readFileSync(file, "utf8").trimEnd().split("\r\n").length === 6 && /zella-voice-audit-log-/.test(dl.suggestedFilename()), dl.suggestedFilename());
    await p.waitForSelector("text=Exported 5 entries.");
    k.check(`${tag}: no page errors`, p.errors.length === 0, p.errors.join(" | "));
    await ctx.close();
  }
  // a read only admin sees the filters but no Export button
  const ctx = await k.context(browser, 1440);
  const p = await k.page(ctx);
  await k.signIn(p, READONLY);
  await p.goto(k.APP + "/audit-logs");
  await p.waitForSelector('label:has-text("Person")');
  // a known fixture of this run is on screen: the list really loaded
  if (await p.isVisible(".al-filters-toggle")) await p.click(".al-filters-toggle");
  await p.fill('input[placeholder="The record\'s id"]', ENTITY);
  await p.waitForSelector("text=50 entries shown");
  await p.waitForSelector('.owner-page-heading button:has-text("Refresh"):not([disabled])');
  k.check("a read only admin sees no Export button", !(await p.isVisible("text=Export CSV")));
  await ctx.close();
  await browser.close();
  } finally {
    cleanUp();
  }
  console.log(k.failures() ? `${k.failures()} FAILED` : "ALL PASSED");
  process.exit(k.failures() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
