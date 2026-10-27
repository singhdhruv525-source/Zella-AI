// Drives the shipped Brain Tools code nodes (plan -> per call: find business, use business, run tool, build reply -> collect)
// against the patched staging copy of the live database functions. Supabase calls are real SQL calls; one is failed on purpose.
import { execFileSync } from 'node:child_process';
import { runCode, runCodeAll } from '../../n8n/src/load.mjs';
const sql = (q) => execFileSync('su', ['nobody', '-s', '/bin/bash', '-c', process.env.ZPSQL + ' -d ' + (process.env.ZDB || 'zvoice')], { input: q }).toString().trim();
const lit = (v) => v === null || v === undefined ? 'null' : typeof v === 'object' ? "'" + JSON.stringify(v).replace(/'/g, "''") + "'::jsonb" : "'" + String(v).replace(/'/g, "''") + "'";
const rpc = (fn, args, fail) => { if (fail) return { statusCode: 503, body: { message: 'upstream unavailable' } };
  return { statusCode: 200, body: JSON.parse(sql(`select to_jsonb(public.${fn}(${Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(', ')}))::text`)) }; };
let pass = 0, fail = 0; const ok = (c, m) => { c ? pass++ : fail++; console.log((c ? 'PASS ' : 'FAIL ') + m); };
function flow(message, failTool) {
  const items = runCodeAll('brain-tool-plan.js', { items: [{ json: { body: { message } } }] }).map((i) => i.json);
  if (!items[0].record) return { results: [] };
  const replies = items.map((it) => {
    const found = rpc('zella_business_for_number', it.lookup);
    const use = runCode('business-apply.js', { json: found, nodes: { Plan: it } }).json;
    const res = rpc('zella_ai_tool', use.record, use.record.p_tool === failTool);
    return { json: runCode('brain-tool-reply.js', { json: res, nodes: { 'Use business': use } }).json };
  });
  return runCodeAll('brain-tool-collect.js', { items: replies })[0].json;
}
const call = { id: 'vapi-int-1', type: 'inboundPhoneCall', customer: { number: '+15551230001' }, phoneNumber: { number: '+15550001000' }, phoneNumberId: 'pn-A' };
const book = { start: '2026-11-02T15:00:00Z', first_name: 'Ana', phone: '+15551230001', confirmed: true, title: 'Cleaning' };
const msg = { type: 'tool-calls', call, toolCallList: [
  { id: 'tc-1', name: 'lookup_caller', arguments: {} },
  { id: 'tc-2', name: 'check_availability', arguments: { date: '2026-11-02', days: 1 } },
  { id: 'tc-3', name: 'book_appointment', arguments: book },
  { id: 'tc-4', name: 'book_appointment', arguments: book },
  { id: 'tc-5', name: 'search_knowledge', arguments: { query: 'parking' } },
  { id: 'tc-6', name: 'not_a_tool', arguments: {} }] };
const r1 = flow(msg, 'search_knowledge');
const byId = Object.fromEntries(r1.results.map((x) => [x.toolCallId, x]));
ok(r1.results.length === 6 && ['tc-1', 'tc-2', 'tc-3', 'tc-4', 'tc-5', 'tc-6'].every((k) => byId[k]), 'six tool calls in one request -> six answers, each under its own toolCallId');
ok(JSON.parse(byId['tc-1'].result).first_name === 'Ana', 'tc-1 lookup_caller: caller recognised from the network number');
ok(Array.isArray(JSON.parse(byId['tc-2'].result).times), 'tc-2 check_availability: times offered');
const b3 = JSON.parse(byId['tc-3'].result), b4 = JSON.parse(byId['tc-4'].result);
ok(b3.status === 'booked' && b4.status === 'booked', 'tc-3/tc-4 the model asked to book twice: both answered "booked" (second is "already booked")');
ok(sql("select count(*) from appointments where start_time = '2026-11-02T15:00:00Z'") === '1', 'exactly one appointment created');
ok(byId['tc-5'].error && !byId['tc-5'].result, 'tc-5 failed upstream: answered with the error field; the other answers are not lost');
ok(JSON.parse(byId['tc-6'].result).status === 'unknown_tool', 'tc-6 unknown tool: answered "not something you can do", nothing done');
ok(r1.results.every((x) => !String(x.result || x.error).includes('\n')), 'every answer is a single line');
// Vapi redelivers the same webhook (same tool call ids): nothing happens twice, same answers
const r2 = flow(msg, null);
const b3b = JSON.parse(r2.results.find((x) => x.toolCallId === 'tc-3').result);
ok(b3b.status === 'booked' && sql("select count(*) from appointments where start_time = '2026-11-02T15:00:00Z'") === '1', 'redelivered request: same "booked" answer, still one appointment');
ok(sql("select count(*) from calls where external_call_id = 'vapi-int-1'") <= '1', 'at most one call row for the call');
// a call on another business's number can't see or book this business's data
const other = flow({ type: 'tool-calls', call: { ...call, id: 'vapi-int-2', phoneNumber: { number: '+15550002000' }, phoneNumberId: 'pn-B' },
  toolCallList: [{ id: 'x-1', name: 'lookup_caller', arguments: {} }, { id: 'x-2', name: 'find_my_appointments', arguments: {} }] }, null);
const o1 = JSON.parse(other.results[0].result), o2 = JSON.parse(other.results[1].result);
ok(o1.status === 'not_recognised' && !(o2.appointments || []).length, "other business's line: caller unknown there, none of Ana's appointments visible");
// transfer through the brain endpoint never reveals the number to the model
sql(`insert into ai_agents (id, business_id, name, agent_type, is_default) values ('a0000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-000000000001', 'R', 'receptionist', true);
     insert into ai_agent_configs (agent_id, escalation_rules) values ('a0000000-0000-4000-8000-00000000000a', '{"transfer_number": "+15550101111", "transfer_open_hours_only": false}');`);
