// The launch checks for every one of the 28 industries, data-driven from what each business is configured to offer
// (its capabilities, record types and message policy). Runs on an ISOLATED copy of the staging database
// (tests/staging/run.sh builds zstg: one active business per industry with an owner, admin, manager, staff member and
// viewer, customers, appointments, calls and every preset record type filled). Nothing is sent: the shipped n8n SMS
// code runs against a provider stand-in.
//
// Per industry:
//   intake       the AI receptionist saves a new caller as a lead and links the live call
//   scheduling   where the business takes bookings: real free times, read-back required, booked, no double booking,
//                rescheduled and cancelled by the caller; where it doesn't (e-commerce): refused by the AI and by the
//                database
//   records      for every enabled record type: staff create and move it on; a status that doesn't exist is refused;
//                the viewer reads but can't write; someone from another business can neither read nor write
//   private      private values (codes, member IDs ...): managers read them, the viewer and other businesses can't
//   today        staff and viewer see Today; another business can't
//   money        staff raise an invoice; only managers record payments; staff can't refund; viewer can't raise one
//   messages     a completed visit queues or holds the feedback request exactly as the industry's policy says
//   recovery     a provider failure is retried, then stops; it shows in "Sending failed"; the owner retries it (staff,
//                viewer and other businesses can't) and it is then sent
// Usage: node tests/workflows/industry_matrix.mjs [slug ...]     (needs zstg; writes tests/workflows/out/matrix.json)
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { runCode } from "../../n8n/src/load.mjs";

const H = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres"];
const DB = "zwf_matrix";
// Match the shell runners: clear redirects in this process as well as in the guard.
for (const key of ["PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE", "PGHOST", "PGPORT", "PGDATABASE"]) delete process.env[key];
execFileSync("bash", ["-c", 'source "$1"; zella_require_isolated "$2" "$3" "$4"',
  "isolated-guard", fileURLToPath(new URL("../lib/isolated_guard.sh", import.meta.url)), H[1], H[3], DB], { stdio: "inherit" });
