// Tests for the n8n workflows. Run: node n8n/test.mjs
// 1) Runs the exact Code-node logic that ships. 2) Checks the workflow files are well formed.
// It does NOT import into n8n (the installed n8n version has not been checked).
import { readFileSync } from 'node:fs';
import { strict as assert } from 'node:assert';
import { runCode, eventTypes } from './src/load.mjs';

let passed = 0;
const failures = [];
const test = (name, fn) => {
  try { fn(); passed++; } catch (e) { failures.push(name + ': ' + e.message); }
};

const BIZ = '3f1c2b4e-5a6d-4e7f-8a9b-0c1d2e3f4a5b';
const good = { business_id: BIZ, event_type: 'appointment.booked', source: 'staff', idempotency_key: 'appt-123-booked', payload: { a: 1 } };
const gate = (body) => runCode('gateway-validate.js', { json: { body } }).json;

// ---------------- gateway: check event
test('valid event passes and maps to rpc arguments', () => {
  const r = gate(good);
  assert.equal(r.valid, true);
  assert.equal(r.rpc.p_business_id, BIZ);
  assert.equal(r.rpc.p_provider_event_id, null);
  assert.deepEqual(r.rpc.p_payload, { a: 1 });
});
test('payload defaults to an empty object', () => assert.deepEqual(gate({ ...good, payload: undefined }).rpc.p_payload, {}));
test('every catalogue event name is accepted', () => { for (const t of eventTypes) assert.equal(gate({ ...good, event_type: t }).valid, true, t); });
test('unknown event type rejected', () => assert.equal(gate({ ...good, event_type: 'made.up' }).valid, false));
test('bad business id rejected', () => assert.equal(gate({ ...good, business_id: 'preview' }).valid, false));
test('missing business id rejected', () => assert.equal(gate({ ...good, business_id: undefined }).valid, false));
test('unknown source rejected', () => assert.equal(gate({ ...good, source: 'hacker' }).valid, false));
test('short idempotency key rejected', () => assert.equal(gate({ ...good, idempotency_key: 'abc' }).valid, false));
test('long idempotency key rejected', () => assert.equal(gate({ ...good, idempotency_key: 'x'.repeat(201) }).valid, false));
test('array payload rejected', () => assert.equal(gate({ ...good, payload: [1] }).valid, false));
test('oversized payload rejected', () => assert.equal(gate({ ...good, payload: { big: 'x'.repeat(61000) } }).valid, false));
test('bad correlation id rejected', () => assert.equal(gate({ ...good, correlation_id: 'nope' }).valid, false));
test('non-object body rejected', () => { assert.equal(gate('text').valid, false); assert.equal(gate(null).valid, false); assert.equal(gate([good]).valid, false); });
test('rejected event carries no rpc', () => assert.equal(gate({}).rpc, null));
test('bad request reply is 400', () => {
  const r = runCode('gateway-bad-request.js', { json: { errors: ['x'] } }).json;
  assert.equal(r.status, 400); assert.equal(r.body.ok, false);
});

// ---------------- gateway: reply
const reply = (statusCode, body) => runCode('gateway-map.js', { json: { statusCode, body } }).json;
test('stored event replies 200 with id', () => assert.deepEqual(reply(200, { id: 'e1', duplicate: false }), { status: 200, body: { ok: true, id: 'e1', duplicate: false } }));
test('duplicate is reported, still 200', () => assert.equal(reply(200, { id: 'e1', duplicate: true }).body.duplicate, true));
test('unknown business is 422', () => assert.equal(reply(400, { message: 'INVALID_BUSINESS' }).status, 422));
test('cancelled business is 422', () => assert.equal(reply(400, { message: 'BUSINESS_NOT_AVAILABLE' }).body.error, 'business_not_available'));
test('database failure is 502 with no details', () => {
  const r = reply(500, { message: 'relation "x" does not exist', hint: 'secret' });
  assert.equal(r.status, 502); assert.equal(JSON.stringify(r).includes('secret'), false);
});

