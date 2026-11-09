// The launch workflow, end to end, for a beauty salon (production's first business is a salon in testing).
// Runs on an ISOLATED copy of the staging database (tests/staging/run.sh builds zstg). Nothing is sent: the n8n sending
// pipelines run with their shipped Code-node logic (n8n/src), and the SMS provider is replaced by a stand-in.
//
//   intake       a caller reaches the AI receptionist: recognised or not, name and "text me" saved, lead created and
//                assigned, the live call linked to them
//   scheduling   real free times; read-back required; booked with the stylist; the same time refused for someone else;
//                reminders scheduled; the team told; a deposit asked for (recorded, not charged)
//   update       the confirmation goes through the SMS pipeline exactly as production runs it today (texting off: the
//                exact text is recorded as a dry run), then with texting on against a provider stand-in
//   staff action arrival, in service, completed (as staff, through their own permissions); colour card saved; deposit and
//                balance recorded as paid by a manager
//   completion   thank-you and rebooking reminders queued and rendered; nothing left open
//   recovery     a provider failure lands in "Sending failed" and is retried; an opted-out customer is never texted
//                (skipped with a reason); a caller who hangs up mid-booking gets a callback assigned
//   audit        AI tool log, record history, money audit, appointment history
// Usage: node tests/workflows/salon_launch.mjs        (needs the staging database zstg)
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { runCode } from "../../n8n/src/load.mjs";

