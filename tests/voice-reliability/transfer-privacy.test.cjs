const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const vm = require('node:vm');
const logic = require('../../web/supabase/functions/voice-rules/logic.ts');

// Run the shipped edge handler and reply helpers; only the backend is replaced.
test('edge transfer tool reply excludes the backend destination from the model payload', async () => {
  let handler;
  const calls = [];
  const destination = '+15550103333';
  const backendResult = { status: 'transfer', say: 'Please hold while I connect you.', transfer_number: destination, can_transfer: true };
  const businessId = 'aaaaaaaa-0000-4000-8000-000000000001';
  const replies = {
    zella_vapi_authenticate: 'ok',
    zella_business_for_number: businessId,
    zella_rate_limit: true,
    zella_ai_voice: backendResult,
  };
  const source = readFileSync(path.join(__dirname, '../../web/supabase/functions/voice-rules/index.ts'), 'utf8');
  vm.runInNewContext(stripTypeScriptTypes(source).replace(/^import .*;\n/gm, ''), {
    ...logic, Response, TextEncoder, AbortSignal,
    console: { log() {}, error() {} },
    Deno: {
      env: { get: (key) => ({ SUPABASE_URL: 'http://backend.test', ZELLA_SERVER_SECRET_KEY: 'local-test-only' })[key] },
      serve: (fn) => { handler = fn; },
    },
    createClient: () => ({ rpc: (fn, args) => {
      assert.ok(Object.hasOwn(replies, fn), `unexpected RPC: ${fn}`);
      calls.push({ fn, args });
      return { abortSignal: async () => ({ data: replies[fn], error: null }) };
    } }),
  });
  const response = await handler(new Request('http://edge.test', {
    method: 'POST',
    body: JSON.stringify({ message: {
      type: 'tool-calls', call: { id: 'privacy-transfer', phoneNumber: { number: '+15550001000' } },
      toolCallList: [{ id: 'transfer-1', function: { name: 'call_rules', arguments: '{"action":"transfer"}' } }],
    } }),
  }));
  assert.equal(response.status, 200);
  const payload = await response.json();
  const voiceCall = calls.find(({ fn }) => fn === 'zella_ai_voice');
  assert.ok(voiceCall, 'the edge handler must reach the transfer backend');
  assert.equal(voiceCall.args.p_action, 'transfer');
  assert.equal(voiceCall.args.p_business_id, businessId);
  assert.equal(payload.results.length, 1);
  const reply = payload.results[0];
  assert.equal(reply.toolCallId, 'transfer-1');
  assert.equal(reply.name, 'call_rules');
  assert.equal(reply.error, undefined);
  const modelResult = JSON.parse(reply.result);
  assert.equal(modelResult.status, 'transfer');
  assert.equal(modelResult.use_transfer_tool, true);
  assert.equal(Object.hasOwn(modelResult, 'transfer_number'), false);
  assert.equal(Object.hasOwn(modelResult, 'number'), false);
  assert.ok(!JSON.stringify(payload).replace(/\D/g, '').includes(destination.replace(/\D/g, '')));
  assert.equal(backendResult.transfer_number, destination, 'the backend fixture retains the destination');
});