// ---------------- router: route
const ev = (type, payload = {}) => ({ id: 'ev-1', business_id: BIZ, event_type: type, correlation_id: 'c-1', payload });
const route = (e) => runCode('router-route.js', { json: e }).json;
test('inbound sms goes to the keyword handler', () => {
  const r = route(ev('message.received', { channel: 'sms', from: '+14155550123', body: 'STOP' }));
  assert.equal(r.plan.rpc, 'zella_handle_inbound_sms_keyword');
  assert.deepEqual(r.plan.body, { p_business_id: BIZ, p_from: '+14155550123', p_body: 'STOP' });
});
test('inbound sms without a body is invalid input', () => assert.equal(route(ev('message.received', { channel: 'sms', from: '+1' })).problem.category, 'invalid_input'));
test('inbound email has no handler yet', () => assert.equal(route(ev('message.received', { channel: 'email', from: 'a@b.c', body: 'hi' })).problem.category, 'missing_configuration'));
test('opt-out records consent', () => {
  const r = route(ev('customer.opted_out', { channel: 'email', email: 'a@b.com' }));
  assert.equal(r.plan.rpc, 'zella_record_consent');
  assert.equal(r.plan.body.p_status, 'opted_out'); assert.equal(r.plan.body.p_purpose, 'marketing'); assert.equal(r.plan.body.p_source, 'system');
});
test('opt-out needs a way to find the person', () => assert.equal(route(ev('customer.opted_out', { channel: 'sms' })).problem.category, 'invalid_input'));
test('opt-out rejects an unknown channel', () => assert.equal(route(ev('customer.opted_out', { channel: 'pigeon', phone: '1' })).problem.category, 'invalid_input'));
test('integration disconnect raises an urgent alert', () => {
  const r = route(ev('integration.disconnected', { provider: 'telnyx', reason: 'token expired' }));
  assert.equal(r.plan.rpc, 'zella_platform_alert'); assert.equal(r.plan.body.p_severity, 'urgent'); assert.equal(r.plan.body.p_dedupe_key, 'telnyx');
});
test('integration reconnect resolves the alert', () => {
  const r = route(ev('integration.reconnected', { provider: 'telnyx' }));
  assert.equal(r.plan.rpc, 'zella_resolve_platform_alerts'); assert.equal(r.plan.body.p_dedupe_key, 'telnyx');
});
test('integration event without provider is invalid', () => assert.equal(route(ev('integration.disconnected', {})).problem.category, 'invalid_input'));
test('events with no handler are flagged, never silently done', () => {
  const r = route(ev('appointment.booked'));
  assert.equal(r.plan, null); assert.equal(r.problem.category, 'missing_configuration');
});
test('non-object payload is handled', () => assert.equal(route({ ...ev('integration.disconnected'), payload: 'x' }).problem.category, 'invalid_input'));

// ---------------- router: result
const result = (routeOut, startBody, handler) =>
  runCode('router-result.js', { json: handler ?? {}, nodes: { Route: routeOut, 'Start execution': { body: startBody } } }).json;
const planned = { event: { id: 'ev-1' }, plan: { rpc: 'zella_platform_alert', handler: 'integration_alert' }, problem: null };
test('success is ok', () => { const r = result(planned, 'exec-1', { statusCode: 200, body: 'uuid' }); assert.equal(r.ok, true); assert.equal(r.execution_id, 'exec-1'); assert.equal(r.needs_manual, false); });
test('keyword action is recorded in the steps', () => assert.equal(result(planned, 'x', { statusCode: 200, body: { action: 'opted_out' } }).steps[1].action, 'opted_out'));
test('429 is a temporary rate limit', () => { const r = result(planned, 'x', { statusCode: 429, body: {} }); assert.equal(r.category, 'rate_limited'); assert.equal(r.needs_manual, false); });
test('500 is temporary', () => assert.equal(result(planned, 'x', { statusCode: 503, body: {} }).category, 'temporary_network'));
test('504 is a provider timeout', () => assert.equal(result(planned, 'x', { statusCode: 504, body: {} }).category, 'provider_timeout'));
test('401 is permanent and needs a person', () => { const r = result(planned, 'x', { statusCode: 401, body: {} }); assert.equal(r.category, 'authentication_failure'); assert.equal(r.needs_manual, true); });
test('tenant mismatch is permanent', () => assert.equal(result(planned, 'x', { statusCode: 400, body: { message: 'TENANT_MISMATCH' } }).category, 'tenant_mismatch'));
test('not allowed is a permission failure', () => assert.equal(result(planned, 'x', { statusCode: 400, body: { message: 'NOT_ALLOWED' } }).category, 'permission_failure'));
test('other 400 is invalid input', () => assert.equal(result(planned, 'x', { statusCode: 400, body: { message: 'oops' } }).category, 'invalid_input'));
test('no handler becomes a failed, manual result', () => {
  const r = result({ event: { id: 'ev-2' }, plan: null, problem: { category: 'missing_configuration', message: 'No handler' } }, 'x');
  assert.equal(r.ok, false); assert.equal(r.category, 'missing_configuration'); assert.equal(r.needs_manual, true);
});
test('error text never includes the database response body', () => assert.equal(result(planned, 'x', { statusCode: 400, body: { message: 'SECRET' } }).error.includes('SECRET'), false));
test('execution id is optional when logging failed to start', () => assert.equal(result(planned, { message: 'down' }, { statusCode: 200, body: {} }).execution_id, null));