const psql = (args, input) => execFileSync("psql", [...H, ...args], { input, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
const q = (sql) => psql(["-d", DB, "-qtAX", "-v", "ON_ERROR_STOP=1"], sql).trim();
const j = (sql) => { const t = q(sql); return t ? JSON.parse(t) : null; };
const lit = (v) => v === null || v === undefined ? "null" : typeof v === "object" ? `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`
  : typeof v === "boolean" || typeof v === "number" ? String(v) : `'${String(v).replace(/'/g, "''")}'`;
const rpc = (fn, args) => j(`select to_jsonb(public.${fn}(${Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(", ")}))`);
const as = (user, sql) => q(`begin; set local role authenticated; select set_config('request.jwt.claims', ${lit(JSON.stringify({ sub: user, role: "authenticated", aal: "aal1" }))}, true) \\g /dev/null
${sql}; commit;`);
const tryAs = (user, sql) => { try { return { ok: true, out: as(user, sql) }; } catch (e) { return { ok: false, out: String(e.stderr ?? e.message) }; } };
const refused = (r) => !r.ok && /NOT_ALLOWED|permission denied|row-level security|VIEW_ONLY|insufficient/i.test(r.out);

const results = {}; let fails = 0, passes = 0, current = "";
const ok = (stage, what, cond, detail = "") => {
  (results[current] ??= []).push({ stage, what, pass: Boolean(cond), detail: cond ? undefined : String(detail).slice(0, 200) });
  if (cond) passes++; else { fails++; console.log(`FAIL [${current}] [${stage}] ${what}${detail ? ` - ${String(detail).slice(0, 200)}` : ""}`); }
};

// ---------- the shipped SMS pipeline (n8n Code-node logic) with a provider stand-in ----------
const TASKS = { plan: "sms-task-plan.js", decide: "sms-task-decide.js", afterLog: "sms-task-after-log.js", afterSend: "sms-task-after-send.js" };
function sendTasks(provider) {
  const out = [];
  for (let batch = 0, items; batch < 20 && (items = j(`select public.zella_claim_followup_texts(25)`) ?? []).length; batch++) for (const item of items) {
    const finish = (f) => { rpc(f.rpc, f.body); out.push({ id: item.task_id, finish: f }); };
    const plan = runCode(TASKS.plan, { json: item }).json;
    if (plan.finish) { finish(plan.finish); continue; }
    const prepared = rpc("zella_prepare_sms", plan.prepare);
    const decide = runCode(TASKS.decide, { json: { statusCode: 200, body: prepared }, nodes: { Plan: plan } }).json;
    if (decide.finish) { finish(decide.finish); continue; }
    const logged = rpc("zella_log_outbound_sms", decide.log);
    const afterLog = runCode(TASKS.afterLog, { json: { statusCode: 200, body: logged }, nodes: { Decide: decide } }).json;
    if (afterLog.finish) { finish(afterLog.finish); continue; }
    const after = runCode(TASKS.afterSend, { json: provider(item), nodes: { "After log": afterLog } }).json;
    rpc("zella_update_outbound_sms", after.update);
    finish(after.finish);
  }
  return out;
}

// ---------- set up ----------
psql(["-qX", "-d", "postgres", "-c", `drop database if exists ${DB}`, "-c", `create database ${DB} template zstg`]);
const TZ = ["America/New_York", "America/Los_Angeles", "Europe/London", "Asia/Kolkata", "Australia/Sydney", "Pacific/Auckland", "America/Sao_Paulo", "Asia/Tokyo"]
  .map((tz) => [tz, Number(new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", hourCycle: "h23" }).format(new Date()))])
  .sort((a, b) => Math.abs(a[1] - 13) - Math.abs(b[1] - 13))[0][0];
q(`update public.businesses set timezone = '${TZ}' where name like 'Staging %'`); // follow-ups wait for 09-19 business time
q(`insert into public.platform_settings (key, value) values ('sms_live', 'true'::jsonb), ('sms_from_number', '"+15550001111"'::jsonb)
   on conflict (key) do update set value = excluded.value`); // this isolated copy only
const slugs = process.argv.slice(2).length ? process.argv.slice(2) : q(`select string_agg(slug, ' ' order by slug) from public.industries`).split(" ");
const uid = (slug, role) => q(`select md5('stg-s-${slug}-${role}')::uuid`);
const day = q(`select to_char(current_date + 4, 'YYYY-MM-DD')`);

for (const [n, slug] of slugs.entries()) {
  current = slug;
  const B = q(`select md5('stg-s-${slug}')::uuid`);
  const U = Object.fromEntries(["owner", "admin", "manager", "staff", "viewer"].map((r) => [r, uid(slug, r)]));
  const OUT = uid(slugs[(n + 1) % slugs.length] === slug ? "other" : slugs[(n + 1) % slugs.length], "owner"); // owner of another business
  const caps = JSON.parse(as(U.owner, `select public.zella_capabilities('${B}')`));
  const on = (k) => caps[k]?.state === "on";
  const policy = j(`select public.zella_message_policy_for('${B}')`);
  q(`insert into public.staff_members (business_id, name, is_active) values ('${B}', 'Alex', true)`);
  const tool = (name, args, call) => rpc("zella_ai_tool", { p_provider_call_id: call, p_business_id: B, p_tool: name, p_args: args });

  // intake
  const call1 = `m-${slug}-1`, phone = `+1512555${String(1000 + n).padStart(4, "0")}`;
  q(`insert into public.calls (business_id, direction, status, from_number, external_call_id, ai_handled, started_at) values ('${B}', 'inbound', 'answered', '${phone}', '${call1}', true, now())`);
  let r = tool("update_caller", { first_name: "Casey", last_name: "Matrix", preferred_contact_method: "text" }, call1);
  const cust = j(`select row_to_json(c) from (select id, source, lead_stage from public.customers where business_id = '${B}' and phone = '${phone}') c`);
  ok("intake", "AI saves a new caller as a lead", r?.status === "saved" && cust?.source === "phone_call", JSON.stringify(r));
  ok("intake", "the live call is linked to them", q(`select customer_id from public.calls where external_call_id = '${call1}'`) === cust?.id);

  // scheduling
  if (on("scheduling")) {
    r = tool("check_availability", { date: day, duration_minutes: 60 }, call1);
    const slot = r?.slots?.[0]?.start;
    ok("scheduling", "real free times offered", Boolean(slot), JSON.stringify(r).slice(0, 150));
    r = tool("book_appointment", { start: slot, first_name: "Casey", title: "Visit", duration_minutes: 60 }, call1);
    ok("scheduling", "booking needs the read-back first", r?.status === "need_confirmation", r?.status);
    r = tool("book_appointment", { start: slot, first_name: "Casey", title: "Visit", duration_minutes: 60, confirmed: true }, call1);
    const appt = r?.appointment_id;
    ok("scheduling", "booked after the caller confirms", r?.status === "booked" && appt, JSON.stringify(r).slice(0, 150));
    const call2 = `m-${slug}-2`;
    q(`insert into public.calls (business_id, direction, status, from_number, external_call_id, ai_handled, started_at) values ('${B}', 'inbound', 'answered', '+15125559${String(100 + n).padStart(3, "0")}', '${call2}', true, now())`);
    r = tool("book_appointment", { start: slot, first_name: "Other", title: "Visit", duration_minutes: 60, confirmed: true }, call2);
    ok("scheduling", "the same time is refused for someone else", r?.status !== "booked", r?.status);
    r = tool("find_my_appointments", {}, call1);
    ok("scheduling", "the caller's booking is found", JSON.stringify(r).includes(appt ?? "none") || (r?.appointments ?? []).length > 0, JSON.stringify(r).slice(0, 150));
    const later = tool("check_availability", { date: q(`select to_char(current_date + 5, 'YYYY-MM-DD')`), duration_minutes: 60 }, call1)?.slots?.[0]?.start;
    r = tool("reschedule_appointment", { appointment_id: appt, new_start: later, start: later, confirmed: true }, call1);
    ok("scheduling", "rescheduled by the caller", q(`select (start_time = ${lit(later)}::timestamptz)::text from public.appointments where id = '${appt}'`) === "true", JSON.stringify(r).slice(0, 150));
    r = tool("cancel_appointment", { appointment_id: appt, confirmed: true }, call1);
    ok("scheduling", "cancelled by the caller; reminders withdrawn", q(`select status from public.appointments where id = '${appt}'`) === "cancelled"
      && q(`select count(*) from public.appointment_reminders where appointment_id = '${appt}' and status = 'pending'`) === "0", JSON.stringify(r).slice(0, 150));
  } else {
    r = tool("check_availability", { date: day, duration_minutes: 60 }, call1);
    ok("scheduling", "no bookings here: the AI doesn't offer times", r?.status === "not_available" && !(r?.slots ?? []).length, JSON.stringify(r).slice(0, 150));
    r = tool("book_appointment", { start: q(`select (current_date + 4 + time '15:00')::timestamptz::text`), first_name: "Casey", title: "Visit", duration_minutes: 60, confirmed: true }, call1);
    ok("scheduling", "no bookings here: the AI can't book, and says to take a message", r?.status === "not_available", JSON.stringify(r).slice(0, 150));
    ok("scheduling", "no bookings here: booking tools are left out of the assistant's list",
      !JSON.stringify(j(`select public.zella_brain_context('${B}') -> 'tools'`)).includes("book_appointment"));
    const ins = tryAs(U.manager, `insert into public.appointments (business_id, customer_id, title, start_time, end_time) values ('${B}', '${cust?.id}', 'x', now() + interval '3 days', now() + interval '3 days 1 hour')`);
    ok("scheduling", "no bookings here: the database refuses new ones", !ins.ok, ins.out.slice(0, 120));
  }

  // records: every enabled type
  // every type in the industry's preset, as a new business gets them (the owner switches on any that are off)
  for (const k of (q(`select coalesce(string_agg(key, ' '), '') from public.crm_record_types where business_id = '${B}' and not enabled`) || "").split(" ").filter(Boolean))
    ok("records", `${k}: owner switches the type on`, tryAs(U.owner, `select public.zella_save_record_type('${B}', '${k}', '{"enabled": true}')`).ok);
  const types = j(`select coalesce(json_agg(json_build_object('key', key, 'statuses', statuses, 'fields', fields) order by position), '[]') from public.crm_record_types where business_id = '${B}' and enabled`);
  // required fields filled the way the form would (a sample value of the field's type)
  const sample = (f, n = 1) => ({ number: 3, bool: true, date: q(`select (current_date + 10)::text`), datetime: q(`select (now() + interval '10 days')::text`),
    select: f.options?.[0]?.key ?? f.options?.[0], email: "matrix@example.test", phone: "+15555550111",
    record: f.type === "record" ? q(`select id from public.crm_records where business_id = '${B}' and type_key = '${f.target}' and archived_at is null and closed_at is null limit 1`) : null })[f.type] ?? `Matrix ${f.label} ${slug} ${n}`;
  const fill = (t, n) => lit(Object.fromEntries((t.fields ?? []).filter((f) => f.required).map((f) => [f.key, sample(f, n)])));
  // records that others must link to (a class before its bookings) first
  types.sort((a, b) => (a.fields ?? []).filter((f) => f.required && f.type === "record").length - (b.fields ?? []).filter((f) => f.required && f.type === "record").length);
  for (const t of types) {
    const st = t.statuses.map((s) => s.key);
    const made = tryAs(U.staff, `select public.zella_save_record('${B}', '${t.key}', null, 'Matrix ${t.key}', null, ${cust?.id ? `'${cust.id}'` : "null"}, '${U.staff}', null, ${fill(t, 1)})`);
    const id = made.ok ? JSON.parse(made.out).id : null;
    ok("records", `${t.key}: staff create`, Boolean(id), made.out.slice(0, 150));
    if (!id) continue;
    // the status checks use a second one, so the first stays open for records that link to it (a class's bookings)
    const id2 = JSON.parse(as(U.staff, `select public.zella_save_record('${B}', '${t.key}', null, 'Matrix ${t.key} 2', null, ${cust?.id ? `'${cust.id}'` : "null"}, '${U.staff}', null, ${fill(t, 2)})`)).id;
    const uniq = (t.fields ?? []).find((f) => f.unique && !["record", "select", "bool", "number"].includes(f.type));
    if (uniq) {
      const withValue = (n) => lit({ ...JSON.parse(fill(t, n).replace(/^'|'::jsonb$/g, "").replace(/''/g, "'")), [uniq.key]: `Matrix unique ${slug}` });
      const first = tryAs(U.staff, `select public.zella_save_record('${B}', '${t.key}', null, 'Matrix unique 1', null, null, null, null, ${withValue(4)})`);
      const dupe = tryAs(U.staff, `select public.zella_save_record('${B}', '${t.key}', null, 'Matrix unique 2', null, null, null, null, ${withValue(5)})`);
      ok("records", `${t.key}: the first record with a ${uniq.label} is saved`, first.ok, first.out.slice(0, 100));
      ok("records", `${t.key}: a second record with the same ${uniq.label} is refused as a duplicate`, !dupe.ok && /DUPLICATE/.test(dupe.out), dupe.out.slice(0, 100));
    }
    if (st.length > 1) ok("records", `${t.key}: staff move it on`, tryAs(U.staff, `select public.zella_set_record_status('${id2}', '${st[1]}', null)`).ok);
    ok("records", `${t.key}: a status that doesn't exist is refused`, !tryAs(U.staff, `select public.zella_set_record_status('${id}', 'no_such_status', null)`).ok);
    ok("records", `${t.key}: viewer reads`, as(U.viewer, `select count(*) from public.crm_records where id = '${id}'`) === "1");
    ok("records", `${t.key}: viewer can't write`, refused(tryAs(U.viewer, `select public.zella_save_record('${B}', '${t.key}', null, 'v', null, null, null, null, '{}')`))
      && refused(tryAs(U.viewer, `select public.zella_set_record_status('${id}', '${st[0]}', null)`)));
    ok("records", `${t.key}: another business can't read or write`, as(OUT, `select count(*) from public.crm_records where id = '${id}'`) === "0"
      && refused(tryAs(OUT, `select public.zella_save_record('${B}', '${t.key}', null, 'x', null, null, null, null, '{}')`))
      && !tryAs(OUT, `select public.zella_set_record_status('${id}', '${st[0]}', null)`).ok);
  }

  // private values
  const secretRec = q(`select s.record_id from public.crm_record_secrets s join public.crm_records r on r.id = s.record_id where r.business_id = '${B}' limit 1`);
  if (secretRec) {
    const mgr = tryAs(U.manager, `select public.zella_record_secrets('${secretRec}')`);
    ok("private", "managers read private values", mgr.ok && mgr.out.length > 2, mgr.out.slice(0, 100));
    const secret = q(`select value from public.crm_record_secrets where record_id = '${secretRec}' limit 1`);
    ok("private", "managers see the actual value", mgr.out.includes(JSON.parse(JSON.stringify(secret))));
    const v = tryAs(U.viewer, `select public.zella_record_secrets('${secretRec}')`), o = tryAs(OUT, `select public.zella_record_secrets('${secretRec}')`);
    ok("private", "the viewer and other businesses never get the value (at most that a private field exists)",
      !v.out.includes(secret) && !o.out.includes(secret) && (!v.ok || JSON.parse(v.out).allowed === false) && !o.ok, `${v.out.slice(0, 60)} | ${o.out.slice(0, 60)}`);
    ok("private", "nor does the viewer find it in the record's data", !as(U.viewer, `select data::text from public.crm_records where id = '${secretRec}'`).includes(secret));
  }

  // today
  ok("today", "staff and viewer see Today", tryAs(U.staff, `select public.zella_today_operations('${B}')`).ok && tryAs(U.viewer, `select public.zella_today_operations('${B}')`).ok);
  ok("today", "another business can't", !tryAs(OUT, `select public.zella_today_operations('${B}')`).ok);

  // money
  if (on("money") && cust?.id) {
    const inv = tryAs(U.staff, `select public.zella_create_charge('${B}', 'invoice', 5000, 'Matrix', '${cust.id}', null, null, null, null, 'mx-${slug}')`);
    const invId = inv.ok ? JSON.parse(inv.out).id : null;
    ok("money", "staff raise an invoice", Boolean(invId), inv.out.slice(0, 120));
    if (invId) {
      ok("money", "staff can't record a payment or refund", refused(tryAs(U.staff, `select public.zella_record_charge_payment('${invId}', 'payment', 5000, 'cash')`))
        && refused(tryAs(U.staff, `select public.zella_record_charge_payment('${invId}', 'refund', 100, 'cash')`)));
      ok("money", "a manager records the payment", tryAs(U.manager, `select public.zella_record_charge_payment('${invId}', 'payment', 5000, 'cash', null, 'mxp-${slug}')`).ok
        && q(`select status from public.customer_charges where id = '${invId}'`) === "paid");
      ok("money", "a repeated payment is not counted twice", tryAs(U.manager, `select public.zella_record_charge_payment('${invId}', 'payment', 5000, 'cash', null, 'mxp-${slug}')`).ok
        && q(`select count(*) from public.customer_charge_payments where charge_id = '${invId}'`) === "1");
    }
    ok("money", "viewer can't raise one", refused(tryAs(U.viewer, `select public.zella_create_charge('${B}', 'invoice', 100, 'v', '${cust.id}')`)));
    ok("money", "another business can't", refused(tryAs(OUT, `select public.zella_create_charge('${B}', 'invoice', 100, 'v', '${cust.id}')`)));
  }

  // messages: a completed visit follows the industry's policy
  const c3 = q(`select md5('stg-s-${slug}-c3')::uuid`);
  if (on("scheduling")) {
  const visit = q(`insert into public.appointments (business_id, customer_id, title, status, start_time, end_time) values ('${B}', '${c3}', 'Matrix visit', 'scheduled', now() - interval '2 hours', now() - interval '1 hour') returning id`);
  q(`update public.appointments set status = 'completed' where id = '${visit}'`);
  const fb = q(`select status || ':' || coalesce(outcome, '') from public.followup_tasks where appointment_id = '${visit}' and kind = 'feedback_request'`);
  ok("messages", `feedback request ${policy.feedback_request === "off" ? "held back (policy off)" : "queued"}`,
    policy.feedback_request === "off" ? fb === "skipped:policy" : fb === "pending:", fb || "(none)");
  }

  // recovery: a provider failure, retries, Sending failed, owner retry
  const task = q(`insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, vars)
                  values ('${B}', '${c3}', 'service_due', 'sms', now() - interval '1 minute', 2, '{"service": "visit"}') returning id`);
  q(`update public.followup_tasks set due_at = now() + interval '1 day' where status = 'pending' and id <> '${task}'`); // only this one is due
  const fail = () => ({ statusCode: 422, body: { errors: [{ code: "40310" }] } });
  sendTasks(fail);
  ok("recovery", "first provider failure: retried later", q(`select status || ':' || (due_at > now())::text from public.followup_tasks where id = '${task}'`) === "pending:true");
  q(`update public.followup_tasks set due_at = now() - interval '1 minute' where id = '${task}'`);
  sendTasks(fail);
  ok("recovery", "after the last attempt it stops", q(`select status from public.followup_tasks where id = '${task}'`) === "failed");
  ok("recovery", "the owner sees it under Sending failed", (JSON.parse(as(U.owner, `select public.zella_failed_work('${B}')`))?.tasks ?? []).some((t) => t.id === task));
  ok("recovery", "staff, viewer and other businesses can't retry", [U.staff, U.viewer, OUT].every((u) => !tryAs(u, `select public.zella_retry_failed('${B}', 'task', '${task}')`).ok));
  ok("recovery", "the owner retries it", tryAs(U.owner, `select public.zella_retry_failed('${B}', 'task', '${task}')`).out === "queued");
  q(`update public.followup_tasks set due_at = now() - interval '1 minute' where id = '${task}'`);
  let k = 0;
  sendTasks(() => ({ statusCode: 200, body: { data: { id: `mx-${slug}-${++k}` } } }));
  ok("recovery", "then it is sent", q(`select status from public.followup_tasks where id = '${task}'`) === "done", q(`select status || ' ' || coalesce(outcome, '') from public.followup_tasks where id = '${task}'`));
  console.log(`${slug}: ${results[slug].filter((x) => x.pass).length}/${results[slug].length}`);
}

mkdirSync(new URL("./out/", import.meta.url), { recursive: true });
writeFileSync(new URL("./out/matrix.json", import.meta.url), JSON.stringify(results, null, 1));
console.log(fails ? `\nINDUSTRY MATRIX: ${passes} passed, ${fails} FAILED` : `\nINDUSTRY MATRIX: ALL ${passes} PASSED`);
process.exit(fails ? 1 : 0);