const t = flow({ type: 'tool-calls', call, toolCallList: [{ id: 't-1', name: 'transfer_to_human', arguments: { reason: 'wants a person' } }] }, null);
ok(JSON.parse(t.results[0].result).use_transfer_tool === true && !t.results[0].result.includes('5550101111'), 'transfer_to_human: "use the transfer tool", number not exposed to the model');

// ---- the older single-purpose webhooks, now one answer per tool call (same staging database)
const tryRpc = (fn, args) => { try { return rpc(fn, args); } catch { return { statusCode: 400, body: { message: 'refused' } }; } };
function oldFlow(planFile, vars, replyFile, fnOf, message) {
  const items = runCodeAll(planFile, { items: [{ json: { body: { message } } }], vars }).map((i) => i.json);
  if (!items[0].record) return { results: [] };
  const replies = items.map((it) => {
    const use = runCode('business-apply.js', { json: rpc('zella_business_for_number', it.lookup), nodes: { Plan: it } }).json;
    return { json: runCode(replyFile, { json: tryRpc(fnOf(use), use.record), nodes: { 'Use business': use } }).json };
  });
  return runCodeAll('brain-tool-collect.js', { items: replies })[0].json;
}
const BOOK = { ONLY_TOOLS: 'check_availability,book_appointment,find_my_appointments,reschedule_appointment,cancel_appointment' };
const bcall = { ...call, id: 'vapi-int-3', customer: { number: '+15551230003' } };
const bslot = { start: '2026-11-02T17:00:00Z', first_name: 'Bo', phone: '+15551230003', title: 'Cleaning' };
const bk = (list) => oldFlow('brain-tool-plan.js', BOOK, 'brain-tool-reply.js', () => 'zella_ai_tool', { type: 'tool-calls', call: bcall, toolCallList: list });
const k1 = bk([{ id: 'k-1', name: 'book_appointment', arguments: bslot }, { id: 'k-2', name: 'update_caller', arguments: { first_name: 'Evil' } }, { id: 'k-3', name: 'check_availability', arguments: { date: '2026-11-02', days: 1 } }]);
const kb = Object.fromEntries(k1.results.map((x) => [x.toolCallId, JSON.parse(x.result || '{}')]));
ok(k1.results.length === 3 && sql("select count(*) from appointments where start_time = '2026-11-02T17:00:00Z'") === '0', 'booking webhook: 3 tool calls -> 3 answers; booking without the caller\'s yes books nothing');
ok(kb['k-2'].status === 'unknown_tool' && Array.isArray(kb['k-3'].times), 'booking webhook: a non-booking tool is refused, availability still answered');
const k2 = bk([{ id: 'k-4', name: 'book_appointment', arguments: { ...bslot, confirmed: true } }]), k2b = bk([{ id: 'k-4', name: 'book_appointment', arguments: { ...bslot, confirmed: true } }]);
ok(JSON.parse(k2.results[0].result).status === 'booked' && JSON.parse(k2b.results[0].result).status === 'booked' && sql("select count(*) from appointments where start_time = '2026-11-02T17:00:00Z'") === '1', 'booking webhook: confirmed booking goes through zella_ai_tool; redelivery answers the same, one appointment');
ok(sql("select count(*) from ai_tool_calls where idempotency_key = 'vapi-int-3:k-4'") === '1', 'booking webhook: audited in ai_tool_calls');
// Voice Rules: an invalid action is refused by the database and leaves nothing behind
const vcall = { ...call, id: 'vapi-int-4' };
const v = oldFlow('voice-tool-plan.js', {}, 'voice-tool-reply.js', (u) => u.rpc, { type: 'tool-calls', call: vcall, toolCallList: [
  { id: 'v-1', name: 'call_rules', arguments: { action: 'drop_everything' } }, { id: 'v-2', name: 'call_rules', arguments: { action: 'rules' } }, { id: 'v-3', name: 'transfer_now', arguments: {} }] });
const vb = Object.fromEntries(v.results.map((x) => [x.toolCallId, x]));
ok(v.results.length === 3 && vb['v-1'].error && vb['v-3'].error && JSON.parse(vb['v-2'].result).instruction, 'voice rules webhook: 3 tool calls -> 3 answers; bad action and other tool get the error field');
ok(sql("select count(*) from calls where external_call_id = 'vapi-int-4'") === '1', 'voice rules webhook: one call row (the refused action rolled back its own)');
// Assistant Tools: each question logged once under its own tool call; junk logs nothing
const before = sql("select count(*) from knowledge_gaps");
const a2 = oldFlow('vapi-tool-plan.js', {}, 'vapi-tool-reply.js', (u) => u.rpc, { type: 'tool-calls', call: { ...call, id: 'vapi-int-5' }, toolCallList: [
  { id: 'q-1', name: 'report_unanswered_question', arguments: { question: 'Do you take insurance?' } }, { id: 'q-2', name: 'report_unanswered_question', arguments: { question: 'Is there parking nearby?' } }, { id: 'q-3', name: 'report_unanswered_question', arguments: {} }] });
ok(a2.results.length === 3 && a2.results.every((x) => typeof x.result === 'string'), 'assistant tools webhook: 3 tool calls -> 3 answers');
ok(Number(sql("select count(*) from knowledge_gaps")) - Number(before) === 2, 'assistant tools webhook: two questions logged, the empty one refused');
console.log(`${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
