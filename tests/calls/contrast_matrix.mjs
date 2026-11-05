// Two contrasting businesses in each of the 28 industries, called through the REAL call handler (the voice-rules edge
// function, served locally behind tests/browser/local-backend.mjs) on an isolated database with the 17 pending
// migrations and sql/zella_setup_enforcement.sql. Messages are signed like Vapi's; nothing is sent anywhere.
//
//   A "everything on"   default booking abilities, a setup FAQ, a transfer phone, English + Spanish, own greeting,
//                       2 hours' minimum notice
//   B "held back"       booking, rescheduling and cancelling switched off in setup; no FAQs; no transfer number
//
// Per business, through voice-rules: search_knowledge (A answers the setup FAQ, B has nothing), check_availability and
// book_appointment (A where the industry takes bookings; B refused; e-commerce refused for both), cancel (B refused),
// transfer-destination-request (A connects to its number, B refused). From the assistant settings the business would
// get (zella_assistant_config): A's greeting and languages, B's tool list without the booking tools.
// Usage: tests/calls/run.sh   (builds the stack and runs this)   writes tests/calls/out/matrix.json
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";

const API = process.env.API ?? "http://localhost:54321";
const DB = process.env.ZDB ?? "zcalls";
const VAPI = "vapi-local-test-secret-0123456789";
const sqlRaw = (q) => execFileSync("psql", ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-h", process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec", "-p", process.env.ZPG_PORT ?? "55433", "-U", "postgres", "-d", DB], { input: q }).toString().trim();
const sql = (q) => { try { return sqlRaw(q); } catch (e) { throw new Error(String(e.stderr ?? e.message).slice(0, 600)); } };
const sign = (raw) => { const ts = String(Date.now()); return { "x-timestamp": ts, "x-signature": crypto.createHmac("sha256", VAPI).update(`${ts}.${raw}`).digest("hex") }; };
async function vapi(message) {
  const raw = JSON.stringify({ message });
  const r = await fetch(`${API}/functions/v1/voice-rules`, { method: "POST", headers: { apikey: "sb_publishable_local_test_only", "content-type": "application/json", ...sign(raw) }, body: raw });
  const text = await r.text(); let json = null; try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: r.status, json, text };
}
let n = 0;
async function tool(callId, name, args) {
  const r = await vapi({ type: "tool-calls", call: { id: callId }, toolCallList: [{ id: `tc-${++n}`, type: "function", function: { name, arguments: args } }] });
  const res = r.json?.results?.[0]?.result;
  let out = res; try { out = typeof res === "string" ? JSON.parse(res) : res; } catch { /* plain text */ }
  return { status: r.status, out, text: typeof res === "string" ? res : JSON.stringify(res ?? r.text) };
}

sql(`delete from vault.decrypted_secrets where name = 'zella_vapi_hmac_secret'; insert into vault.decrypted_secrets (id, name, decrypted_secret) values (gen_random_uuid(), 'zella_vapi_hmac_secret', '${VAPI}')`);
// K3 (sql/zella_assistant_delivery.sql): with that file and a voice-rules that answers assistant-request
// (ZMATRIX_ASSISTANT=1), every business's call also fetches its assistant through voice-rules. Test platform settings
// make the assistant sendable; they are removed at the end.
const ASSISTANT = process.env.ZMATRIX_ASSISTANT === "1" && sql(`select to_regprocedure('public.zella_assistant_for_call(text,text,text)') is not null`) === "t";
const TEST_SETTINGS = ["vapi_server_url", "vapi_credential_id", "voice_llm_provider", "voice_llm_model", "voice_tts_provider", "voice_tts_voice_id", "voice_stt_model_multilingual"];
if (ASSISTANT) sql(`insert into platform_settings (key, value) values ('vapi_server_url', '"https://example.test/functions/v1/voice-rules"'), ('vapi_credential_id', '"cred-test"'),
  ('voice_llm_provider', '"anthropic"'), ('voice_llm_model', '"claude-sonnet-5"'), ('voice_tts_provider', '"11labs"'), ('voice_tts_voice_id', '"testvoice01"'), ('voice_stt_model_multilingual', '"nova-3"') on conflict (key) do update set value = excluded.value`);
const industries = sql(`select json_agg(json_build_object('id', id, 'slug', slug, 'name', name) order by slug) from industries where is_active`);
const list = JSON.parse(industries);
const results = []; let fails = 0, passes = 0;
const check = (ind, biz, what, cond, detail = "") => { results.push({ industry: ind, business: biz, what, pass: Boolean(cond), detail: cond ? undefined : String(detail).slice(0, 220) }); cond ? passes++ : fails++;
  if (!cond) console.log(`FAIL ${ind} ${biz}: ${what} - ${String(detail).slice(0, 220)}`); };