const H = ["-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres"];
const DB = "zwf_salon";
const psql = (args, input) => execFileSync("psql", [...H, ...args], { input, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
const q = (sql) => psql(["-d", DB, "-qtAX", "-v", "ON_ERROR_STOP=1"], sql).trim();
const j = (sql) => { const t = q(sql); return t ? JSON.parse(t) : null; };
const lit = (v) => v === null || v === undefined ? "null" : typeof v === "object" ? `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`
  : typeof v === "boolean" || typeof v === "number" ? String(v) : `'${String(v).replace(/'/g, "''")}'`;
const rpc = (fn, args) => j(`select to_jsonb(public.${fn}(${Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(", ")}))`);
// as a signed-in member, through row security
const as = (user, sql) => q(`begin; set local role authenticated; select set_config('request.jwt.claims', ${lit(JSON.stringify({ sub: user, role: "authenticated", aal: "aal1" }))}, true) \\g /dev/null
${sql}; commit;`);

let fails = 0;
const ok = (stage, what, cond, detail = "") => { console.log(`${cond ? "PASS" : "FAIL"} [${stage}] ${what}${detail ? ` - ${detail}` : ""}`); if (!cond) fails++; };
const messages = [];

// ---------- set up: a copy of staging, configured like production's salon ----------
psql(["-qX", "-d", "postgres", "-c", `drop database if exists ${DB}`, "-c", `create database ${DB} template zstg`]);
for (const m of ["zella_ai_caller_fixes", "zella_message_courtesy"]) q(readFileSync(new URL(`../../sql/${m}.sql`, import.meta.url), "utf8"));
const B = q(`select md5('stg-s-beauty-salon')::uuid`);
// texts after a visit respect quiet hours; give the salon a time zone where it is midday now, so they are due during the run
const TZ = ["America/New_York", "America/Los_Angeles", "Europe/London", "Asia/Kolkata", "Australia/Sydney", "Pacific/Auckland", "America/Sao_Paulo", "Asia/Tokyo"]
  .map((tz) => [tz, Number(new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", hourCycle: "h23" }).format(new Date()))])
  .sort((a, b) => Math.abs(a[1] - 13) - Math.abs(b[1] - 13))[0][0];
q(`update public.businesses set timezone = '${TZ}' where id = '${B}'`);
const OWNER = q(`select md5('stg-s-beauty-salon-owner')::uuid`), MANAGER = q(`select md5('stg-s-beauty-salon-manager')::uuid`), STAFF = q(`select md5('stg-s-beauty-salon-staff')::uuid`);
q(`insert into public.profiles (id, first_name) select u.id, split_part(u.email, '@', 1) from auth.users u where u.email like '%@staging.test' on conflict (id) do nothing`);
q(`insert into public.staff_members (business_id, name, is_active) values ('${B}', 'Rosa', true)`);
q(`select set_config('request.jwt.claims', ${lit(JSON.stringify({ sub: OWNER, role: "authenticated" }))}, false); select public.zella_apply_industry_defaults('${B}')`);
// production's salon (5 Nov): confirmations and reminders on; missed-call, new-lead, no-show and after-visit follow-ups paused
q(`update public.automations set status = case when trigger_type in ('appointment_confirmation', 'appointment_reminder') then 'active'
     when trigger_type in ('missed_call_follow_up', 'new_lead_callback', 'no_show_follow_up', 'post_appointment_follow_up') then 'paused' else status end where business_id = '${B}'`);
q(`insert into public.calls (business_id, direction, status, from_number, external_call_id, ai_handled, started_at) values ('${B}', 'inbound', 'answered', '+15125550777', 'launch-call-1', true, now())`);
const tool = (name, args, call = "launch-call-1") => rpc("zella_ai_tool", { p_provider_call_id: call, p_business_id: B, p_tool: name, p_args: args });

// ---------- 1. intake ----------
let r = tool("lookup_caller", {});
ok("intake", "a new caller isn't guessed", r.status === "not_recognised");
r = tool("update_caller", { first_name: "Maria", last_name: "Lopez", preferred_contact_method: "text" });
ok("intake", "the AI saves the caller", r.status === "saved");
const cust = j(`select row_to_json(c) from (select id, first_name, source, lead_stage, assigned_to, preferred_contact_method pref, preferred_channel channel from public.customers where business_id = '${B}' and phone = '+15125550777') c`);
ok("intake", "lead created from the call, new stage", cust?.source === "phone_call" && cust?.lead_stage === "new");
ok("intake", "lead assigned to someone on the team", Boolean(cust?.assigned_to));
ok("intake", "\"text me\" is saved and used for messages", cust?.pref === "sms" && cust?.channel === "sms", `${cust?.pref}/${cust?.channel}`);
ok("intake", "the live call is linked to the caller", q(`select customer_id from public.calls where external_call_id = 'launch-call-1'`) === cust?.id);
ok("intake", "the team is told about the new lead", Number(q(`select count(*) from public.staff_notifications where business_id = '${B}' and title ilike '%lead%' and created_at > now() - interval '5 minutes'`)) > 0);
r = tool("lookup_caller", {});
ok("intake", "next time the caller is recognised by first name only", r.status === "recognised" && r.first_name === "Maria" && !("phone" in r));

// ---------- 2. scheduling ----------
const day = q(`select to_char(current_date + 4, 'YYYY-MM-DD')`);
r = tool("check_availability", { date: day, duration_minutes: 90 });
ok("schedule", "real free times offered", r.status !== undefined && (r.slots ?? []).length > 0, `${(r.slots ?? []).length} times`);
const slot = r.slots?.[1]?.start;
r = tool("book_appointment", { start: slot, first_name: "Maria", title: "Colour and cut", duration_minutes: 90 });
ok("schedule", "booking needs the read-back first", r.status === "need_confirmation");
r = tool("book_appointment", { start: slot, first_name: "Maria", title: "Colour and cut", duration_minutes: 90, confirmed: true });
ok("schedule", "booked after the caller confirms", r.status === "booked", r.say);
const apptId = r.appointment_id;
const again = tool("book_appointment", { start: slot, first_name: "Maria", title: "Colour and cut", duration_minutes: 90, confirmed: true });
ok("schedule", "a repeated request doesn't book twice", again.repeated === true && again.appointment_id === apptId);
const appt = j(`select row_to_json(a) from (select status, booking_state, staff_id, customer_id from public.appointments where id = '${apptId}') a`);
ok("schedule", "booked for Maria with the stylist", appt.customer_id === cust.id && Boolean(appt.staff_id) && appt.booking_state === "confirmed");
q(`insert into public.calls (business_id, direction, status, from_number, external_call_id, ai_handled, started_at) values ('${B}', 'inbound', 'answered', '+15125550888', 'launch-call-2', true, now())`);
r = tool("book_appointment", { start: slot, first_name: "Other", title: "Cut", duration_minutes: 90, confirmed: true }, "launch-call-2");
ok("schedule", "the same time is refused for another caller, with real alternatives", r.status === "unavailable" && (r.slots ?? []).length > 0);
const rem = j(`select json_agg(kind || ':' || coalesce(hours_before::text, '0') order by due_at) from public.appointment_reminders where appointment_id = '${apptId}' and status = 'pending'`);
ok("schedule", "confirmation now, reminders 24 h and 2 h before", JSON.stringify(rem) === JSON.stringify(["confirmation:0", "reminder:24", "reminder:2"]), JSON.stringify(rem));
ok("schedule", "the team is told about the booking", Number(q(`select count(*) from public.staff_notifications where business_id = '${B}' and title ilike '%appointment%' and created_at > now() - interval '5 minutes'`)) > 0);
const deposit = JSON.parse(as(STAFF, `select public.zella_create_charge('${B}', 'deposit', 2500, 'Colour deposit', '${cust.id}', null, '${apptId}', null, null, 'dep-${apptId}')`));
const tasks = j(`select json_object_agg(kind, status || coalesce(':' || outcome, '')) from public.followup_tasks where customer_id = '${cust.id}'`) ?? {};
ok("schedule", "one booking message: no repeat \"you are booked\" text (held back by the salon policy, visible as skipped)", !("booking_follow_up" in tasks) || tasks.booking_follow_up === "skipped:policy", JSON.stringify(tasks));
ok("schedule", "the welcome text gives way to the booking confirmation (closed with the reason)", tasks.welcome_new_customer === "skipped:superseded", tasks.welcome_new_customer);
ok("schedule", "a deposit is asked for (recorded, not charged)", q(`select status from public.customer_charges where id = '${deposit.id}'`) === "open");

// ---------- 3. customer update: the shipped SMS pipeline ----------
// like the n8n schedule running again and again: claim batches until nothing is due (other synthetic businesses queue too)
function smsPipeline(claimSql, files, provider) {
  const out = [];
  // a batch can come back empty while texts are still due: tasks outside their business's sending hours are moved on
  const due = () => Number(q(claimSql.includes("reminders") ? `select count(*) from public.appointment_reminders where status = 'pending' and due_at <= now()`
    : `select count(*) from public.followup_tasks where status = 'pending' and channel = 'sms' and due_at <= now()`));
  for (let batch = 0, items; batch < 60 && ((items = j(claimSql) ?? []).length || due() > 0); batch++) for (const item of items) {
    const id = item.reminder_id ?? item.task_id;
    const finish = (f) => { rpc(f.rpc, f.body); out.push({ id, kind: item.kind, finish: f }); };
    const plan = runCode(files.plan, { json: item }).json;
    if (plan.finish) { finish(plan.finish); continue; }
    const prepared = rpc("zella_prepare_sms", plan.prepare);
    const decide = runCode(files.decide, { json: { statusCode: 200, body: prepared }, nodes: { Plan: plan } }).json;
    if (decide.finish) { finish(decide.finish); continue; }
    const logged = rpc("zella_log_outbound_sms", decide.log);
    const afterLog = runCode(files.afterLog, { json: { statusCode: 200, body: logged }, nodes: { Decide: decide } }).json;
    const msg = { kind: item.kind, customer: item.customer?.id, to: decide.to, text: decide.text, live: decide.live, result: decide.live ? "pending" : "dry run" };
    messages.push(msg);
    if (afterLog.finish) { finish(afterLog.finish); continue; }
    const answer = provider(afterLog.telnyx, item);
    const after = runCode(files.afterSend, { json: answer, nodes: { "After log": afterLog } }).json;
    msg.result = after.update.p_status;
    rpc("zella_update_outbound_sms", after.update);
    finish(after.finish);
  }
  return out;
}
const REMINDERS = { plan: "sms-plan.js", decide: "sms-decide.js", afterLog: "sms-after-log.js", afterSend: "sms-after-send.js" };
const TASKS = { plan: "sms-task-plan.js", decide: "sms-task-decide.js", afterLog: "sms-task-after-log.js", afterSend: "sms-task-after-send.js" };
const noProvider = () => { throw new Error("nothing may be sent in a dry run"); };

// today in production: texting is off
let run = smsPipeline(`select public.zella_claim_reminders(25, 'sms')`, REMINDERS, noProvider);
const conf = messages.find((m) => m.kind === "confirmation");
ok("update", "texting off (as in production): the confirmation is written exactly and recorded, not sent", Boolean(conf) && conf.live === false
  && /Maria/.test(conf.text) && /Staging beauty-salon/.test(conf.text) && /Colour and cut/.test(conf.text), conf?.text);
ok("update", "the dry run is visible: message logged as dry_run, reminder closed with the reason", q(`select status from public.sms_messages where business_id = '${B}' and message_body = ${lit(conf?.text ?? "")} limit 1`) === "dry_run"
  && q(`select status || ':' || coalesce(error, '') from public.appointment_reminders where appointment_id = '${apptId}' and kind = 'confirmation'`).startsWith("skipped:dry_run"));
ok("update", "the 24 h and 2 h reminders wait for their time", Number(q(`select count(*) from public.appointment_reminders where appointment_id = '${apptId}' and kind = 'reminder' and status = 'pending'`)) === 2);

// texting on, in this isolated copy only, with a provider stand-in: one accepted, one refused
q(`insert into public.platform_settings (key, value) values ('sms_live', 'true'::jsonb), ('sms_from_number', '"+15550001111"'::jsonb)
   on conflict (key) do update set value = excluded.value`);
q(`update public.appointment_reminders set due_at = now() - interval '1 minute' where appointment_id = '${apptId}' and kind = 'reminder' and hours_before = 24`);
let n = 0;
run = smsPipeline(`select public.zella_claim_reminders(25, 'sms')`, REMINDERS, (tel) => { n++; return { statusCode: 200, body: { data: { id: `provider-msg-${n}` } } }; });
const sent = messages.filter((m) => m.live);
ok("update", "texting on: the 24 h reminder is sent to Maria's number from the business number", sent.length === 1 && sent[0].to === "+15125550777", sent[0]?.text);
ok("update", "the message is marked sent with the provider's reference, the reminder done",
  q(`select status from public.sms_messages where external_message_id = 'provider-msg-1'`) === "sent" && q(`select status from public.appointment_reminders where appointment_id = '${apptId}' and hours_before = 24`) === "sent");

// ---------- 4. staff action on the day ----------
q(`update public.appointments set start_time = now() - interval '5 minutes', end_time = now() + interval '85 minutes' where id = '${apptId}'`);
for (const action of ["arrived", "in_service", "completed"]) {
  let res = "";
  try { res = as(STAFF, `select public.zella_set_attendance('${apptId}', '${action}')`); } catch (e) { res = String(e.stderr ?? e.message); }
  ok("on the day", `staff marks ${action.replace("_", " ")}`, !/ERROR/.test(res), res.slice(0, 120));
}
ok("on the day", "the appointment is completed", q(`select status from public.appointments where id = '${apptId}'`) === "completed");
// Colour cards arrive switched off for an existing salon (presets v2); the owner switches them on in Customize records
as(OWNER, `select public.zella_save_record_type('${B}', 'colour_cards', '{"enabled": true}')`);
const card = JSON.parse(as(STAFF, `select public.zella_save_record('${B}', 'colour_cards', null, 'Maria, copper balayage', null, '${cust.id}', '${STAFF}', null,
  '{"formula": "7.4 + 8.34, 20 vol", "developer": "20 vol", "processing_minutes": 35, "stylist": "Rosa"}')`));
ok("on the day", "the stylist saves the colour card on Maria's profile", Boolean(card.id) && q(`select customer_id from public.crm_records where id = '${card.id}'`) === cust.id);
as(MANAGER, `select public.zella_record_charge_payment('${deposit.id}', 'payment', 2500, 'card_terminal', null, 'pay-dep-${apptId}')`);
const inv = JSON.parse(as(STAFF, `select public.zella_create_charge('${B}', 'invoice', 12000, 'Colour and cut', '${cust.id}', '${card.id}', '${apptId}', null, null, 'inv-${apptId}')`));
as(MANAGER, `select public.zella_record_charge_payment('${inv.id}', 'payment', 12000, 'card_terminal', null, 'pay-inv-${apptId}')`);
ok("on the day", "deposit and the visit are paid (recorded by a manager, nothing charged by Zella Voice)",
  q(`select string_agg(status, ',' order by kind) from public.customer_charges where appointment_id = '${apptId}'`) === "paid,paid");
let refused = "";
try { as(STAFF, `select public.zella_record_charge_payment('${inv.id}', 'refund', 100, 'cash')`); } catch (e) { refused = String(e.stderr ?? e.message); }
ok("on the day", "a stylist can't refund", /NOT_ALLOWED/.test(refused));

// ---------- 5. completion: thanks and rebooking ----------
q(`update public.appointments set start_time = now() - interval '26 hours', end_time = now() - interval '24 hours' where id = '${apptId}'`);
q(`select public.zella_run_industry_timers()`);
q(`select public.zella_queue_customer_touches(50)`);
const queued = j(`select coalesce(json_agg(kind order by kind), '[]') from public.followup_tasks where customer_id = '${cust.id}' and status = 'pending'`);
ok("completion", "a thank-you / feedback message is queued after the visit", queued.some((k) => /feedback|service_completed|booking_follow_up|post_appointment/.test(k)), JSON.stringify(queued));
q(`update public.followup_tasks set due_at = now() - interval '1 minute' where customer_id = '${cust.id}' and status = 'pending'`);
run = smsPipeline(`select public.zella_claim_followup_texts(25)`, TASKS, (tel) => { n++; return { statusCode: 200, body: { data: { id: `provider-msg-${n}` } } }; });
const after = messages.filter((m) => m.live && m !== sent[0] && m.customer === cust.id);
ok("completion", "after the visit Maria gets one check-in, in plain words", after.length === 1 && /Maria/.test(after[0].text) && !/\{\{/.test(after[0].text), after.map((m) => `${m.kind}: ${m.text}`).join(" | "));
ok("completion", "the other after-visit notes are held back (no repeats)", Number(q(`select count(*) from public.followup_tasks where customer_id = '${cust.id}' and status <> 'skipped' and (kind = 'feedback_request' or (kind = 'record_status_update' and vars ->> 'record_title' = 'your visit' and not coalesce((vars ->> 'review')::boolean, false)))`)) === 1
  && Number(q(`select count(*) from public.followup_tasks where customer_id = '${cust.id}' and status = 'skipped' and outcome = 'policy' and outcome_notes is not null`)) >= 1);
ok("completion", "a rebooking reminder is planned (service due)", Number(q(`select count(*) from public.automations where business_id = '${B}' and trigger_type = 'service_due' and status = 'active'`)) > 0);
ok("completion", "nothing is left open for this visit", q(`select count(*) from public.appointment_reminders where appointment_id = '${apptId}' and status = 'pending'`) === "0");

// ---------- 6. recovery ----------
// the provider refuses a text: it shows in "Sending failed" and can be retried
q(`insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, vars) values ('${B}', '${cust.id}', 'service_due', 'sms', now() - interval '1 minute', 2, '{"service": "colour"}')`);
run = smsPipeline(`select public.zella_claim_followup_texts(25)`, TASKS, () => ({ statusCode: 422, body: { errors: [{ code: "40310" }] } }));
const failedMsg = j(`select row_to_json(m) from (select id, status, metadata ->> 'error' error from public.sms_messages where business_id = '${B}' and status = 'failed' order by created_at desc limit 1) m`);
ok("recovery", "a provider refusal is recorded as failed, with the provider's code only", failedMsg?.status === "failed" && /40310/.test(failedMsg?.error ?? ""), failedMsg?.error);
const failedTask = q(`select id from public.followup_tasks where customer_id = '${cust.id}' and kind = 'service_due' order by created_at desc limit 1`);
ok("recovery", "first refusal: retried automatically later (task back to pending, due in the future)",
  q(`select status || ':' || (due_at > now())::text from public.followup_tasks where id = '${failedTask}'`) === "pending:true");
q(`update public.followup_tasks set due_at = now() - interval '1 minute' where id = '${failedTask}'`);
smsPipeline(`select public.zella_claim_followup_texts(25)`, TASKS, () => ({ statusCode: 422, body: { errors: [{ code: "40310" }] } }));
ok("recovery", "after the last attempt it stops (failed), nothing more is sent", q(`select status from public.followup_tasks where id = '${failedTask}'`) === "failed");
const failedWork = JSON.parse(as(OWNER, `select public.zella_failed_work('${B}')`) || "null");
ok("recovery", "the owner sees it under Sending failed", (failedWork?.tasks ?? []).some((t) => t.id === failedTask));
let retried = "";
try { retried = as(OWNER, `select public.zella_retry_failed('${B}', 'task', '${failedTask}')`); } catch (e) { retried = String(e.stderr ?? e.message); }
ok("recovery", "the owner retries it and it is queued again", retried === "queued" && q(`select status from public.followup_tasks where id = '${failedTask}'`) === "pending", retried.slice(0, 120));
let staffRetry = "";
try { as(STAFF, `select public.zella_retry_failed('${B}', 'task', '${failedTask}')`); } catch (e) { staffRetry = String(e.stderr ?? e.message); }
ok("recovery", "a stylist can't retry or resend", /NOT_ALLOWED/.test(staffRetry));
// an opted-out customer is never texted, and the reason is visible
q(`update public.customers set do_not_sms = true where id = '${cust.id}'`);
q(`insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, vars) values ('${B}', '${cust.id}', 'no_response_follow_up', 'sms', now() - interval '1 minute', 2, '{}')`);
const before = messages.length;
run = smsPipeline(`select public.zella_claim_followup_texts(25)`, TASKS, noProvider);
ok("recovery", "an opted-out customer is never texted; the task is skipped with a reason", messages.length === before
  && /consent|do_not_contact|opt/.test(q(`select coalesce(outcome_notes, outcome, status) from public.followup_tasks where customer_id = '${cust.id}' and kind = 'no_response_follow_up' order by created_at desc limit 1`) || ""));
q(`update public.customers set do_not_sms = false where id = '${cust.id}'`);
// a caller hangs up before booking: a callback is created and assigned
q(`insert into public.calls (business_id, direction, status, from_number, external_call_id, ai_handled, started_at) values ('${B}', 'inbound', 'answered', '+15125550999', 'launch-call-3', true, now() - interval '2 minutes')`);
rpc("zella_record_inbound_call", { p_provider_call_id: "launch-call-3", p_called_number: "+15125550000", p_vapi_phone_number_id: null, p_from_number: "+15125550999",
  p_started_at: null, p_ended_at: null, p_seconds: 40, p_reason: "customer-ended-call", p_summary: "Wanted a colour appointment but had to go.", p_recording_url: null, p_transcript: null, p_wants_callback: true });
const cb = j(`select row_to_json(c) from (select status, assigned_to is not null assigned, customer_id is not null cust from public.callbacks where call_id = (select id from public.calls where external_call_id = 'launch-call-3')) c`);
ok("recovery", "a caller who hangs up mid-booking gets a callback, assigned, and becomes a lead", cb?.assigned === true && cb?.cust === true, JSON.stringify(cb));

// ---------- 7. audit trail ----------
ok("audit", "every AI action is logged (tool, outcome, no message content)", Number(q(`select count(*) from public.ai_tool_calls where business_id = '${B}' and provider_call_id like 'launch-call-%'`)) >= 6);
ok("audit", "money changes are in the audit log", Number(q(`select count(*) from public.audit_logs where business_id = '${B}' and entity_type = 'customer_charge'`)) >= 4);
ok("audit", "the colour card's history shows who added it", q(`select actor from public.crm_record_events where record_id = '${card.id}' and kind = 'created'`) === STAFF);
ok("audit", "texts sent and refused are on record with their status", Number(q(`select count(*) from public.sms_messages where business_id = '${B}' and status in ('sent', 'failed', 'dry_run')`)) >= 3);

console.log("\nMessages Maria would receive:");
for (const m of messages.filter((x) => x.customer === cust.id)) console.log(`  ${m.result.padEnd(8)} ${m.kind}: ${m.text}`);
console.log(fails ? `\nLAUNCH WORKFLOW: ${fails} FAILED` : "\nLAUNCH WORKFLOW: ALL PASSED");
process.exit(fails ? 1 : 0);
