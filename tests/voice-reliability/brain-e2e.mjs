// The 14 Receptionist Brain tools through the voice-rules edge function over HTTP, against the staging database
// (mock-rest.mjs), every request signed like Vapi (vapi-client.mjs). Resets the fixture itself. Staging only.
import { readFileSync } from 'node:fs';
import { P, send, sign, now, sql, control, callA, counter } from './vapi-client.mjs';
const { ok, done } = counter();
const A = 'aaaaaaaa-0000-4000-8000-000000000001', B = 'bbbbbbbb-0000-4000-8000-000000000002';
const SPAM = sql("select to_regclass('public.spam_list_entries') is not null") === 't';
control('');
sql(readFileSync(new URL('./fixture.sql', import.meta.url), 'utf8'));
sql(`insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('${A}', '+15550001000', 'pn-A'), ('${B}', '+15550002000', 'pn-B');
  insert into ai_agents (id, business_id, name, agent_type, is_default) values ('a0000000-0000-4000-8000-00000000000a', '${A}', 'R', 'receptionist', true), ('b0000000-0000-4000-8000-00000000000b', '${B}', 'R', 'receptionist', true);
  insert into ai_agent_configs (agent_id, escalation_rules) values ('a0000000-0000-4000-8000-00000000000a', '{"transfer_number": "+15550101111", "transfer_open_hours_only": false, "emergency_enabled": true}'), ('b0000000-0000-4000-8000-00000000000b', '{"transfer_enabled": false}');
  delete from knowledge_items;
  insert into knowledge_items (business_id, kind, title, answer, status) values ('${A}', 'faq', 'Parking', 'Free parking behind the building.', 'ready'), ('${B}', 'faq', 'Parking', 'OTHER-BUSINESS-ONLY parking answer.', 'ready');`);