// ---------------- workflow files
// ---------------- schedulers: check
const sched = (statusCode, body) => runCode('scheduler-check.js', { json: { statusCode, body }, vars: { JOB: 'zella_expire_holds' } }).json;
test('scheduler job success carries the count and no alert', () => { const r = sched(200, 3); assert.equal(r.ok, true); assert.equal(r.count, 3); assert.equal(r.alert, null); });
test('scheduler job success with a non-number body has no count', () => assert.equal(sched(200, null).count, null));
test('scheduler job failure raises a grouped alert', () => {
  const r = sched(500, { message: 'secret detail' });
  assert.equal(r.ok, false); assert.equal(r.alert.p_kind, 'scheduler_failed'); assert.equal(r.alert.p_dedupe_key, 'zella_expire_holds'); assert.equal(r.alert.p_business_id, null);
  assert.equal(JSON.stringify(r).includes('secret detail'), false);
});
test('scheduler 404 (function missing) also alerts', () => assert.equal(sched(404, {}).ok, false));

// ---------------- scheduler workflow: every job is wired and none is a trigger-only function
const schedFile = JSON.parse(readFileSync(new URL('./workflows/zella-schedulers.json', import.meta.url), 'utf8'));
test('scheduler workflow runs 10 jobs', () => assert.equal(schedFile.nodes.filter((n) => n.name.startsWith('Run ')).length, 10));
test('trigger-only functions are not scheduled', () => {
  const t = JSON.stringify(schedFile);
  assert.ok(!t.includes('zella_calls_to_callbacks') && !t.includes('zella_queue_no_show_followup'));
});
test('each job node calls its own function', () => {
  for (const n of schedFile.nodes.filter((x) => x.name.startsWith('Run '))) assert.ok(n.parameters.url.endsWith('/rpc/' + n.name.slice(4)), n.name);
});
test('each job check names its own job', () => {
  for (const n of schedFile.nodes.filter((x) => x.name.startsWith('Check '))) assert.ok(n.parameters.jsCode.includes("'" + n.name.slice(6) + "'"), n.name);
});

// ---------------- sms sender
const R = { reminder_id: '11111111-1111-4111-8111-111111111111', kind: 'reminder', channel: 'sms',
  business: { id: BIZ, name: 'Test Salon', timezone: 'America/New_York' }, customer: { id: 'cust-1', first_name: 'Ana', phone: '4155550123' },
  appointment: { id: 'a1', title: 'haircut', start_time: '2026-11-03T15:00:00Z' } };
const plan = (r) => runCode('sms-plan.js', { json: r }).json;
test('plan builds the prepare request with business-time date and time', () => {
  const p = plan(R);
  assert.equal(p.finish, null); assert.equal(p.prepare.p_template_key, 'appointment_reminder'); assert.equal(p.prepare.p_vars.date, 'Tue, Nov 3'); assert.equal(p.prepare.p_vars.time, '10:00 AM');
  assert.equal(p.prepare.p_vars.appointment, 'haircut'); assert.equal(p.prepare.p_purpose, 'transactional');
});
test('confirmation uses the confirmation template', () => assert.equal(plan({ ...R, kind: 'confirmation' }).prepare.p_template_key, 'appointment_confirmation'));
test('confirmation request uses the reminder template', () => assert.equal(plan({ ...R, kind: 'confirmation_request' }).prepare.p_template_key, 'appointment_reminder'));
test('non-text channel is skipped with a reason', () => { const p = plan({ ...R, channel: 'email' }); assert.equal(p.finish.rpc, 'zella_skip_reminder'); assert.match(p.finish.body.p_reason, /channel_not_supported_yet:email/); });
test('unknown kind is skipped', () => assert.equal(plan({ ...R, kind: 'weird' }).finish.rpc, 'zella_skip_reminder'));
test('bad appointment time is skipped, not sent', () => assert.equal(plan({ ...R, appointment: { title: 'x', start_time: 'nope' } }).finish.rpc, 'zella_skip_reminder'));
test('missing title falls back to "appointment"', () => assert.equal(plan({ ...R, appointment: { start_time: R.appointment.start_time } }).prepare.p_vars.appointment, 'appointment'));

