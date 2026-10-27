// voice-rules over HTTP against the staging database (through mock-rest.mjs), every request signed like Vapi's HMAC
// credential (vapi-client.mjs) with a TEST secret.
import { P, send, sign, now, sql, control, callA, counter, URL_, SECRET } from './vapi-client.mjs';
const { ok, done } = counter();
control('');

// ---- authentication
const st = { message: { type: 'status-update', status: 'ringing', timestamp: Date.now(), call: callA('e2e-auth') } };
const stRaw = JSON.stringify(st);
ok((await send(stRaw)).status === 401, 'no signature: 401');
ok((await P(st, { secret: 'not-the-secret-0123456789' })).status === 401, 'signed with the wrong secret: 401');
ok((await send(stRaw, { 'x-zella-secret': 's3cret-test' })).status === 401, 'old static X-Zella-Secret header alone: 401');
ok((await send(stRaw, { authorization: 'Bearer ' + SECRET })).status === 401, 'bearer token while in HMAC mode: 401');
const ts = now(); const sig = sign(stRaw, ts);
ok((await send(stRaw.replace('ringing', 'ended'), { 'x-timestamp': ts, 'x-signature': sig })).status === 401, 'signed body changed in transit: 401');
ok((await P(st, { ts: String(Number(now()) - 600) })).status === 401, 'correctly signed 10 minutes ago: 401 (expired)');
ok(sql("select count(*) from calls where external_call_id = 'e2e-auth'") === '0', 'nothing recorded for any refused request');
ok((await send(stRaw, { 'x-timestamp': ts, 'x-signature': sig })).status === 200, 'valid signed request: 200');
const replay = await send(stRaw, { 'x-timestamp': ts, 'x-signature': sig });
ok(replay.status === 401, 'exact same signed request again (replay): 401');
// a replayed tool call is refused before anything runs, so it can't fetch a caller's data again
const tcBody = { message: { type: 'tool-calls', call: callA('e2e-auth'), toolCallList: [{ id: 'r1', function: { name: 'call_rules', arguments: '{"action":"rules"}' } }] } };
const tRaw = JSON.stringify(tcBody), tts = now(), tsig = sign(tRaw, tts);
const first = await send(tRaw, { 'x-timestamp': tts, 'x-signature': tsig });
const again = await send(tRaw, { 'x-timestamp': tts, 'x-signature': tsig });
ok(first.status === 200 && again.status === 401 && !(await again.text()).includes('results'), 'replayed tool call: refused, no answer data returned');
ok((await P('{not json')).status === 400 && (await P({})).status === 400 && (await P({ message: { type: 7 } })).status === 400, 'signed but malformed (bad JSON, no message, bad type): 400');
ok((await fetch(URL_, { method: 'GET' })).status === 405, 'GET: 405');
ok((await P({ message: { type: 'tool-calls', pad: 'x'.repeat(300 * 1024) } })).status === 413, 'over 256 KB: 413');
ok((await P({ message: { type: 'speech-update' } })).status === 200, 'signed message type Zella does not use: acknowledged, ignored');

// ---- call status: in order, once
for (const s of ['ringing', 'in-progress', 'in-progress']) ok((await P({ message: { type: 'status-update', status: s, timestamp: Date.now(), call: callA('e2e-1') } })).status === 200, 'status-update ' + s + ' accepted (200)');

// ---- tool calls: several in one request, each answered under its own id, with its tool name
const r = await (await P({ message: { type: 'tool-calls', call: callA('e2e-1'), toolCallList: [
  { id: 'a', type: 'function', function: { name: 'call_rules', arguments: '{"action":"rules"}' } },
  { id: 'b', name: 'call_rules', arguments: { action: 'transfer', reason: 'wants a person' } },
  { id: 'c', name: 'call_rules', arguments: { action: 'drop_tables' } },
  { id: 'd', name: 'book_everything', arguments: {} }] } })).json();
const by = Object.fromEntries(r.results.map((x) => [x.toolCallId, x]));
ok(r.results.length === 4 && ['a', 'b', 'c', 'd'].every((k) => by[k]), 'four tool calls -> four answers, matched by toolCallId');
ok(by.a.name === 'call_rules' && by.d.name === 'book_everything', 'each answer names its tool (Vapi ToolCallResult.name)');
ok(JSON.parse(by.a.result).status === 'open', 'a: rules answered from the database (Vapi function-style arguments string)');
const b = JSON.parse(by.b.result);
ok(b.status === 'transfer' && b.use_transfer_tool === true && !by.b.result.includes('5550101111'), 'b: transfer allowed, model told to use the transfer tool, number NOT exposed');
ok(by.c.error && by.d.error, 'c/d: unknown action and unknown tool each get an error answer');
ok(sql("select count(*) from calls where external_call_id = 'e2e-1'") === '1', 'one call row for the call');

