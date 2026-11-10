// Before-and-after: a CRM change -> the next call, through the REAL call handler (voice-rules, served locally behind
// tests/browser/local-backend.mjs) on an isolated copy of production (tests/e2e/run.sh). Every message is signed the
// way Vapi signs it and carries the call's phone number the way Vapi sends it; the business is found from that number.
// CRM changes are made as the signed-in owner through the same database functions the CRM pages call.
//
// What this proves: what Zella hands to Vapi (the assistant at assistant-request) and what every tool answers, before
// and after each change, for business A, while business B stays exactly as it was.
// What it does NOT prove: that Vapi speaks it. No real call is made; that is tests/e2e/PROVIDER_PLAN.md.
//
// Writes tests/e2e/out/evidence.json: per scenario, the business, the version saved and delivered, the call id, the
// tool results, the observed answer and pass/fail.
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";

const API = process.env.API ?? "http://localhost:54321";
const DB = process.env.ZDB ?? "ze2e";
const VAPI = "vapi-local-test-secret-0123456789";
const sqlRaw = (q) => execFileSync("psql", ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", DB], { input: q }).toString().trim();
const sql = (q) => { try { return sqlRaw(q); } catch (e) { throw new Error(String(e.stderr ?? e.message).slice(0, 800)); } };
const sign = (raw) => { const ts = String(Date.now()); return { "x-timestamp": ts, "x-signature": crypto.createHmac("sha256", VAPI).update(`${ts}.${raw}`).digest("hex") }; };

const A = { id: "5e000000-0000-0000-0000-00000000000a", agent: "5e100000-0000-0000-0000-00000000000a", owner: "5e300000-0000-0000-0000-00000000000a", e164: "+15125558001", pn: "vpn-e2e-a", name: "Maple Salon" };
const B = { id: "5e000000-0000-0000-0000-00000000000b", agent: "5e100000-0000-0000-0000-00000000000b", owner: "5e300000-0000-0000-0000-00000000000b", e164: "+15125558002", pn: "vpn-e2e-b", name: "Oak Dental" };

async function vapi(message) {
  const raw = JSON.stringify({ message });
  const t0 = performance.now();
  const r = await fetch(`${API}/functions/v1/voice-rules`, { method: "POST", headers: { apikey: "sb_publishable_local_test_only", "content-type": "application/json", ...sign(raw) }, body: raw });
  const text = await r.text(); let json = null; try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: r.status, json, text, ms: Math.round(performance.now() - t0) };
}
let seq = 0;
// a call as Vapi starts it: assistant-request on the business's own number, then the call record (status-update)
async function startCall(biz) {
  const callId = `e2e-${biz === A ? "a" : "b"}-${++seq}`;
  const call = { id: callId, type: "inboundPhoneCall", phoneNumberId: biz.pn, customer: { number: "+15125550142" } };
  const ar = await vapi({ type: "assistant-request", call, phoneNumber: { id: biz.pn, number: biz.e164 } });
  sql(`insert into calls (business_id, direction, status, from_number, to_number, external_call_id, ai_handled) values ('${biz.id}', 'inbound', 'answered', '+15125550142', '${biz.e164}', '${callId}', true) on conflict do nothing`);
  const delivered = sql(`select coalesce((select d.outcome || ':v' || coalesce(v.version::text, '-') || ':' || coalesce(left(d.config_hash, 8), '-') from assistant_deliveries d left join agent_config_versions v on v.id = d.version_id where d.provider_call_id = '${callId}' order by d.id desc limit 1), 'none')`);
  return { callId, call, assistant: ar.json?.assistant ?? null, reply: ar.json, ms: ar.ms, delivered };
}
async function tool(c, biz, name, args) {
  const r = await vapi({ type: "tool-calls", call: c.call, phoneNumber: { id: biz.pn, number: biz.e164 }, toolCallList: [{ id: `tc-${++seq}`, type: "function", function: { name, arguments: args } }] });
  const res = r.json?.results?.[0]?.result ?? r.json?.results?.[0]?.error;
  return { status: r.status, text: typeof res === "string" ? res : JSON.stringify(res ?? r.text) };
}
async function transfer(c, biz) {
  const r = await vapi({ type: "transfer-destination-request", call: c.call, phoneNumber: { id: biz.pn, number: biz.e164 } });
  return { status: r.status, text: r.text, json: r.json };
}
const prompt = (c) => c.assistant?.model?.messages?.[0]?.content ?? "";
const toolsOf = (c) => (c.assistant?.model?.tools ?? []).map((t) => t.function?.name ?? t.name).filter(Boolean);
// the CRM: one psql session as the signed-in owner
const asOwner = (biz, q) => sql(`select set_config('request.jwt.claims', '{"sub":"${biz.owner}","role":"authenticated","aal":"aal1"}', false); set role authenticated; ${q}; reset role;`);
const publish = (biz, patch) => sql(`select set_config('request.jwt.claims', '{"sub":"${biz.owner}","role":"authenticated","aal":"aal1"}', false); set role authenticated;
  with base as (select jsonb_build_object('system_prompt', c.system_prompt, 'escalation_rules', c.escalation_rules, 'knowledge_base', c.knowledge_base, 'appointment_rules', c.appointment_rules) b
                  from ai_agent_configs c where c.agent_id = '${biz.agent}'),
       d as (select public.zella_save_agent_config_draft('${biz.agent}', (select b from base) || '${JSON.stringify(patch).replace(/'/g, "''")}'::jsonb) id)
  select (select id from d)::text || '|' || public.zella_validate_agent_config((select id from d))::text || '|' || public.zella_publish_agent_config((select id from d))::text; reset role;`).split("\n").pop();
