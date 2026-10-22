// Builds the importable n8n workflow files from the Code-node sources.
// Run: node n8n/src/build.mjs
import { writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadCode } from './load.mjs';

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'workflows');
mkdirSync(out, { recursive: true });

const SUPABASE = 'https://pffqxlumqhjdbzvvoszm.supabase.co';
const SUPABASE_CRED = { httpCustomAuth: { id: '', name: 'Zella Supabase service role' } };
const GATEWAY_CRED = { httpHeaderAuth: { id: '', name: 'Zella gateway secret' } };

const id = (name) => {
  const h = createHash('sha1').update(name).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const node = (name, type, typeVersion, position, parameters, extra = {}) => ({
  parameters, id: id(name), name, type, typeVersion, position, ...extra,
});
const rpcNode = (name, position, fn, bodyExpr, opts = {}) =>
  node(name, 'n8n-nodes-base.httpRequest', 4.2, position, {
    method: 'POST',
    url: opts.urlExpr ?? `${SUPABASE}/rest/v1/rpc/${fn}`,
    authentication: 'genericCredentialType',
    genericAuthType: 'httpCustomAuth',
    sendBody: true,
    specifyBody: 'json',
    jsonBody: bodyExpr,
    options: opts.full ? { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } } : {},
  }, { credentials: SUPABASE_CRED, ...(opts.timeout ? {} : {}) });
const code = (name, position, file) =>
  node(name, 'n8n-nodes-base.code', 2, position, { mode: 'runOnceForEachItem', jsCode: loadCode(file) });
const ifBool = (name, position, expr) =>
  node(name, 'n8n-nodes-base.if', 2, position, {
    conditions: {
      options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
      conditions: [{ id: id(name + ':c'), leftValue: expr, rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
      combinator: 'and',
    },
    options: {},
  });
const link = (to, index = 0) => ({ node: to, type: 'main', index });
const wf = (name, nodes, connections) => ({
  name, nodes, connections, active: false, settings: { executionOrder: 'v1' }, pinData: {},
  meta: { templateCredsSetupCompleted: false },
});

// ------------------------------------------------------------------ Event Gateway
const gateway = wf('Zella - Event Gateway', [
  node('Receive event', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/events', authentication: 'headerAuth', responseMode: 'responseNode', options: {},
  }, { webhookId: id('webhook:zella-events'), credentials: GATEWAY_CRED }),
  code('Check event', [240, 200], 'gateway-validate.js'),
  ifBool('Is valid', [480, 200], '={{ $json.valid }}'),
  rpcNode('Store event', [720, 100], 'zella_ingest_event', '={{ JSON.stringify($json.rpc) }}', { full: true }),
  code('Build reply', [960, 100], 'gateway-map.js'),
  code('Build bad request reply', [720, 320], 'gateway-bad-request.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1200, 200], {
    respondWith: 'json', responseBody: '={{ $json.body }}', options: { responseCode: '={{ $json.status }}' },
  }),
], {
  'Receive event': { main: [[link('Check event')]] },
  'Check event': { main: [[link('Is valid')]] },
  'Is valid': { main: [[link('Store event')], [link('Build bad request reply')]] },
  'Store event': { main: [[link('Build reply')]] },
  'Build reply': { main: [[link('Reply')]] },
  'Build bad request reply': { main: [[link('Reply')]] },
});

// ------------------------------------------------------------------ Event Router
const router = wf('Zella - Event Router', [
  node('Every minute', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 200], { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } }),
  rpcNode('Claim events', [240, 200], 'zella_claim_events', '={{ JSON.stringify({ p_limit: 20 }) }}'),
  code('Route', [480, 200], 'router-route.js'),
  rpcNode('Start execution', [720, 200], 'zella_start_execution',
    "={{ JSON.stringify({ p_workflow_key: 'event_router', p_business_id: $json.event.business_id, p_event_id: $json.event.id, p_workflow_version: '1', p_correlation_id: $json.event.correlation_id }) }}",
    { full: true }),
  ifBool('Has handler', [960, 200], "={{ $('Route').item.json.plan !== null }}"),
  rpcNode('Run handler', [1200, 100], '',
    "={{ JSON.stringify($('Route').item.json.plan.body) }}",
    { full: true, urlExpr: `={{ '${SUPABASE}/rest/v1/rpc/' + $('Route').item.json.plan.rpc }}` }),
  code('Result', [1440, 200], 'router-result.js'),
  rpcNode('Finish execution', [1680, 200], 'zella_finish_execution',
    "={{ JSON.stringify({ p_execution_id: $json.execution_id, p_ok: $json.ok, p_step: $json.steps[$json.steps.length - 1].step, p_steps: $json.steps, p_error_category: $json.category, p_error: $json.error, p_needs_manual: $json.needs_manual }) }}",
    { full: true }),
  rpcNode('Complete event', [1920, 200], 'zella_complete_event',
    "={{ JSON.stringify({ p_event_id: $('Result').item.json.event_id, p_ok: $('Result').item.json.ok, p_error_category: $('Result').item.json.category, p_error: $('Result').item.json.error }) }}"),
], {
  'Every minute': { main: [[link('Claim events')]] },
  'Claim events': { main: [[link('Route')]] },
  'Route': { main: [[link('Start execution')]] },
  'Start execution': { main: [[link('Has handler')]] },
  'Has handler': { main: [[link('Run handler')], [link('Result')]] },
  'Run handler': { main: [[link('Result')]] },
  'Result': { main: [[link('Finish execution')]] },
  'Finish execution': { main: [[link('Complete event')]] },
});

writeFileSync(join(out, 'zella-event-gateway.json'), JSON.stringify(gateway, null, 2) + '\n');
writeFileSync(join(out, 'zella-event-router.json'), JSON.stringify(router, null, 2) + '\n');
console.log('Built', gateway.nodes.length, 'gateway nodes and', router.nodes.length, 'router nodes.');
