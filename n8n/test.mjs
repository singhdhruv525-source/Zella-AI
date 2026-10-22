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
for (const file of ['zella-event-gateway.json', 'zella-event-router.json']) {
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
    const trigger = w.nodes.find((n) => /webhook|scheduleTrigger/.test(n.type)).name;
    const seen = new Set([trigger]); const queue = [trigger];
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
    for (const n of w.nodes.filter((x) => x.type === 'n8n-nodes-base.httpRequest')) {
      assert.equal(n.parameters.authentication, 'genericCredentialType'); assert.ok(n.credentials?.httpCustomAuth);
    }
  });
}

console.log(`${passed} passed, ${failures.length} failed`);
for (const f of failures) console.log('  FAIL ' + f);
process.exit(failures.length ? 1 : 0);