const versionOf = (biz) => sql(`select coalesce((select version || ':' || status || ':' || sync_status from agent_config_versions where business_id = '${biz.id}' and status = 'published' order by version desc limit 1), 'none')`);
const fingerprint = async () => { const c = await startCall(B); return { hash: crypto.createHash("sha256").update(JSON.stringify(c.assistant)).digest("hex").slice(0, 16), c }; };

const evidence = []; let fails = 0;
function record(scenario, biz, data) {
  const pass = data.checks.every(([, ok]) => ok);
  if (!pass) fails++;
  evidence.push({ scenario, business_id: biz.id, business: biz.name, pass, ...data, checks: data.checks.map(([what, ok]) => ({ what, ok })) });
  console.log(`${pass ? "PASS" : "FAIL"} ${scenario}${pass ? "" : ": " + data.checks.filter(([, ok]) => !ok).map(([w]) => w).join("; ")}`);
}

// ---------- the two businesses (A: salon, B: dental), as setup leaves them ----------
sql(`delete from vault.decrypted_secrets where name = 'zella_vapi_hmac_secret'; insert into vault.decrypted_secrets (id, name, decrypted_secret) values (gen_random_uuid(), 'zella_vapi_hmac_secret', '${VAPI}');
insert into platform_settings (key, value) values ('vapi_server_url', '"https://example.test/functions/v1/voice-rules"'), ('vapi_credential_id', '"cred-test"'),
  ('voice_llm_provider', '"anthropic"'), ('voice_llm_model', '"claude-sonnet-5"'), ('voice_tts_provider', '"11labs"'), ('voice_tts_voice_id', '"testvoice01"'),
  ('voice_stt_model_multilingual', '"nova-3"') on conflict (key) do update set value = excluded.value;
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
  select '${A.id}', '${A.name}', id, 'America/Chicago', true, 'active' from industries where slug = 'beauty-salon' on conflict do nothing;
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
  select '${B.id}', '${B.name}', id, 'America/New_York', true, 'active' from industries where slug = 'dental' on conflict do nothing;
insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('${A.id}', '${A.e164}', '${A.pn}'), ('${B.id}', '${B.e164}', '${B.pn}');
insert into business_hours (business_id, weekday, opens, closes) select '${A.id}', d, '09:00', '17:00' from generate_series(0, 6) d;
insert into business_hours (business_id, weekday, opens, closes) select '${B.id}', d, '00:00', '23:59' from generate_series(0, 6) d;
insert into ai_agents (id, business_id, name, agent_type, status, is_default) values ('${A.agent}', '${A.id}', 'Ava', 'receptionist', 'active', true), ('${B.agent}', '${B.id}', 'Ben', 'receptionist', 'active', true);
insert into ai_agent_configs (agent_id, system_prompt, escalation_rules, knowledge_base, appointment_rules) values
  ('${A.agent}', 'You are the receptionist of Maple Salon. Help callers book and answer from the knowledge.', '{"transfer_enabled": true, "transfer_to": {"type": "phone_number", "phone": "+15125550101"}}',
   '{"services": [{"name": "Haircut", "duration_minutes": 45, "price": "$40"}]}', '{}'),
  ('${B.agent}', 'You are the receptionist of Oak Dental. Answer from the knowledge and take messages.', '{"transfer_enabled": true, "transfer_to": {"type": "phone_number", "phone": "+15125550201"}}',
   '{"services": [{"name": "Cleaning", "duration_minutes": 60, "price": "$120"}]}', '{}');
insert into auth.users (id, email, email_confirmed_at) values ('${A.owner}', 'owner@maple.test', now()), ('${B.owner}', 'owner@oak.test', now());
insert into business_members (business_id, user_id, role, status) values ('${A.id}', '${A.owner}', 'owner', 'active'), ('${B.id}', '${B.owner}', 'owner', 'active');
insert into knowledge_items (business_id, kind, title, question, answer, status) values ('${B.id}', 'faq', 'Parking', 'Is there parking?', 'Oak Dental has a garage on Pine Street.', 'ready');`);
const bStart = await fingerprint();