const tc = (id, name, args = {}) => ({ id, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const tools = async (callId, list, extra = {}) => {
  const r = await P({ message: { type: 'tool-calls', call: callA(callId, extra), toolCallList: list } });
  const body = await r.json();
  return { status: r.status, timing: r.headers.get('server-timing'), results: body.results, by: Object.fromEntries((body.results || []).map((x) => [x.toolCallId, x])) };
};
const res = (x) => { try { return JSON.parse(x.result); } catch { return {}; } };
const count = (q) => Number(sql(q));

// ---- every tool, through one endpoint; each answer under its own id, with its name
const r1 = await tools('b-1', [tc('1', 'search_knowledge', { query: 'parking' }), tc('2', 'check_open_hours'), tc('3', 'lookup_caller'),
  tc('4', 'check_availability', { date: '2026-11-02', days: 1 }), tc('5', 'find_my_appointments'), tc('6', 'take_message', { message: 'please call me back' }),
  tc('7', 'report_emergency', { summary: 'water leaking from the ceiling' }), tc('8', 'report_unanswered_question', { question: 'Do you take dental insurance?' })]);
ok(r1.status === 200 && r1.results.length === 8 && r1.results.every((x, i) => x.toolCallId === String(i + 1)), 'eight tools in one request -> eight answers, in order, each under its own toolCallId');
ok(r1.results.every((x) => x.name === ['search_knowledge', 'check_open_hours', 'lookup_caller', 'check_availability', 'find_my_appointments', 'take_message', 'report_emergency', 'report_unanswered_question'][Number(x.toolCallId) - 1]), 'each answer names its tool');
const s1 = res(r1.by['1']);
ok(s1.status === 'confirmed' && JSON.stringify(s1.results).includes('Free parking') && !JSON.stringify(s1).includes('OTHER-BUSINESS'), 'search_knowledge: this business\'s approved answer only');
ok(res(r1.by['2']).status === 'open' || res(r1.by['2']).status === 'closed', 'check_open_hours: answered from the business hours (' + res(r1.by['2']).status + ')');
ok(res(r1.by['3']).first_name === 'Ana', 'lookup_caller: recognised by the network number');
ok(Array.isArray(res(r1.by['4']).times) && res(r1.by['4']).times.length > 0, 'check_availability: real open times');
ok(Array.isArray(res(r1.by['5']).appointments), 'find_my_appointments: the caller\'s own list');
ok(res(r1.by['6']).status === 'message_saved', 'take_message: saved');
// with a transfer number set the database puts an emergency straight through to a person; the number stays hidden
ok(r1.by['7'].result && ['transfer', 'alerted', 'emergency'].includes(res(r1.by['7']).status) && !r1.by['7'].result.includes('5550101111'), 'report_emergency: raised (' + res(r1.by['7']).status + '), number not exposed');
ok(res(r1.by['8']).status === 'logged' && count("select count(*) from knowledge_gaps where question ilike '%dental insurance%'") === 1, 'report_unanswered_question: logged once');
const r2 = await tools('b-1', [tc('9', 'update_caller', { email: 'ana@example.com', preferred_contact_method: 'sms' }), tc('10', 'request_follow_up', { reason: 'wants a quote for whitening' }),
  tc('11', 'transfer_to_human', { reason: 'wants a person' }), tc('12', 'book_appointment', { start: res(r1.by['4']).times[0].start, first_name: 'Ana', phone: '+15551230001', confirmed: true })]);
ok(res(r2.by['9']).status === 'saved' && sql(`select email || '/' || preferred_contact_method from customers where id = 'cccccccc-0000-4000-8000-000000000001'`) === 'ana@example.com/sms', 'update_caller: saved on the caller\'s own record');
ok(res(r2.by['10']).status === 'requested', 'request_follow_up: task created');
const tr = res(r2.by['11']);
ok(tr.status === 'transfer' && tr.use_transfer_tool === true && !r2.by['11'].result.includes('5550101111'), 'transfer_to_human: allowed, told to use the transfer tool, number NOT exposed');
const booked = res(r2.by['12']);
ok(booked.status === 'booked' && count(`select count(*) from appointments where business_id = '${A}' and booking_state = 'confirmed' and status in ('scheduled','confirmed')`) === 1, 'book_appointment (confirmed): booked, one appointment');
const apptId = sql(`select id from appointments where business_id = '${A}' limit 1`);
const times = res(r1.by['4']).times;
const r3 = await tools('b-1', [tc('13', 'reschedule_appointment', { appointment_id: apptId, start: times[1].start, confirmed: true })]);
ok(res(r3.by['13']).status === 'rescheduled' && sql(`select abs(extract(epoch from start_time - '${times[1].start}'::timestamptz)) < 60 from appointments where id = '${apptId}'`) === 't', 'reschedule_appointment (confirmed): moved, verified');
const r4 = await tools('b-1', [tc('14', 'cancel_appointment', { appointment_id: apptId, confirmed: true })]);
ok(res(r4.by['14']).status === 'cancelled' && sql(`select status from appointments where id = '${apptId}'`) === 'cancelled', 'cancel_appointment (confirmed): cancelled, verified');
ok(count("select count(*) from ai_tool_calls where provider_call_id = 'b-1'") === 14, 'all 14 tools audited in ai_tool_calls (one row each)');

// ---- confirmation is required before booking, moving or cancelling
const slot = times[2].start;
const nc = await tools('b-2', [tc('n1', 'book_appointment', { start: slot, first_name: 'Ana', phone: '+15551230001' }), tc('n2', 'book_appointment', { start: slot, first_name: 'Ana', confirmed: 'yes' }),
  tc('n3', 'cancel_appointment', { appointment_id: apptId }), tc('n4', 'reschedule_appointment', { appointment_id: apptId, start: slot })]);
ok(nc.results.every((x) => res(x).status === 'need_confirmation') && count(`select count(*) from appointments where start_time = '${slot}'`) === 0, 'no confirmed=true (missing, or "yes" as text): nothing booked, moved or cancelled');

// ---- repeated delivery and replay
const bookMsg = { message: { type: 'tool-calls', call: callA('b-3'), toolCallList: [tc('d1', 'book_appointment', { start: slot, first_name: 'Ana', phone: '+15551230001', confirmed: true })] } };
const raw = JSON.stringify(bookMsg);
const ts = now(), sig = sign(raw, ts);
const first = await (await send(raw, { 'x-timestamp': ts, 'x-signature': sig })).json();
const replay = await send(raw, { 'x-timestamp': ts, 'x-signature': sig });
ok(replay.status === 401, 'exact replay of a signed booking request: 401, nothing run');
const again = await (await P(bookMsg, { ts: String(Number(ts) + 2) })).json();   // Vapi re-sending the same tool call later, freshly signed
ok(res(first.results[0]).status === 'booked' && res(again.results[0]).status === 'booked' && count(`select count(*) from appointments where start_time = '${slot}' and status <> 'cancelled'`) === 1,
  'same tool call delivered again: same "booked" answer, still one appointment');
ok(count("select count(*) from ai_tool_calls where idempotency_key = 'b-3:d1' and status = 'done'") === 1, 'one completed audit row for that tool call');

// ---- 10 different calls trying to book the same time at once
const race = times[3].start;
const racers = await Promise.all(Array.from({ length: 10 }, (_, i) => tools('race-' + i, [tc('r', 'book_appointment', { start: race, first_name: 'C' + i, phone: '+1555777' + String(i).padStart(4, '0'), confirmed: true })],
  { customer: { number: '+1555777' + String(i).padStart(4, '0') } })));
const won = racers.filter((x) => res(x.results[0]).status === 'booked').length;
ok(won === 1 && count(`select count(*) from appointments where start_time = '${race}' and status <> 'cancelled' and booking_state = 'confirmed'`) === 1, `10 simultaneous HTTP bookings of one time: ${won} booked, one appointment`);

// ---- business isolation: B's line, even claiming A in its call settings
sql(`insert into appointments (business_id, customer_id, title, start_time, end_time) values ('${A}', 'cccccccc-0000-4000-8000-000000000001', 'A only', '2026-11-04T15:00:00Z', '2026-11-04T15:30:00Z')`);
const aAppt = sql(`select id from appointments where title = 'A only'`);
const iso = await tools('b-4', [tc('i1', 'find_my_appointments'), tc('i2', 'cancel_appointment', { appointment_id: aAppt, confirmed: true }), tc('i3', 'search_knowledge', { query: 'parking' }), tc('i4', 'lookup_caller'), { id: 'i5', name: 'call_rules', arguments: { action: 'rules' } }],
  { phoneNumber: { number: '+15550002000' }, phoneNumberId: 'pn-B', metadata: { business_id: A } });
ok(!(res(iso.by['i1']).appointments || []).some((x) => x.appointment_id === aAppt), 'B\'s line: none of A\'s appointments are visible');
ok(res(iso.by['i2']).status !== 'cancelled' && sql(`select status from appointments where id = '${aAppt}'`) !== 'cancelled', 'B\'s line: A\'s appointment id can\'t be cancelled');
ok(!JSON.stringify(res(iso.by['i3'])).includes('Free parking') && JSON.stringify(res(iso.by['i3'])).includes('OTHER-BUSINESS'), 'B\'s line: B\'s knowledge only');
ok(res(iso.by['i4']).status === 'not_recognised', 'B\'s line: A\'s customer is not recognised there');
ok(sql("select business_id from calls where external_call_id = 'b-4'") === B, 'the call row (created by call_rules) belongs to B, not the business the call settings claimed');

// ---- invalid arguments and unknown tools: answered, nothing run
const before = count('select count(*) from ai_tool_calls');
const bad = await tools('b-5', [tc('v1', 'check_availability', { date: 'next tuesday' }), tc('v2', 'book_appointment', { start: 'tomorrow at 3', first_name: 'X', confirmed: true }),
  tc('v3', 'cancel_appointment', { appointment_id: "1; drop table appointments", confirmed: true }), tc('v4', 'check_availability', { days: 99 }),
  tc('v5', 'update_caller', { preferred_contact_method: 'pigeon' }), tc('v6', 'delete_all_customers'), tc('v7', 'check_open_hours')]);
ok(['v1', 'v2', 'v3', 'v4', 'v5'].every((k) => /^Invalid arguments: /.test(bad.by[k].error || '')), 'malformed date, start, appointment id, days, contact method: error answer saying what to fix');
ok(/not available/.test(bad.by.v6.error || '') && res(bad.by.v7).status, 'unknown tool refused; the valid tool in the same request still answered');
ok(count('select count(*) from ai_tool_calls') === before + 1, 'only the valid tool reached the database');
const malformedArgs = await tools('b-5', [{ id: 'm1', function: { name: 'lookup_caller', arguments: '{not json' } }, { id: 'm2', name: 'lookup_caller', arguments: [1, 2] }]);
ok(malformedArgs.results.length === 2 && malformedArgs.results.every((x) => x.result), 'unparseable or non-object arguments: treated as empty, still answered');

// ---- spam protection (only on databases with the spam migration)
if (SPAM) {
  sql(`insert into spam_list_entries (business_id, list, channel, value_type, value, reason) values ('${A}', 'block', 'call', 'phone', public.zella_digits('+15559990666'), 'test')`);
  const blk = await tools('b-6', [tc('s1', 'book_appointment', { start: times[4].start, first_name: 'X', confirmed: true }), tc('s2', 'find_my_appointments'), tc('s3', 'report_emergency', { summary: 'fire' })],
    { customer: { number: '+15559990666' } });
  ok(res(blk.by.s1).status === 'screened' && res(blk.by.s2).status === 'screened' && count(`select count(*) from appointments where start_time = '${times[4].start}'`) === 0, 'spam-screened caller: tools refused by the server, nothing booked');
  ok(res(blk.by.s3).status !== 'screened', 'spam-screened caller: an emergency still goes through');
} else console.log('skip  spam-screened caller checks (spam migration not applied on this database)');

// ---- rate limit (only where zella_rate_limit exists): 30 tool calls a minute per call, then safe answers
if (sql("select to_regprocedure('public.zella_rate_limit(text, integer, integer)') is not null") === 't') {
  const rl = [];
  for (let k = 0; k < 4; k++) rl.push(...(await tools('rl-1', Array.from({ length: 10 }, (_, i) => tc('q' + k + '-' + i, 'check_open_hours')))).results);
  const answered = rl.filter((x) => x.result).length;
  ok(answered === 30 && rl.length === 40 && rl.filter((x) => x.error).length === 10, `rate limit: 40 tool calls on one call -> ${answered} answered, the rest refused safely`);
} else console.log('skip  rate limit check (zella_rate_limit not on this database)');

// ---- dependencies failing: every tool call still gets a valid, safe answer
control('down:zella_ai_tool:search_knowledge');
const part = await tools('b-7', [tc('p1', 'search_knowledge', { query: 'parking' }), tc('p2', 'lookup_caller')]);
ok(part.by.p1.error && !part.by.p1.result && res(part.by.p2).first_name === 'Ana', 'one tool\'s database call fails: that one gets the error field, the other is answered');
control('junk:zella_ai_tool');
const junk = await tools('b-7', [tc('j1', 'lookup_caller'), tc('j2', 'check_open_hours')]);
ok(junk.results.every((x) => x.error && !x.result), 'malformed database response: error answers, nothing claimed');
control('slow:zella_ai_tool');
let t0 = Date.now();
const slow = await tools('b-7', [tc('t1', 'check_availability'), tc('t2', 'book_appointment', { start: '2026-11-02T20:00:00Z', first_name: 'Ana', confirmed: true })]);
const took = Date.now() - t0;
ok(slow.results.every((x) => x.error) && took < 6000, `database too slow: both answered with the error field within the budget (${took} ms; tools run in parallel)`);
control('down:zella_business_for_number');
const before2 = count('select count(*) from ai_tool_calls');
const nolook = await tools('b-7', [tc('l1', 'lookup_caller'), tc('l2', 'book_appointment', { start: '2026-11-02T20:00:00Z', first_name: 'Ana', confirmed: true })]);
ok(nolook.results.every((x) => x.error) && count('select count(*) from ai_tool_calls') === before2, 'business lookup unavailable: error answers, no tool run');
control('');

// ---- call_rules and Brain tools mixed in one request; timing header present
const mix = await tools('b-8', [{ id: 'x1', name: 'call_rules', arguments: { action: 'rules' } }, tc('x2', 'lookup_caller')]);
ok(res(mix.by.x1).status && res(mix.by.x2).first_name === 'Ana' && mix.by.x1.name === 'call_rules', 'call_rules and a Brain tool in one request: both answered');
ok(/auth;dur=\d+/.test(mix.timing || '') && /tools;dur=\d+/.test(mix.timing || '') && /total;dur=\d+/.test(mix.timing || ''), 'Server-Timing reports auth, lookup, tools and total');
process.exit(done() ? 1 : 0);