const smsPlan = { reminder_id: R.reminder_id, business_id: BIZ, customer_id: 'cust-1' };
const decide = (statusCode, body) => runCode('sms-decide.js', { json: { statusCode, body }, nodes: { Plan: smsPlan } }).json;
const okPrep = { allowed: true, live: false, to: '+14155550123', from: null, body: 'Hi Ana', template_id: 't1', template_version: 1 };
test('dry run is logged as dry_run', () => { const d = decide(200, okPrep); assert.equal(d.finish, null); assert.equal(d.log.p_status, 'dry_run'); assert.equal(d.live, false); assert.equal(d.log.p_dedupe_key, 'reminder:' + R.reminder_id); });
test('live is logged as queued', () => { const d = decide(200, { ...okPrep, live: true, from: '+15550001111' }); assert.equal(d.log.p_status, 'queued'); assert.equal(d.live, true); });
test('live without a sender number fails loudly', () => { const d = decide(200, { ...okPrep, live: true }); assert.equal(d.finish.body.p_ok, false); assert.equal(d.finish.body.p_error, 'sender_number_not_set'); });
test('no consent skips the reminder, no retry', () => { const d = decide(200, { allowed: false, reason: 'no_consent', live: true }); assert.equal(d.finish.rpc, 'zella_skip_reminder'); assert.equal(d.finish.body.p_reason, 'no_consent'); assert.equal(d.log, undefined); });
test('prepare failure is a retryable failure', () => { const d = decide(500, {}); assert.equal(d.finish.rpc, 'zella_complete_reminder'); assert.equal(d.finish.body.p_ok, false); });
test('prepare error text is not copied into the result', () => assert.equal(JSON.stringify(decide(500, { message: 'SECRETDETAIL' })).includes('SECRETDETAIL'), false));

const afterLog = (statusCode, body, d) => runCode('sms-after-log.js', { json: { statusCode, body }, nodes: { Decide: { reminder_id: R.reminder_id, live: true, from: '+15550001111', to: '+14155550123', text: 'Hi', ...d } } }).json;
test('live new message goes to Telnyx with the right payload', () => {
  const a = afterLog(200, { id: 'm1', duplicate: false, status: 'queued' });
  assert.equal(a.finish, null); assert.deepEqual(a.telnyx, { from: '+15550001111', to: '+14155550123', text: 'Hi', type: 'SMS' }); assert.equal(a.message_id, 'm1');
});
test('dry run never builds a Telnyx payload', () => { const a = afterLog(200, { id: 'm1', duplicate: false, status: 'dry_run' }, { live: false }); assert.equal(a.telnyx, undefined); assert.equal(a.finish.rpc, 'zella_skip_reminder'); assert.match(a.finish.body.p_reason, /dry_run/); });
test('already-sent duplicate is not sent again and completes ok', () => { const a = afterLog(200, { id: 'm1', duplicate: true, status: 'sent' }); assert.equal(a.telnyx, undefined); assert.equal(a.finish.body.p_ok, true); });
test('in-flight duplicate is suppressed', () => { const a = afterLog(200, { id: 'm1', duplicate: true, status: 'queued' }); assert.equal(a.telnyx, undefined); assert.equal(a.finish.body.p_reason, 'duplicate_suppressed'); });
test('log failure fails the reminder and sends nothing', () => { const a = afterLog(500, {}); assert.equal(a.telnyx, undefined); assert.equal(a.finish.body.p_ok, false); });