// 0. the number decides the business; an unknown number gets nothing
{
  const a = await startCall(A); const b = await startCall(B);
  const u = await vapi({ type: "assistant-request", call: { id: "e2e-unknown", phoneNumberId: "vpn-nobody" }, phoneNumber: { id: "vpn-nobody", number: "+15125550000" } });
  record("0 number -> business", A, { call_ids: [a.callId, b.callId, "e2e-unknown"], delivered: [a.delivered, b.delivered], ms: [a.ms, b.ms],
    observed: { a: a.assistant?.metadata, b: b.assistant?.metadata, unknown: u.json },
    checks: [["A's number gets A", a.assistant?.metadata?.business_id === A.id && prompt(a).includes("Maple Salon")], ["B's number gets B", b.assistant?.metadata?.business_id === B.id && prompt(b).includes("Oak Dental")],
             ["no business's settings for an unknown number", !u.json?.assistant && /can't take your call/.test(u.json?.error ?? "")]] });
}

// 1. hours
{
  const before = await startCall(A);
  const t1 = await tool(before, A, "check_open_hours", {});
  asOwner(A, `select public.zella_save_business_hours('${A.id}', (select jsonb_agg(jsonb_build_object('weekday', d, 'opens', '10:00', 'closes', '14:00')) from generate_series(0, 6) d))`);
  const after = await startCall(A);
  const t2 = await tool(after, A, "check_open_hours", {});
  const av = await tool(after, A, "check_availability", { days: 3 });
  const times = [...av.text.matchAll(/"start":"([^"]+)"/g)].map((m) => new Date(m[1]));
  const local = (d) => Number(new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", hour: "numeric", hourCycle: "h23" }).format(d));
  record("1 hours: 9-5 -> 10-2", A, { call_ids: [before.callId, after.callId], delivered: [before.delivered, after.delivered], tool_results: { before: t1.text.slice(0, 300), after: t2.text.slice(0, 300), availability: av.text.slice(0, 300) },
    observed: { prompt_before: /9:00|9 ?am|09:00/i.test(prompt(before)), prompt_after: /10:00|10 ?am/i.test(prompt(after)) },
    checks: [["the next call's instructions carry the new hours", /10:00|10 ?am/i.test(prompt(after)) && !/09:00 ?- ?17:00|9:00 ?am ?- ?5:00 ?pm/i.test(prompt(after))],
             ["offered times all inside 10:00-14:00", times.length > 0 && times.every((d) => local(d) >= 10 && local(d) < 14)]] });
}

// 2. a service price
{
  const before = await startCall(A);
  asOwner(A, `select public.zella_business_services_save('${A.id}', '[{"name": "Haircut", "duration_minutes": 45, "price": "$45"}]'::jsonb)`);
  const after = await startCall(A);
  const again = await startCall(A);
  const h = (c) => c.delivered.split(":")[2];
  record("2 price: Haircut $40 -> $45", A, { call_ids: [before.callId, after.callId], delivered: [before.delivered, after.delivered],
    observed: { before: prompt(before).match(/Haircut[^\n]*/)?.[0], after: prompt(after).match(/Haircut[^\n]*/)?.[0] },
    fingerprints: { before: h(before), after: h(after), after_again: h(again) },
    checks: [["a new fingerprint for the changed settings, the same one while nothing changes", h(before) !== h(after) && h(after) === h(again) && h(after) !== "-"],
             ["before: $40", /Haircut[^\n]*\$40/.test(prompt(before))], ["after: $45 and never $40", /Haircut[^\n]*\$45/.test(prompt(after)) && !/\$40/.test(prompt(after))]] });
}

// 3-4. an FAQ: added, edited, unpublished, deleted; a refused edit keeps the last good answer; in-progress call
{
  const c0 = await startCall(A);
  const k0 = await tool(c0, A, "search_knowledge", { query: "Is there parking?" });
  asOwner(A, `insert into knowledge_items (business_id, kind, title, question, answer, status) values ('${A.id}', 'faq', 'Parking', 'Is there parking?', 'Free parking behind Maple Salon.', 'processing')`);
  const k1 = await tool(c0, A, "search_knowledge", { query: "Is there parking?" });   // same call, still in progress
  const c1 = await startCall(A);
  const k2 = await tool(c1, A, "search_knowledge", { query: "Is there parking?" });
  asOwner(A, `update knowledge_items set answer = 'Parking moved to the Elm Street lot.' where business_id = '${A.id}' and title = 'Parking'`);
  const k3 = await tool(c1, A, "search_knowledge", { query: "Is there parking?" });
  let refused = "";
  try { asOwner(A, `update knowledge_items set answer = '   ' where business_id = '${A.id}' and title = 'Parking'`); } catch (e) { refused = String(e.message).match(/KNOWLEDGE_[A-Z_]+/)?.[0] ?? "error"; }
  const k4 = await tool(c1, A, "search_knowledge", { query: "Is there parking?" });
  asOwner(A, `update knowledge_items set status = 'draft' where business_id = '${A.id}' and title = 'Parking'`);   // unpublish: back to draft
  const k5 = await tool(c1, A, "search_knowledge", { query: "Is there parking?" });
  asOwner(A, `update knowledge_items set status = 'processing', answer = 'Parking is back behind the salon.' where business_id = '${A.id}' and title = 'Parking'`);
  const k6 = await tool(c1, A, "search_knowledge", { query: "Is there parking?" });
  asOwner(A, `update knowledge_items set status = 'archived' where business_id = '${A.id}' and title = 'Parking'`);   // the CRM's Remove (no hard delete: history is kept)
  const k7 = await tool(c1, A, "search_knowledge", { query: "Is there parking?" });
  const kB = await tool(await startCall(B), B, "search_knowledge", { query: "Is there parking?" });
  record("3-4 FAQ add / edit / refused edit / unpublish / republish / delete", A, { call_ids: [c0.callId, c1.callId],
    tool_results: { before: k0.text.slice(0, 160), added_mid_call: k1.text.slice(0, 160), added: k2.text.slice(0, 160), edited: k3.text.slice(0, 160), refused_edit: refused,
                    after_refused: k4.text.slice(0, 160), unpublished: k5.text.slice(0, 160), republished: k6.text.slice(0, 160), deleted: k7.text.slice(0, 160), business_b: kB.text.slice(0, 160) },
    checks: [["nothing invented before", !/Free parking|Elm Street/i.test(k0.text)], ["an answer added mid-call is used by that call's next search", /Free parking behind Maple/.test(k1.text)],
             ["added: used", /Free parking behind Maple/.test(k2.text)], ["edited: new answer, old gone", /Elm Street/.test(k3.text) && !/Free parking/.test(k3.text)],
             ["a bad edit is refused and the last good answer stays", refused === "KNOWLEDGE_ANSWER_EMPTY" && /Elm Street/.test(k4.text)],
             ["unpublished: not used", !/Elm Street|Maple/.test(k5.text)], ["republished: used", /back behind the salon/.test(k6.text)], ["deleted: not used", !/behind the salon|Elm Street/.test(k7.text)],
             ["B never gets A's answer", /Pine Street/.test(kB.text) && !/Maple|Elm/.test(kB.text)]] });
}

// 5. greeting and language
{
  const before = await startCall(A);
  asOwner(A, `select public.zella_business_language_save('${A.id}', 'en-US', array['es'], 'Hola and welcome to {name}!')`);
  const after = await startCall(A);
  record("5 greeting and language: English -> English + Spanish, new greeting", A, { call_ids: [before.callId, after.callId], delivered: [before.delivered, after.delivered],
    observed: { first_before: before.assistant?.firstMessage, first_after: after.assistant?.firstMessage, transcriber_after: after.assistant?.transcriber, voice_after: after.assistant?.voice },
    checks: [["the next call opens with the new greeting", after.assistant?.firstMessage === "Hola and welcome to Maple Salon!"],
             ["it listens for more than one language", after.assistant?.transcriber?.language === "multi"], ["and is told to switch to Spanish", /Spanish/.test(prompt(after))],
             ["the call before kept its own greeting", before.assistant?.firstMessage !== after.assistant?.firstMessage]] });
}

// 6. transfer destination (controlled test numbers in the 555 range; nothing is dialled). After hours first: the
// business is closed (scenario 1 left 10:00-14:00 Chicago), so a transfer is refused and a message offered.
{
  const allDay = (biz) => asOwner(biz, `select public.zella_save_business_hours('${biz.id}', (select jsonb_agg(jsonb_build_object('weekday', d, 'opens', '00:00', 'closes', '23:59')) from generate_series(0, 6) d))`);
  const openNow = sql(`select (public.zella_business_open('${A.id}') ->> 'open')`);
  const cX = await startCall(A);
  const tX = await tool(cX, A, "transfer_to_human", { reason: "customer_requests_human" });
  const dX = await transfer(cX, A);
  allDay(A);
  const c0 = await startCall(A);
  const t0 = await tool(c0, A, "transfer_to_human", { reason: "customer_requests_human" });
  const d0 = await transfer(c0, A);
  const v = publish(A, { escalation_rules: { transfer_enabled: true, transfer_to: { type: "phone_number", phone: "+15125550109" } } });
  const c1 = await startCall(A);
  const t1 = await tool(c1, A, "transfer_to_human", { reason: "customer_requests_human" });
  const d1 = await transfer(c1, A);
  record("6 transfer: closed -> refused; open: +15125550101 -> +15125550109", A, { call_ids: [cX.callId, c0.callId, c1.callId], version_published: v.split("|")[0], delivered: [cX.delivered, c0.delivered, c1.delivered],
    tool_results: { closed: tX.text.slice(0, 200), before: t0.text.slice(0, 200), after: t1.text.slice(0, 200) }, observed: { open_at_first: openNow, destination_closed: dX.json, destination_before: d0.json, destination_after: d1.json },
    checks: [["while closed: no number given, a message offered", openNow === "true" || (!dX.json?.destination && /message/i.test(tX.text))],
             ["open, before: the old number", d0.json?.destination?.number === "+15125550101"], ["open, after: the new number, never the old", d1.json?.destination?.number === "+15125550109"]] });
}

// 7. booking switched off
{
  const c0 = await startCall(A);
  const v = publish(A, { appointment_rules: { can_book: false, can_reschedule: false, can_cancel: false } });
  const c1 = await startCall(A);
  const av = await tool(c1, A, "check_availability", { days: 3 });
  const bk = await tool(c1, A, "book_appointment", { start: new Date(Date.now() + 86400e3).toISOString(), first_name: "Test", last_name: "Caller", phone: "+15125550142", title: "Haircut", confirmed: true });
  const booked = sql(`select count(*) from appointments where business_id = '${A.id}'`);
  record("7 booking switched off", A, { call_ids: [c0.callId, c1.callId], version_published: v.split("|")[0], delivered: [c0.delivered, c1.delivered],
    observed: { tools_before: toolsOf(c0), tools_after: toolsOf(c1) }, tool_results: { availability: av.text.slice(0, 200), booking: bk.text.slice(0, 200) },
    checks: [["before: booking tools offered", toolsOf(c0).includes("book_appointment")], ["after: not offered", !toolsOf(c1).some((t) => /book_appointment|check_availability|reschedule|cancel_appointment/.test(t))],
             ["and refused if called anyway", /not_available/.test(av.text) && /not_available/.test(bk.text)], ["nothing was booked", booked === "0"]] });
  publish(A, { appointment_rules: { can_book: true, can_reschedule: true, can_cancel: true } });
}

// 8. a holiday (H1)
{
  const day = sql(`select ((now() at time zone 'America/Chicago')::date + 1)::text`);
  const c0 = await startCall(A);
  const a0 = await tool(c0, A, "check_availability", { date: day, days: 1 });
  asOwner(A, `select public.zella_add_business_closure('${A.id}', '${day}', '${day}', 'Staff training', null, null)`);
  const c1 = await startCall(A);
  const a1 = await tool(c1, A, "check_availability", { date: day, days: 1 });
  const onDay = (t) => [...t.matchAll(/"start":"([^"]+)"/g)].filter((m) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago" }).format(new Date(m[1])) === day).length;
  record("8 holiday tomorrow", A, { call_ids: [c0.callId, c1.callId], tool_results: { before: a0.text.slice(0, 200), after: a1.text.slice(0, 200) },
    observed: { times_that_day_before: onDay(a0.text), times_that_day_after: onDay(a1.text), told: /Staff training/.test(prompt(c1)) },
    checks: [["before: times offered that day", onDay(a0.text) > 0], ["after: none offered that day", onDay(a1.text) === 0], ["and the call is told", /Staff training/.test(prompt(c1))]] });
}

// 9. delivery states and timing
{
  const v = publish(A, { knowledge_base: { services: [{ name: "Haircut", duration_minutes: 45, price: "$45" }], restrictions: ["Never promise same-day colour"] } });
  const pending = versionOf(A);
  const t0 = Date.now();
  const c = await startCall(A);
  const live = versionOf(A);
  sql(`delete from platform_settings where key = 'voice_tts_voice_id'`);
  const bad = await startCall(A);
  const failed = versionOf(A); const reason = sql(`select coalesce(sync_error, '') from agent_config_versions where business_id = '${A.id}' order by version desc limit 1`);
  sql(`insert into platform_settings (key, value) values ('voice_tts_voice_id', '"testvoice01"')`);
  const ok = await startCall(A);
  const draftV = sql(`select set_config('request.jwt.claims', '{"sub":"${A.owner}","role":"authenticated","aal":"aal1"}', false); set role authenticated;
    select public.zella_save_agent_config_draft('${A.agent}', (select jsonb_build_object('system_prompt', c.system_prompt, 'escalation_rules', c.escalation_rules, 'knowledge_base', c.knowledge_base, 'appointment_rules', c.appointment_rules) from ai_agent_configs c where c.agent_id = '${A.agent}')); reset role;`).split("\n").pop();
  const st = JSON.parse(sql(`select set_config('request.jwt.claims', '{"sub":"${A.owner}","role":"authenticated","aal":"aal1"}', false); set role authenticated; select public.zella_assistant_delivery_status('${A.id}')::text; reset role;`).split("\n").pop());
  record("9 states and timing", A, { call_ids: [c.callId, bad.callId, ok.callId], version_published: v.split("|")[0],
    observed: { after_publish: pending, after_next_call: live, settings_broken: failed, reason, fixed: versionOf(A), ms_to_build: c.ms, ms_from_publish_to_call_answer: Date.now() - t0, broken_reply: bad.reply },
    checks: [["published -> waiting for the next call", /:published:pending$/.test(pending)], ["the next call uses it -> live", /:published:live$/.test(live) && /restrictions|same-day colour/i.test(prompt(c))],
             ["unsendable settings -> failed with the reason, caller hears the refusal", /:failed$/.test(failed) && /voice_tts_voice_id/.test(reason) && /can't take/.test(bad.reply?.error ?? "")],
             ["fixed -> live again on the next call", /:published:live$/.test(versionOf(A)) && !!ok.assistant], ["assistant built in under 2 s", c.ms < 2000],
             ["stages: an unpublished draft shows as draft", st.draft?.id === draftV],
             ["stages: delivery configured and the last call got the current settings", st.delivery?.configured === true && st.delivery?.last_served?.is_current === true],
             ["stages: no verified real call (none was made)", st.verified_call === null]],
    stages: st });
}

// 10. B untouched by all of it
{
  const bEnd = await fingerprint();
  const k = await tool(bEnd.c, B, "search_knowledge", { query: "Is there parking?" });
  const d = await transfer(bEnd.c, B);
  record("10 B unchanged while A was edited", B, { call_ids: [bStart.c.callId, bEnd.c.callId], observed: { assistant_before: bStart.hash, assistant_after: bEnd.hash, transfer: d.json?.destination?.number },
    checks: [["B's assistant is byte-for-byte the same", bStart.hash === bEnd.hash], ["B's knowledge and transfer unchanged", /Pine Street/.test(k.text) && d.json?.destination?.number === "+15125550201"]] });
}

// 11. what the model receives: no credentials, no transfer numbers, no owner or staff contact details, no other business
{
  sql(`update businesses set email = 'billing@maple.test' where id = '${A.id}'; insert into staff_members (business_id, name, phone, email, is_active) values ('${A.id}', 'Rita Stylist', '+15125550177', 'rita@maple.test', true)`);
  const c = await startCall(A);
  const all = JSON.stringify(c.assistant);
  const model = JSON.stringify(c.assistant?.model ?? {}) + (c.assistant?.firstMessage ?? "");
  const leaks = [["transfer numbers", /\+15125550109|\+15125550101/], ["the business email", /billing@maple\.test/], ["staff contact details", /\+15125550177|rita@maple\.test/],
                 ["the HMAC secret", new RegExp(VAPI)], ["the server key", /sb_secret/], ["business B", /Oak Dental|Pine Street/]];
  record("11 nothing private or secret in what the model receives", A, { call_ids: [c.callId], observed: { server: c.assistant?.server, size: all.length },
    checks: [...leaks.map(([what, re]) => [`no ${what}`, !re.test(all)]), ["the model text has no email address at all", !/[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[a-z]{2,}/.test(model)]] });
}

sql(`delete from platform_settings where key in ('vapi_server_url', 'vapi_credential_id', 'voice_llm_provider', 'voice_llm_model', 'voice_tts_provider', 'voice_tts_voice_id', 'voice_stt_model_multilingual')`);
mkdirSync(new URL("./out/", import.meta.url), { recursive: true });
writeFileSync(new URL("./out/evidence.json", import.meta.url), JSON.stringify({ run_at: new Date().toISOString(), database: DB, provider: "none (local voice-rules; no Vapi call)", scenarios: evidence }, null, 1));
console.log(`\n${evidence.length} scenarios: ${evidence.length - fails} passed, ${fails} failed`);
process.exit(fails ? 1 : 0);