for (const [k, ind] of list.entries()) {
  const ids = { A: `f${String(k).padStart(2, "0")}a0000-0000-0000-0000-000000000001`, B: `f${String(k).padStart(2, "0")}b0000-0000-0000-0000-000000000001` };
  for (const v of ["A", "B"]) {
    const id = ids[v], agent = id.replace(/^f/, "e");
    sql(`delete from appointments where business_id = '${id}'; delete from knowledge_items where business_id = '${id}' and source_key like 'setup:%';
      delete from business_languages where business_id = '${id}'; delete from ai_agent_configs where agent_id = '${agent}';
      insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status) values ('${id}', '${v} ${ind.name}', '${ind.id}', 'UTC', true, 'active') on conflict (id) do nothing;
      insert into business_hours (business_id, weekday, opens, closes) select '${id}', d, '00:00', '23:59' from generate_series(0, 6) d where not exists (select 1 from business_hours where business_id = '${id}');
      insert into ai_agents (id, business_id, name, agent_type, status, is_default) values ('${agent}', '${id}', 'Ava', 'receptionist', 'active', true) on conflict (id) do nothing;
      insert into calls (business_id, direction, status, from_number, external_call_id, ai_handled) values ('${id}', 'inbound', 'answered', '+1512555${String(k).padStart(2, "0")}0${v === "A" ? 1 : 2}', 'call-${id}', true) on conflict do nothing;`);
    if (v === "A") {
      sql(`insert into ai_agent_configs (agent_id, appointment_rules, escalation_rules, knowledge_base, voice_config) values ('${agent}',
        '{"min_notice_hours": 2}', '{"transfer_to": {"type": "phone_number", "phone": "+15125550100"}}',
        '{"faqs": [{"question": "Is there parking?", "answer": "Yes, free parking behind the building."}]}', '{"language": "en-US+es-US", "greeting": "Hello from A, how can I help?"}');
`);
      // the setup's language reaches the live settings (sql/zella_setup_enforcement.sql); absent before that file
      try { sql(`select public.zella_setup_language_apply('${id}', 'en-US+es-US', 'Hello from A, how can I help?')`); } catch { /* before the fix */ }
    } else {
      sql(`insert into ai_agent_configs (agent_id, appointment_rules, escalation_rules, knowledge_base) values ('${agent}',
        '{"can_book": false, "can_reschedule": false, "can_cancel": false}', '{}', '{}');`);
    }
  }
  const bookable = sql(`select public.zella_capability_on('${ids.A}', 'scheduling')`) === "t";

  // knowledge
  let r = await tool(`call-${ids.A}`, "search_knowledge", { query: "parking" });
  check(ind.slug, "A", "the setup FAQ is answered", r.status === 200 && /free parking/i.test(r.text), r.text);
  r = await tool(`call-${ids.B}`, "search_knowledge", { query: "parking" });
  check(ind.slug, "B", "no FAQ: nothing invented", r.status === 200 && /no_information|no approved information/i.test(r.text), r.text);

  // booking
  r = await tool(`call-${ids.A}`, "check_availability", { days: 3 });
  const slots = r.out?.times ?? r.out?.slots ?? [];   // voice-rules hands the times to the assistant as "times"
  if (bookable) {
    check(ind.slug, "A", "times are offered, none inside the 2 hours' notice", slots.length > 0 && slots.every((s) => new Date(s.start) >= new Date(Date.now() + 2 * 3600e3 - 60e3)), r.text);
    const b = await tool(`call-${ids.A}`, "book_appointment", { start: slots[0]?.start, first_name: "Test", last_name: "Caller", phone: `+15125559${String(k).padStart(3, "0")}`, title: "Visit", confirmed: true });
    check(ind.slug, "A", "an offered time books (booked or requested, never invented)", /"status":"(booked|requested)"|booked|requested/.test(b.text) && !/error/i.test(b.out?.status ?? ""), b.text);
  } else {
    check(ind.slug, "A", "the industry takes no bookings: refused", /not_available/.test(r.text), r.text);
  }
  r = await tool(`call-${ids.B}`, "check_availability", { days: 3 });
  check(ind.slug, "B", "booking switched off in setup: availability refused", /not_available/.test(r.text), r.text);
  r = await tool(`call-${ids.B}`, "book_appointment", { start: new Date(Date.now() + 86400e3).toISOString(), first_name: "X", phone: "+15125550000", confirmed: true });
  check(ind.slug, "B", "and booking refused", /not_available/.test(r.text), r.text);
  r = await tool(`call-${ids.B}`, "cancel_appointment", { appointment_id: "00000000-0000-0000-0000-000000000000" });
  check(ind.slug, "B", "cancelling switched off: refused", /not_available/.test(r.text), r.text);

  // transfer
  let t = await vapi({ type: "transfer-destination-request", call: { id: `call-${ids.A}`, customer: { number: "+15125550001" } } });
  check(ind.slug, "A", "transfer goes to the business's own number", t.status === 200 && /\+15125550100/.test(t.text), t.text);
  t = await vapi({ type: "transfer-destination-request", call: { id: `call-${ids.B}`, customer: { number: "+15125550002" } } });
  check(ind.slug, "B", "no transfer number: refused with a message, no number given", t.status === 200 && !/\+1512555010/.test(t.text) && /message|can't|cannot/i.test(t.text), t.text);

  // what the assistant itself would be set up with
  const cfgA = JSON.parse(sql(`select public.zella_assistant_config('${ids.A}')::text`) || "{}");
  const cfgB = JSON.parse(sql(`select public.zella_assistant_config('${ids.B}')::text`) || "{}");
  const toolsOf = (c) => JSON.stringify(c?.assistant?.model?.tools ?? c?.model?.tools ?? c?.tools ?? c);
  const first = (c) => c?.assistant?.firstMessage ?? c?.firstMessage ?? "";
  check(ind.slug, "A", "the assistant opens with the setup greeting", /Hello from A/.test(first(cfgA)), first(cfgA) || JSON.stringify(cfgA).slice(0, 200));
  check(ind.slug, "A", "and is set up for English and Spanish", /es|multi|spanish/i.test(JSON.stringify(cfgA?.assistant?.transcriber ?? cfgA?.transcriber ?? cfgA)), JSON.stringify(cfgA?.assistant?.transcriber ?? cfgA?.transcriber ?? {}).slice(0, 200));
  check(ind.slug, "B", "the assistant's tools leave out booking, rescheduling and cancelling", !/book_appointment|check_availability|reschedule_appointment|cancel_appointment/.test(toolsOf(cfgB)) && /search_knowledge|take_message/.test(toolsOf(cfgB)), toolsOf(cfgB).slice(0, 200));
  if (ASSISTANT) {
    for (const v of ["A", "B"]) {
      const num = `+1512556${String(k).padStart(2, "0")}0${v === "A" ? 1 : 2}`;
      sql(`insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) select '${ids[v]}', '${num}', 'vpn-${ids[v]}' where not exists (select 1 from business_phone_numbers where e164 = '${num}')`);
    }
    const a = await vapi({ type: "assistant-request", call: { id: `ar-${ids.A}`, phoneNumberId: `vpn-${ids.A}`, customer: { number: "+15125550001" } }, phoneNumber: { number: `+1512556${String(k).padStart(2, "0")}01` } });
    const b = await vapi({ type: "assistant-request", call: { id: `ar-${ids.B}`, phoneNumberId: `vpn-${ids.B}`, customer: { number: "+15125550002" } }, phoneNumber: { number: `+1512556${String(k).padStart(2, "0")}02` } });
    check(ind.slug, "A", "a call fetches A's own current assistant through voice-rules (greeting, its business)", a.status === 200 && /Hello from A/.test(a.json?.assistant?.firstMessage ?? "") && a.json?.assistant?.metadata?.business_id === ids.A, a.text.slice(0, 200));
    check(ind.slug, "B", "a call fetches B's assistant, without booking tools", b.status === 200 && b.json?.assistant?.metadata?.business_id === ids.B && !/book_appointment|cancel_appointment/.test(JSON.stringify(b.json?.assistant?.model?.tools ?? "x")), b.text.slice(0, 200));
  }
  console.log(`${ind.slug.padEnd(24)} ${results.filter((x) => x.industry === ind.slug && !x.pass).length ? "FAILED" : "ok"}`);
}
if (ASSISTANT) sql(`delete from platform_settings where key in (${TEST_SETTINGS.map((x) => `'${x}'`).join(", ")})`);
mkdirSync(new URL("./out/", import.meta.url), { recursive: true });
writeFileSync(new URL("./out/matrix.json", import.meta.url), JSON.stringify(results, null, 1));
console.log(`\n${list.length} industries, ${list.length * 2} businesses, ${passes + fails} checks: ${passes} passed, ${fails} failed`);
process.exit(fails ? 1 : 0);