const afterSend = (statusCode, body) => runCode('sms-after-send.js', { json: { statusCode, body }, nodes: { 'After log': { reminder_id: R.reminder_id, message_id: 'm1' } } }).json;
test('Telnyx success records the external id and completes ok', () => { const a = afterSend(200, { data: { id: 'tx-1' } }); assert.deepEqual(a.update, { p_id: 'm1', p_status: 'sent', p_external_id: 'tx-1', p_error: null }); assert.equal(a.finish.body.p_ok, true); });
test('Telnyx 200 without an id is not trusted', () => assert.equal(afterSend(200, {}).update.p_status, 'failed'));
test('Telnyx rejection fails the message and lets the database retry', () => { const a = afterSend(422, { errors: [{ code: '40310', detail: 'PRIVATE DETAIL' }] }); assert.equal(a.update.p_status, 'failed'); assert.equal(a.finish.body.p_ok, false); assert.match(a.update.p_error, /422 \(code 40310\)/); assert.equal(JSON.stringify(a).includes('PRIVATE DETAIL'), false); });
test('Telnyx rate limit is a failure the database retries', () => assert.equal(afterSend(429, {}).finish.body.p_ok, false));

// ---------------- sms workflow shape
const smsFile = JSON.parse(readFileSync(new URL('./workflows/zella-sms-sender.json', import.meta.url), 'utf8'));
test('only the Telnyx node talks to Telnyx', () => {
  const t = smsFile.nodes.filter((n) => JSON.stringify(n.parameters).includes('api.telnyx.com'));
  assert.deepEqual(t.map((n) => n.name), ['Send via Telnyx']);
});
test('Telnyx node can only be reached after the live check', () => {
  const c = smsFile.connections;
  const into = Object.entries(c).filter(([, v]) => v.main.flat().some((l) => l.node === 'Send via Telnyx')).map(([k]) => k);
  assert.deepEqual(into, ['Send for real']);
  assert.equal(c['Send for real'].main[0][0].node, 'Send via Telnyx');
});
test('Telnyx box ships with no credential, so no other secret can be attached by accident', () => { const n = smsFile.nodes.find((x) => x.name === 'Send via Telnyx'); assert.equal(n.parameters.authentication, 'none'); assert.equal(n.credentials, undefined); });

// ---------------- follow-up texts
const T = { task_id: '22222222-2222-4222-8222-222222222222', kind: 'no_show_follow_up', channel: 'sms', business: { id: BIZ, name: 'Test Salon' }, customer: { id: 'cust-1', first_name: 'Ana' } };
const tplan = (t) => runCode('sms-task-plan.js', { json: t }).json;
test('no-show follow-up uses its template, transactional', () => { const p = tplan(T); assert.equal(p.finish, null); assert.equal(p.prepare.p_template_key, 'no_show_follow_up'); assert.equal(p.prepare.p_purpose, 'transactional'); });
test('quote and post-visit follow-ups are transactional', () => { for (const k of ['quote_follow_up', 'post_appointment_follow_up']) { const p = tplan({ ...T, kind: k }); assert.equal(p.prepare.p_template_key, k); assert.equal(p.prepare.p_purpose, 'transactional'); } });
test('reactivation is marketing, so it needs opt-in', () => assert.equal(tplan({ ...T, kind: 'lead_reactivation' }).prepare.p_purpose, 'marketing'));
test('a call task is skipped, never texted', () => { const p = tplan({ ...T, channel: 'call' }); assert.equal(p.finish.rpc, 'zella_skip_followup_task'); assert.match(p.finish.body.p_reason, /channel_not_supported_yet:call/); assert.equal(p.prepare, undefined); });
test('callback fallback for a missed call uses the missed-call text', () => { const p = tplan({ ...T, kind: 'callback_sms', callback_reason: 'missed_call' }); assert.equal(p.finish, null); assert.equal(p.prepare.p_template_key, 'missed_call_follow_up'); assert.equal(p.prepare.p_purpose, 'transactional'); });
test('callback fallback for a new lead uses the lead acknowledgement', () => assert.equal(tplan({ ...T, kind: 'callback_sms', callback_reason: 'new_lead' }).prepare.p_template_key, 'lead_acknowledgement'));
test('callback fallback with an unknown or missing reason is skipped', () => { for (const r of ['requested', undefined, null]) assert.match(tplan({ ...T, kind: 'callback_sms', callback_reason: r }).finish.body.p_reason, /unknown_callback_reason/); });
test('unknown task kind is skipped with a reason', () => assert.match(tplan({ ...T, kind: 'waitlist_offer' }).finish.body.p_reason, /unknown_followup_kind:waitlist_offer/));

