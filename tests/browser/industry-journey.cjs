// A working day in the CRM as the owner of each industry's business, in a real browser against the local stand-in
// (isolated test database, test data only, nothing sent: messages are recorded, not delivered).
// For each industry: switch on reminders / confirmations / new-lead callbacks as the owner would; add a lead through
// "Add lead"; book them through "New <appointment>"; for every industry record type add one through its form (every
// field filled, linked to the person) and move it through every status; open the person's profile; check the main
// pages at phone width; check a viewer can't change records; read the AI receptionist's instructions.
// After each step it reads what the database really holds (rows, reminders, tasks, notifications, messages,
// automation runs). Output: <OUT>/<slug>.json.   Usage: node tests/browser/industry-journey.cjs [worker] [workers]
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const APP = process.env.APP_URL ?? "http://localhost:5199", BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const OUT = process.env.OUT ?? "/tmp/industry-journey";
const PG = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", process.env.ZDB ?? "zella_ui", "-AtqX", "-c"];
const sql = (q) => execFileSync("psql", [...PG, q]).toString().trim();
const json = (q) => JSON.parse(sql(q) || "null");
const [worker = 0, workers = 1] = process.argv.slice(2).map(Number);
const RUN = (process.env.RUN ?? Date.now().toString(36).slice(-4)).replace(/[^a-z0-9]/gi, "");
const OWNER = "a0000000-0000-0000-0000-000000000002", VIEWER = "a0000000-0000-0000-0000-000000000004";

// What automations and the system produced for one business (counts per kind)
const OUTPUTS = ["appointment_reminders", "followup_tasks", "crm_tasks", "notifications", "staff_notifications", "sms_messages", "email_messages",
  "callbacks", "crm_record_events", "automation_runs", "message_drafts", "workflow_executions", "automation_events"];
const counts = (id) => json(`select json_build_object(${OUTPUTS.map((t) => `'${t}', (select count(*) from public.${t} where business_id = '${id}')`).join(", ")},
  'industry_rule_runs', (select count(*) from public.industry_automation_runs r join public.automations a on a.id = r.automation_id where a.business_id = '${id}'))`);
const delta = (a, b) => Object.fromEntries(Object.keys(b).map((k) => [k, b[k] - (a[k] ?? 0)]).filter(([, v]) => v !== 0));

async function token(email) {
  const r = await fetch(`${BACKEND}/auth/v1/token?grant_type=password`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email, password: "Test-pass-1" }) });
  return (await r.json()).access_token;
}
async function rpc(tok, fn, args) {
  const r = await fetch(`${BACKEND}/rest/v1/rpc/${fn}`, { method: "POST", headers: { authorization: `Bearer ${tok}`, "content-type": "application/json" }, body: JSON.stringify(args) });
  return { status: r.status, body: await r.text() };
}