// ---- transfers: only this business's own authorised number
const td = await (await P({ message: { type: 'transfer-destination-request', call: callA('e2e-1') } })).json();
ok(td.destination && td.destination.type === 'number' && td.destination.number === '+15550101111', 'transfer-destination-request: destination = business A\'s own number');
const tb = await (await P({ message: { type: 'transfer-destination-request', call: callA('e2e-2', { phoneNumber: { number: '+15550002000' }, phoneNumberId: 'pn-B' }) } })).json();
ok(tb.error && !tb.destination && !JSON.stringify(tb).includes('5550101111'), 'business B (transfers off): refused, never given A\'s number');
const tu = await (await P({ message: { type: 'transfer-destination-request', call: callA('e2e-3', { phoneNumber: { number: '+15559990000' }, phoneNumberId: 'pn-x', metadata: { business_id: 'aaaaaaaa-0000-4000-8000-000000000001' } }) } })).json();
ok(tu.error && !tu.destination, 'unregistered line claiming business A in call settings: refused');
const tn = await (await P({ message: { type: 'transfer-destination-request' } })).json();
ok(tn.error && !tn.destination, 'transfer request with no call at all: refused');
// B's line asking call_rules gets B's own answer (no business falls back to A)
const rb = await (await P({ message: { type: 'tool-calls', call: callA('e2e-2', { phoneNumber: { number: '+15550002000' }, phoneNumberId: 'pn-B', metadata: { business_id: 'aaaaaaaa-0000-4000-8000-000000000001' } }), toolCallList: [{ id: 'x', name: 'call_rules', arguments: { action: 'transfer' } }] } })).json();
ok(JSON.parse(rb.results[0].result).status !== 'transfer' && sql("select business_id from calls where external_call_id = 'e2e-2'") === 'bbbbbbbb-0000-4000-8000-000000000002', 'B\'s line claiming A in call settings: handled as B (transfers off), call row belongs to B');

// ---- end of call, then late and repeated events
const report = { message: { type: 'end-of-call-report', endedReason: 'customer-ended-call', startedAt: '2026-10-27T15:00:00.000Z', endedAt: '2026-10-27T15:02:05.000Z',
  artifact: { transcript: 'AI: Hello. User: Hi.', recordingUrl: 'https://storage.example/rec.wav' }, analysis: { summary: 'Asked about opening hours.' }, call: callA('e2e-1') } };
ok((await P(report)).status === 200, 'end-of-call-report accepted');
ok(sql("select duration_seconds || '|' || (transcript is not null) || '|' || coalesce(recording_url, '') from calls where external_call_id = 'e2e-1'") === '125|true|https://storage.example/rec.wav',
  'report recorded: duration from Vapi\'s own start/end times (125 s), transcript and recording kept');
await P({ message: { type: 'status-update', status: 'in-progress', timestamp: Date.now(), call: callA('e2e-1') } });
await P(report);
ok(sql("select count(*) || '|' || duration_seconds from calls where external_call_id = 'e2e-1' group by duration_seconds") === '1|125', 'late in-progress and a repeated report: still one row, nothing changed');

// ---- time limits and failures: the caller is never left hanging and nothing is claimed
control('slow:zella_ai_voice');
let t0 = Date.now();
const slow = await (await P({ message: { type: 'tool-calls', call: callA('e2e-4'), toolCallList: [{ id: 's1', name: 'call_rules', arguments: { action: 'message', message: 'call me' } }, { id: 's2', name: 'call_rules', arguments: {} }] } })).json();
const took = Date.now() - t0;
ok(slow.results.length === 2 && slow.results.every((x) => x.error && !x.result) && took < 9000, `database too slow: both tool calls answered with a safe error within the budget (${took} ms)`);
control('slow:zella_transfer_destination');
t0 = Date.now();
const tslow = await (await P({ message: { type: 'transfer-destination-request', call: callA('e2e-1') } })).json();
ok(tslow.error && !tslow.destination && Date.now() - t0 < 9000, 'transfer lookup too slow: refused, no guessed number');
control('down:zella_vapi_authenticate');
ok((await P({ message: { type: 'status-update', status: 'ended', call: callA('e2e-5') } })).status === 503, 'signature check unreachable: 503, nothing done');
control('slow:zella_vapi_authenticate');
t0 = Date.now();
ok((await P({ message: { type: 'status-update', status: 'ended', call: callA('e2e-5') } })).status === 503 && Date.now() - t0 < 9000, 'signature check too slow: 503 within the time limit');
control('');
ok(sql("select count(*) from calls where external_call_id = 'e2e-5'") === '0', 'no call row from requests that could not be checked');
done();