const tPlanned = { task_id: T.task_id, business_id: BIZ, customer_id: 'cust-1' };
const tdecide = (statusCode, body) => runCode('sms-task-decide.js', { json: { statusCode, body }, nodes: { Plan: tPlanned } }).json;
test('task dry run is logged as dry_run with a task key', () => { const d = tdecide(200, okPrep); assert.equal(d.log.p_status, 'dry_run'); assert.equal(d.log.p_dedupe_key, 'task:' + T.task_id); assert.equal(d.live, false); });
test('task live without a sender number fails and retries later', () => { const d = tdecide(200, { ...okPrep, live: true }); assert.equal(d.finish.body.p_outcome, 'failed'); assert.equal(d.finish.body.p_notes, 'sender_number_not_set'); assert.equal(d.finish.body.p_retry_in_minutes, 15); });
test('task without consent is skipped, not retried', () => { const d = tdecide(200, { allowed: false, reason: 'no_consent', live: true }); assert.equal(d.finish.rpc, 'zella_skip_followup_task'); assert.equal(d.finish.body.p_reason, 'no_consent'); });
test('task prepare failure fails the task for retry without leaking the response', () => { const d = tdecide(500, { message: 'SECRETDETAIL' }); assert.equal(d.finish.body.p_outcome, 'failed'); assert.equal(JSON.stringify(d).includes('SECRETDETAIL'), false); });

const tAfterLog = (statusCode, body, d) => runCode('sms-task-after-log.js', { json: { statusCode, body }, nodes: { Decide: { task_id: T.task_id, live: true, from: '+15550001111', to: '+14155550123', text: 'Hi', ...d } } }).json;
test('task live new message goes to Telnyx', () => { const a = tAfterLog(200, { id: 'm1', duplicate: false, status: 'queued' }); assert.equal(a.finish, null); assert.deepEqual(a.telnyx, { from: '+15550001111', to: '+14155550123', text: 'Hi', type: 'SMS' }); });
test('task dry run never builds a Telnyx payload', () => { const a = tAfterLog(200, { id: 'm1', duplicate: false, status: 'dry_run' }, { live: false }); assert.equal(a.telnyx, undefined); assert.match(a.finish.body.p_reason, /dry_run/); });
test('task already sent is not sent again and completes', () => { const a = tAfterLog(200, { id: 'm1', duplicate: true, status: 'sent' }); assert.equal(a.telnyx, undefined); assert.equal(a.finish.body.p_outcome, 'sms_sent'); });
test('task in-flight duplicate is suppressed', () => { const a = tAfterLog(200, { id: 'm1', duplicate: true, status: 'queued' }); assert.equal(a.telnyx, undefined); assert.equal(a.finish.body.p_reason, 'duplicate_suppressed'); });
test('task log failure sends nothing', () => { const a = tAfterLog(500, {}); assert.equal(a.telnyx, undefined); assert.equal(a.finish.body.p_outcome, 'failed'); });

const tAfterSend = (statusCode, body) => runCode('sms-task-after-send.js', { json: { statusCode, body }, nodes: { 'After log': { task_id: T.task_id, message_id: 'm1' } } }).json;
test('task Telnyx success records the id and completes as sms_sent', () => { const a = tAfterSend(200, { data: { id: 'tx-1' } }); assert.deepEqual(a.update, { p_id: 'm1', p_status: 'sent', p_external_id: 'tx-1', p_error: null }); assert.equal(a.finish.body.p_outcome, 'sms_sent'); });
test('task Telnyx rejection fails the message and the task retries', () => { const a = tAfterSend(422, { errors: [{ code: '40310', detail: 'PRIVATE' }] }); assert.equal(a.update.p_status, 'failed'); assert.equal(a.finish.body.p_outcome, 'failed'); assert.equal(a.finish.body.p_retry_in_minutes, 15); assert.equal(JSON.stringify(a).includes('PRIVATE'), false); });
test('task Telnyx 200 without an id is not trusted', () => assert.equal(tAfterSend(200, {}).finish.body.p_outcome, 'failed'));