async function settle(p) {
  const t0 = Date.now();
  while (Date.now() - t0 < 6000 && await p.evaluate(() => /Loading|Checking|Saving/.test(document.querySelector(".ba-main, main")?.innerText?.slice(0, 3000) ?? "")).catch(() => false)) await p.waitForTimeout(200);
  await p.waitForTimeout(400);
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  sql(`insert into business_members (business_id, user_id, role, status) select id, '${VIEWER}', 'viewer', 'active' from businesses where id::text like 'c0000000%' on conflict do nothing`);
  const list = sql(`select b.id || '|' || i.slug from businesses b join industries i on i.id = b.industry_id where b.id::text like 'c0000000%' order by i.slug`)
    .split("\n").map((l) => { const [id, slug] = l.split("|"); return { id, slug }; }).filter((_, i) => i % workers === worker)
    .filter((b) => !(process.env.SKIP_DONE && fs.existsSync(path.join(OUT, `${b.slug}.json`))));
  const ownerTok = await token("owner@glow.test"), viewerTok = await token("viewer@glow.test");
  const browser = await chromium.launch();

  for (const biz of list) {
    const R = { slug: biz.slug, steps: [] };
    const step = (name, ok, detail = {}) => { R.steps.push({ name, ok, ...detail }); console.log(`${ok ? "ok  " : "FAIL"} ${biz.slug}: ${name}${detail.note ? ` - ${detail.note}` : ""}`); };
    const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
    await ctx.addInitScript((id) => localStorage.setItem("zella.lastBusiness", id), biz.id);
    await ctx.route("https://zlocal.supabase.co/**", async (r) => {
      const q = r.request();
      const res = await fetch(q.url().replace("https://zlocal.supabase.co", BACKEND), { method: q.method(), headers: q.headers(), body: ["GET", "HEAD"].includes(q.method()) ? undefined : q.postDataBuffer() });
      await r.fulfill({ status: res.status, headers: Object.fromEntries(res.headers.entries()), body: Buffer.from(await res.arrayBuffer()) });
    });
    const p = await ctx.newPage();
    const errors = []; p.on("pageerror", (e) => errors.push(e.message));
    p.on("dialog", (d) => d.accept());
    await p.goto(APP + "/app");
    await p.fill('input[type="email"]', "owner@glow.test");
    if (!(await p.$('input[type="password"]'))) await p.click('button[type="submit"]');
    await p.fill('input[type="password"]', "Test-pass-1");
    await p.click('button[type="submit"]');
    await p.waitForTimeout(3000);
    const term = json(`select coalesce(c.terminology, '{}') from businesses b left join industry_configurations c on c.industry_id = b.industry_id where b.id = '${biz.id}'`);
    R.terminology = { customer: term.customer, customers: term.customers, appointment: term.appointment, staff: term.staff_plural };

    // 0. the owner switches on the everyday automations (they start paused until go-live)
    const autos = json(`select coalesce(json_agg(json_build_object('id', id, 'type', trigger_type, 'status', status)), '[]') from automations where business_id = '${biz.id}'`);
    R.automations = autos.map((a) => `${a.type}:${a.status}`);
    let switched = 0;
    for (const a of autos.filter((x) => ["appointment_reminder", "appointment_confirmation", "new_lead_callback"].includes(x.type) && x.status !== "active")) {
      const r = await rpc(ownerTok, "zella_set_automation", { p_business_id: biz.id, p_automation_id: a.id, p_enabled: true });
      if (r.status < 300) switched++; else R.automationError = r.body.slice(0, 200);
    }
    step("owner switches on reminders, confirmations and lead callbacks", !R.automationError, { note: `${switched} switched on${R.automationError ? `; ${R.automationError}` : ""}` });

    // 1. add a lead
    let before = counts(biz.id);
    // unique per run, so a re-run never finds the previous run's records under the same name
    const first = "Jamie", last = `Rivera${biz.slug.replace(/[^a-z]/g, "").slice(0, 6)}${RUN}`;
    await p.goto(APP + "/app/today"); await settle(p);
    await p.getByRole("button", { name: "Add lead" }).first().click();
    const lead = p.locator("section.ba-modal");
    await lead.getByLabel("First name").fill(first);
    await lead.getByLabel("Last name").fill(last);
    await lead.locator('input[type="tel"]').fill(`(512) 555-${String(1000 + Math.floor(Math.random() * 8999))}`);
    await lead.locator('input[type="email"]').fill(`jamie.${biz.slug}.${RUN}@example.test`);
    await lead.locator("textarea").fill("Called asking about prices and availability next week.");
    await lead.getByRole("button", { name: "Add lead" }).click();
    await p.waitForTimeout(1500);
    const cust = json(`select row_to_json(c) from (select id, first_name, last_name, lead_stage, status, assigned_to from customers where business_id = '${biz.id}' and last_name = '${last}' order by created_at desc limit 1) c`);
    let after = counts(biz.id);
    step("add a lead through Add lead", Boolean(cust), { note: cust ? `stage ${cust.lead_stage ?? "-"}, assigned ${cust.assigned_to ? "yes" : "no"}` : "not saved", produced: delta(before, after) });

    // 2. book them, where this business takes bookings (zella_capabilities); where it doesn't, there's no booking button
    //    and the server refuses one
    before = after;
    await p.goto(APP + "/app/today"); await settle(p);
    const bookLabel = new RegExp(`^New ${(term.appointment ?? "appointment").toLowerCase()}`, "i");
    const caps = json(`select public.zella_capabilities('${biz.id}')`);
    R.capabilities = Object.fromEntries(Object.entries(caps).map(([k, v]) => [k, v.state]));
    const schedulingOn = caps.scheduling?.enabled;
    if (!schedulingOn) {
      const buttons = await p.getByRole("button", { name: bookLabel }).count();
      const nav = await p.locator("#ba-sidebar").innerText();
      let refused = "";
      try { sql(`insert into appointments (business_id, title, start_time, end_time) values ('${biz.id}', 'x', now(), now() + interval '1 hour')`); } catch (e) { refused = String(e.stderr ?? e.message); }
      step("no bookings where this business doesn't take them", buttons === 0 && !/Calendar|Check-ins|Waitlist/.test(nav) && /CAPABILITY_OFF:scheduling/.test(refused),
        { note: `booking buttons ${buttons}; calendar/check-ins/waitlist in menu: ${/Calendar|Check-ins|Waitlist/.test(nav)}; server: ${refused.match(/CAPABILITY_OFF:\w+/)?.[0] ?? "accepted"}` });
    } else {
    await p.getByRole("button", { name: bookLabel }).first().click();
    const book = p.locator("section.ba-modal");
    await book.getByPlaceholder(/^Find a /).fill(last);
    await p.waitForTimeout(1200);
    await book.locator(".ba-picker button").first().click().catch(() => {});
    await book.getByLabel("Title").fill(`${term.service ?? "Service"} for ${first}`);
    const d = new Date(Date.now() + 2 * 86400000);
    await book.getByLabel("Date").fill(d.toISOString().slice(0, 10));
    await book.getByLabel("Start time").fill("10:00");
    await book.locator('button[type="submit"]').click();
    await p.waitForTimeout(1800);
    const bookErr = await book.locator(".ba-error").innerText().catch(() => "");
    const appt = json(`select row_to_json(a) from (select id, status, customer_id is not null as linked from appointments where business_id = '${biz.id}' order by created_at desc limit 1) a`);
    after = counts(biz.id);
    step(`book a ${term.appointment ?? "appointment"}`, Boolean(appt?.linked), { note: appt ? `linked to the lead: ${appt.linked}` : `not booked ${bookErr}`, produced: delta(before, after) });
    const reminders = json(`select coalesce(json_agg(kind || ' ' || hours_before || 'h ' || status), '[]') from appointment_reminders where business_id = '${biz.id}'`);
    R.reminders = reminders;
    }
    // where check-ins are off, the page isn't in the menu and the server refuses an arrival
    if (schedulingOn && !caps.checkins?.enabled) {
      const nav = await p.locator("#ba-sidebar").innerText();
      const a = sql(`select id from appointments where business_id = '${biz.id}' order by created_at desc limit 1`);
      let refused = "";
      if (a) try { sql(`select public.zella_set_attendance('${a}', 'arrived')`); } catch (e) { refused = String(e.stderr ?? e.message); }
      step("no front-desk check-ins where they don't fit", !/Check-ins/.test(nav) && (!a || /CAPABILITY_OFF:checkins/.test(refused)), { note: `in menu: ${/Check-ins/.test(nav)}; server: ${refused.match(/CAPABILITY_OFF:\w+/)?.[0] ?? (a ? "accepted" : "no booking")}` });
    }

    // 2b. the owner switches on the industry's new record types (Customize records), as they would after an update
    const offTypes = json(`select coalesce(json_agg(key), '[]') from crm_record_types where business_id = '${biz.id}' and not enabled and preset_key = public.zella_industry_key_for('${biz.id}')`);
    for (const k of offTypes) {
      const r = await rpc(ownerTok, "zella_save_record_type", { p_business_id: biz.id, p_key: k, p_patch: { enabled: true } });
      if (r.status >= 300) step(`switch on ${k}`, false, { note: r.body.slice(0, 160) });
    }
    if (offTypes.length) step("owner switches on the new record types", true, { note: offTypes.join(", ") });

    // 3. every industry record type: add one, then walk it through every status
    const types = json(`select coalesce(json_agg(json_build_object('key', key, 'singular', singular, 'plural', plural, 'fields', fields, 'statuses', statuses, 'link_person', link_person, 'title_label', title_label) order by position), '[]') from crm_record_types where business_id = '${biz.id}' and enabled`);
    R.recordTypes = [];
    for (const t of types) {
      before = counts(biz.id);
      await p.goto(APP + `/app/records/${t.key}`); await settle(p);
      const title = `${t.singular} for ${first} ${last}`;
      const m = p.locator("section.ba-modal");
      try {
        await p.getByRole("button", { name: new RegExp(`^Add ${t.singular}$`, "i") }).first().click({ timeout: 8000 });
        await m.locator("label.ba-field input").first().fill(title, { timeout: 8000 });   // the title is always the first field
      } catch (e) {
        step(`add ${t.singular}`, false, { note: `form didn't open or has no title field: ${e.message.split("\n")[0].slice(0, 120)}` });
        R.recordTypes.push({ type: t.key, label: t.plural, added: false, error: "form" });
        await p.keyboard.press("Escape").catch(() => {});
        continue;
      }
      for (const f of t.fields) {
        const esc = f.label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const box = m.locator("label.ba-field").filter({ has: p.locator("span", { hasText: new RegExp(`^${esc}$`) }) }).first();
        try {
          if (f.type === "record") await box.locator("select option").nth(1).waitFor({ state: "attached", timeout: 4000 }).catch(() => {}); // links load their choices
          if (f.sensitive) await box.locator("textarea, input").first().fill(`Private ${f.label.toLowerCase()}`);
          else if (f.type === "select" || f.type === "record") { if (await box.locator("select option").count() > 1) await box.locator("select").selectOption({ index: f.type === "record" ? (await box.locator("select option").count()) - 1 : 1 }); }
          else if (f.type === "bool") await box.locator('input[type="checkbox"]').check();
          else if (f.type === "longtext") await box.locator("textarea").fill(`Notes about ${f.label.toLowerCase()}`);
          else if (f.type === "number") await box.locator("input").fill("3");
          else if (f.type === "date") await box.locator("input").fill(new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10));
          else if (f.type === "datetime") await box.locator("input").fill(new Date(Date.now() + 3 * 86400000).toISOString().slice(0, 16));
          else await box.locator("input").fill(f.unique ? `T${Date.now() % 100000}` : `Test ${f.label}`);
        } catch { /* field shape not as expected: recorded below */ }
      }
      if (t.link_person) {
        await m.getByPlaceholder("Start typing…").fill(last);
        await p.waitForTimeout(1200);
        await m.locator(".ba-picklist button").first().click().catch(() => {});
      }
      await m.locator('button[type="submit"]').click();
      await p.waitForTimeout(1500);
      const addErr = await m.locator(".ba-error").innerText().catch(() => "");
      const rec = json(`select row_to_json(r) from (select id, status, customer_id is not null as linked, data from crm_records where business_id = '${biz.id}' and type_key = '${t.key}' and title = $t$${title}$t$ limit 1) r`);
      const secretKeys = rec ? json(`select coalesce(json_agg(field_key), '[]') from crm_record_secrets where record_id = '${rec.id}'`) : [];
      const filled = rec ? t.fields.filter((f) => (rec.data?.[f.key] !== undefined && rec.data[f.key] !== "") || secretKeys.includes(f.key)).length : 0;
      const leaked = rec ? t.fields.filter((f) => f.sensitive && rec.data?.[f.key] !== undefined).length : 0;
      if (t.fields.some((f) => f.sensitive)) step(`${t.singular}: private fields kept out of record data`, leaked === 0 && secretKeys.length > 0, { note: `${secretKeys.length} stored privately, ${leaked} in record data` });
      const tr = { type: t.key, label: t.plural, added: Boolean(rec), linked: rec?.linked ?? false, fieldsFilled: `${filled}/${t.fields.length}`, error: addErr || undefined, statuses: [] };
      step(`add ${t.singular}`, Boolean(rec), { note: rec ? `fields ${filled}/${t.fields.length}, linked ${rec.linked}` : addErr });
      // statuses, in order
      if (rec) {
        for (const s of t.statuses.slice(1)) {
          const b2 = counts(biz.id);
          await p.goto(APP + `/app/records/${t.key}`); await settle(p);
          // closed records are hidden from the default "open" list: show everything
          const all = p.locator("select").filter({ hasText: /Open|All/ }).first();
          if (await all.count()) await all.selectOption({ label: "All" }).catch(() => {});
          await p.waitForTimeout(500);
          await p.locator("tr", { hasText: title }).first().click().catch(() => {});
          const m2 = p.locator("section.ba-modal");
          const sel = m2.locator("label.ba-field").filter({ has: p.locator("span", { hasText: /^Status$/ }) }).locator("select").first();
          let picked = "";
          try { await sel.waitFor({ timeout: 4000 }); await sel.selectOption(s.key); picked = await sel.inputValue(); } catch (e) { picked = `error: ${e.message.slice(0, 80)}`; }
          if (process.env.DEBUG) console.log("   picked", s.key, "->", picked);
          await m2.locator('button[type="submit"]').click().catch(() => {});
          await p.waitForTimeout(1300);
          const now = sql(`select status from crm_records where id = '${rec.id}'`);
          tr.statuses.push({ status: s.key, ok: now === s.key, produced: delta(b2, counts(biz.id)) });
          await p.keyboard.press("Escape").catch(() => {});
        }
        const okAll = tr.statuses.every((x) => x.ok);
        step(`move ${t.singular} through ${t.statuses.length} statuses`, okAll, { note: tr.statuses.map((x) => `${x.status}${x.ok ? "" : "(FAILED)"}${Object.keys(x.produced).length ? `→${Object.entries(x.produced).map(([k, v]) => `${k}+${v}`).join(",")}` : ""}`).join(" | ") });
      }
      tr.produced = delta(before, counts(biz.id));
      R.recordTypes.push(tr);
    }

    // 3b. money: add an invoice through the Money page and record part of it as paid (nothing is charged)
    if (caps.money?.enabled) {
      await p.goto(APP + "/app/money"); await settle(p);
      try {
        await p.getByRole("button", { name: /^add$/i }).first().click({ timeout: 6000 });
        const mm = p.locator("section.ba-modal");
        await mm.locator("input[inputmode=decimal]").fill("120.50");
        await mm.locator("input").nth(1).fill(`Work for ${first} ${last}`);
        await mm.getByRole("button", { name: /^Add$/ }).click();
        await p.waitForTimeout(1500);
        await p.locator("tr", { hasText: `Work for ${first} ${last}` }).first().click();
        await p.waitForTimeout(1200);
        const dm = p.locator("section.ba-modal");
        await dm.locator("input[inputmode=decimal]").fill("20");
        await dm.getByRole("button", { name: "Record" }).click();
        await p.waitForTimeout(1500);
        await p.keyboard.press("Escape").catch(() => {});
      } catch (e) { R.moneyError = e.message.split("\n")[0].slice(0, 120); }
      const ch = json(`select row_to_json(c) from (select c.status, c.amount_minor, (public.zella_charge_balance(c.id) ->> 'balance_minor')::int as left from customer_charges c where business_id = '${biz.id}' and description = $t$Work for ${first} ${last}$t$ order by created_at desc limit 1) c`);
      step("money: invoice added and part paid", ch?.status === "partially_paid" && ch.left === 10050, { note: ch ? `${ch.status}, ${ch.left} cents left` : R.moneyError ?? "not saved" });
    }

    // 4. the person's profile shows what was done
    if (cust) {
      await p.goto(APP + "/app/customers"); await settle(p);
      await p.locator("tr", { hasText: last }).first().click().catch(() => {});
      await p.waitForTimeout(2200);
      await p.getByRole("tab", { name: /^Records/ }).click().catch(() => {});
      await p.waitForTimeout(600);
      const prof = await p.evaluate(() => [...document.querySelectorAll(".ba-main, .bp-panel, section.ba-modal")].map((e) => e.innerText).join("\n"));
      R.profile = { showsAppointment: /10:00|10 AM|10:00 AM/i.test(prof) || /appointment|booking|visit|session|reservation|consultation|service call/i.test(prof), showsRecords: types.some((t) => prof.includes(t.singular) || prof.includes(t.plural)), excerpt: prof.replace(/\s+/g, " ").slice(0, 400) };
      step("open the person's profile", true, { note: `shows the booking: ${R.profile.showsAppointment}, shows industry records: ${R.profile.showsRecords}` });
      await p.keyboard.press("Escape").catch(() => {});
    }

    // 5. a viewer cannot change records (server check, on a real record with a valid status)
    const anyRec = sql(`select id || '|' || status from crm_records where business_id = '${biz.id}' limit 1`);
    if (anyRec) {
      const [rid, st] = anyRec.split("|");
      const r = await rpc(viewerTok, "zella_set_record_status", { p_id: rid, p_status: st, p_note: "viewer attempt" });
      const okRefused = r.status >= 400 && /NOT_ALLOWED|denied|permission|role/i.test(r.body);
      step("a viewer can't change records", okRefused, { note: `${r.status} ${r.body.slice(0, 90)}` });
    }

    // 6. phone width
    await p.setViewportSize({ width: 390, height: 844 });
    const phone = [];
    for (const route of ["/app/today", "/app/customers", ...types.map((t) => `/app/records/${t.key}`)]) {
      await p.goto(APP + route); await settle(p);
      phone.push({ route, overflow: await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth) });
    }
    step("phone width: no sideways scrolling", phone.every((x) => x.overflow <= 0), { note: phone.filter((x) => x.overflow > 0).map((x) => `${x.route} +${x.overflow}px`).join(", ") });
    await p.screenshot({ path: path.join(OUT, `${biz.slug}-phone-records.png`) });

    // 7. what the AI receptionist is told
    const prompt = sql(`select public.zella_brain_prompt('${biz.id}')`);
    R.receptionist = {
      length: prompt.length,
      mentionsEmergency: /emergenc|911|urgent/i.test(prompt),
      noAdvice: /(medical|legal|financial|clinical|tax|investment) advice|not (a|give) (diagnos|advice)/i.test(prompt),
      identity: /verify|identity|confirm (the|their) (name|identity)/i.test(prompt),
      industryWords: [term.customers, term.appointments, term.services].filter((w) => w && prompt.toLowerCase().includes(String(w).toLowerCase())),
    };
    step("AI receptionist instructions read", prompt.length > 0, { note: `${prompt.length} chars; emergency ${R.receptionist.mentionsEmergency}, no-advice line ${R.receptionist.noAdvice}, identity check ${R.receptionist.identity}` });

    R.pageErrors = [...new Set(errors)].slice(0, 5);
    fs.writeFileSync(path.join(OUT, `${biz.slug}.json`), JSON.stringify(R, null, 1));
    await ctx.close();
  }
  await browser.close();
})();
