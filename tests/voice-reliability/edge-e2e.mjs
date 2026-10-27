const P = (body, secret = 's3cret-test') => fetch('http://127.0.0.1:8000', { method: 'POST', headers: { 'content-type': 'application/json', 'x-zella-secret': secret }, body: JSON.stringify(body) });
const callA = (id, extra = {}) => ({ id, type: 'inboundPhoneCall', customer: { number: '+15551230001' }, phoneNumber: { number: '+15550001000' }, phoneNumberId: 'pn-A', ...extra });
let pass = 0, fail = 0; const ok = (c, m) => { c ? pass++ : fail++; console.log((c ? 'PASS ' : 'FAIL ') + m); };
// status updates first: the call exists from the moment it starts
for (const st of ['ringing', 'in-progress', 'in-progress']) ok((await P({ message: { type: 'status-update', status: st, timestamp: Date.now(), call: callA('e2e-1') } })).status === 200, 'status-update ' + st + ' accepted (200)');
// one request, four tool calls: rules, transfer, an unknown action, an unknown tool
const r = await (await P({ message: { type: 'tool-calls', call: callA('e2e-1'), toolCallList: [
  { id: 'a', name: 'call_rules', arguments: { action: 'rules' } },
  { id: 'b', name: 'call_rules', arguments: { action: 'transfer', reason: 'wants a person' } },
  { id: 'c', name: 'call_rules', arguments: { action: 'drop_tables' } },
  { id: 'd', name: 'book_everything', arguments: {} }] } })).json();
const by = Object.fromEntries(r.results.map((x) => [x.toolCallId, x]));
ok(r.results.length === 4 && ['a', 'b', 'c', 'd'].every((k) => by[k]), 'four tool calls -> four answers, matched by toolCallId');
ok(JSON.parse(by.a.result).status === 'open', 'a: rules answered from the database');
const b = JSON.parse(by.b.result);
ok(b.status === 'transfer' && b.use_transfer_tool === true && !by.b.result.includes('5550101111'), 'b: transfer allowed, model told to use the transfer tool, number NOT exposed');
ok(by.c.error && by.d.error, 'c/d: unknown action and unknown tool each get an error answer');
// Vapi asks where to transfer: the server answers with this business's authorised number
const td = await (await P({ message: { type: 'transfer-destination-request', call: callA('e2e-1') } })).json();
ok(td.destination && td.destination.type === 'number' && td.destination.number === '+15550101111', 'transfer-destination-request: destination = business A\'s own number (' + (td.destination && td.destination.number) + ')');
// a call on business B's line (transfers switched off) is refused, never given A's number
const tb = await (await P({ message: { type: 'transfer-destination-request', call: callA('e2e-2', { phoneNumber: { number: '+15550002000' }, phoneNumberId: 'pn-B' }) } })).json();
ok(tb.error && !tb.destination && !JSON.stringify(tb).includes('5550101111'), 'business B (transfers off): refused, no number');
// an unregistered line can't get a destination either, even if it claims business A in its settings
const tu = await (await P({ message: { type: 'transfer-destination-request', call: callA('e2e-3', { phoneNumber: { number: '+15559990000' }, phoneNumberId: 'pn-x', metadata: { business_id: 'aaaaaaaa-0000-4000-8000-000000000001' } }) } })).json();
ok(tu.error && !tu.destination, 'unregistered line claiming business A in call settings: refused');
// security basics
ok((await P({ message: { type: 'tool-calls' } }, 'wrong')).status === 401, 'wrong secret: 401');
ok((await fetch('http://127.0.0.1:8000', { method: 'POST', headers: { 'x-zella-secret': 's3cret-test' }, body: '{not json' })).status === 400, 'malformed JSON: 400');
ok((await fetch('http://127.0.0.1:8000', { method: 'GET' })).status === 405, 'GET: 405');
console.log(`${pass} passed, ${fail} failed`);