// ---------------- follow-up workflow shape
const fuFile = JSON.parse(readFileSync(new URL('./workflows/zella-followup-texts.json', import.meta.url), 'utf8'));
test('follow-up workflow claims text tasks only, for the listed kinds', () => {
  const n = fuFile.nodes.find((x) => x.name === 'Claim follow-ups');
  assert.ok(n.parameters.url.endsWith('/rpc/zella_claim_followup_texts'));
  for (const k of ['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms']) assert.ok(n.parameters.jsonBody.includes(k), k);
  assert.ok(!n.parameters.jsonBody.includes('waitlist_offer'));
});
test('follow-up Telnyx box is reachable only after the live check and ships with no credential', () => {
  const into = Object.entries(fuFile.connections).filter(([, v]) => v.main.flat().some((l) => l.node === 'Send via Telnyx')).map(([k]) => k);
  assert.deepEqual(into, ['Send for real']);
  const n = fuFile.nodes.find((x) => x.name === 'Send via Telnyx'); assert.equal(n.parameters.authentication, 'none'); assert.equal(n.credentials, undefined);
});
test('follow-up workflow only reports results through task functions', () => {
  const t = JSON.stringify(fuFile);
  assert.ok(!t.includes('zella_complete_reminder') && !t.includes('zella_skip_reminder') && !t.includes('zella_claim_reminders'));
});

for (const file of ['zella-event-gateway.json', 'zella-event-router.json', 'zella-schedulers.json', 'zella-sms-sender.json', 'zella-followup-texts.json']) {
  const w = JSON.parse(readFileSync(new URL('./workflows/' + file, import.meta.url), 'utf8'));
  const names = w.nodes.map((n) => n.name);
  test(file + ': node names are unique', () => assert.equal(new Set(names).size, names.length));
  test(file + ': node ids are unique', () => assert.equal(new Set(w.nodes.map((n) => n.id)).size, w.nodes.length));
  test(file + ': every connection points at a real node', () => {
    for (const [from, c] of Object.entries(w.connections)) {
      assert.ok(names.includes(from), 'unknown source ' + from);
      for (const branch of c.main) for (const l of branch) assert.ok(names.includes(l.node), from + ' -> ' + l.node);
    }
  });
  test(file + ': every node is reachable from the trigger', () => {
    const triggers = w.nodes.filter((n) => /webhook|scheduleTrigger/.test(n.type)).map((n) => n.name);
    const seen = new Set(triggers); const queue = [...triggers];
    while (queue.length) for (const b of w.connections[queue.shift()]?.main ?? []) for (const l of b) if (!seen.has(l.node)) { seen.add(l.node); queue.push(l.node); }
    assert.deepEqual(names.filter((n) => !seen.has(n)), []);
  });
  test(file + ': expressions only reference nodes that exist', () => {
    const text = JSON.stringify(w);
    for (const m of text.matchAll(/\$\('([^']+)'\)/g)) assert.ok(names.includes(m[1]), 'expression refers to missing node ' + m[1]);
  });
  test(file + ': no secrets in the file', () => {
    const text = JSON.stringify(w);
    assert.ok(!/eyJ[A-Za-z0-9_-]{20,}/.test(text), 'looks like a JWT');
    assert.ok(!/sb_secret_|service_role_key|apikey/i.test(text.replace(/httpCustomAuth/g, '')), 'mentions a key');
  });
  test(file + ': is inactive until switched on', () => assert.equal(w.active, false));
  test(file + ': Code nodes parse', () => {
    for (const n of w.nodes.filter((x) => x.type === 'n8n-nodes-base.code')) new Function('$json', '$', n.parameters.jsCode);
  });
  test(file + ': HTTP nodes use a credential, not pasted keys', () => {
    for (const n of w.nodes.filter((x) => x.type === 'n8n-nodes-base.httpRequest' && x.name !== 'Send via Telnyx')) {
      assert.equal(n.parameters.authentication, 'genericCredentialType'); assert.ok(n.credentials?.httpCustomAuth || n.credentials?.httpHeaderAuth);
    }
  });
}

console.log(`${passed} passed, ${failures.length} failed`);
for (const f of failures) console.log('  FAIL ' + f);
process.exit(failures.length ? 1 : 0);
