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
const code = (name, position, file, vars = {}) =>
  node(name, 'n8n-nodes-base.code', 2, position, { mode: 'runOnceForEachItem', jsCode: loadCode(file, vars) });
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


// ------------------------------------------------------------------ Schedulers
// Each job is one database call on a timer. A failed call raises a grouped platform alert.
// Not here on purpose: zella_calls_to_callbacks and zella_queue_no_show_followup are database
// triggers (they fire on their own); zella_check_invitations needs the email sender;
// zella_retention_due only lists businesses and nothing deletes yet.
export const SCHEDULE = {
  every5: ['zella_flag_overdue_leads', 'zella_expire_holds', 'zella_expire_waitlist_offers', 'zella_detect_transfer_failures'],
  every15: ['zella_queue_quote_followups'],
  daily: ['zella_queue_lead_reactivation', 'zella_check_setup_incomplete', 'zella_check_trials', 'zella_apply_payment_policy'],
  weekly: ['zella_post_weekly_reviews'],
};
const triggers = {
  every5: ['Every 5 minutes', { rule: { interval: [{ field: 'minutes', minutesInterval: 5 }] } }],
  every15: ['Every 15 minutes', { rule: { interval: [{ field: 'minutes', minutesInterval: 15 }] } }],
  daily: ['Every day', { rule: { interval: [{ field: 'days', daysInterval: 1, triggerAtHour: 4 }] } }],
  weekly: ['Every Monday', { rule: { interval: [{ field: 'weeks', weeksInterval: 1, triggerAtDay: [1], triggerAtHour: 8 }] } }],
};
const schedNodes = [];
const schedConns = {};
let row = 0;
for (const [key, fns] of Object.entries(SCHEDULE)) {
  const [tname, tparams] = triggers[key];
  schedNodes.push(node(tname, 'n8n-nodes-base.scheduleTrigger', 1.2, [0, row * 220 + 100], tparams));
  schedConns[tname] = { main: [fns.map((f) => link('Run ' + f))] };
  for (const f of fns) {
    const y = row * 220;
    const body = f === 'zella_queue_lead_reactivation' ? '={{ JSON.stringify({ p_limit: 200 }) }}' : '{}';
    schedNodes.push(rpcNode('Run ' + f, [260, y], f, body, { full: true }));
    schedNodes.push(code('Check ' + f, [520, y], 'scheduler-check.js', { JOB: f }));
    schedNodes.push(ifBool('Failed ' + f, [780, y], '={{ !$json.ok }}'));
    schedNodes.push(rpcNode('Alert ' + f, [1040, y - 60], 'zella_platform_alert', '={{ JSON.stringify($json.alert) }}'));
    schedConns['Run ' + f] = { main: [[link('Check ' + f)]] };
    schedConns['Check ' + f] = { main: [[link('Failed ' + f)]] };
    schedConns['Failed ' + f] = { main: [[link('Alert ' + f)], []] };
    row++;
  }
}
const schedulers = wf('Zella - Schedulers', schedNodes, schedConns);

// ------------------------------------------------------------------ SMS Sender (reminders)
// Claim reminders -> prepare (consent + template) -> log -> send (only when live) -> report back.
// Dry-run is the default: until the database setting sms_live is true, nothing is sent.
// The Telnyx box ships with NO credential on purpose: n8n would otherwise attach any Header Auth
// credential it finds (including the gateway secret). Add the Telnyx key by hand when going live.
const finishNode = (pos) => rpcNode('Finish reminder', pos, '', "={{ JSON.stringify($json.finish.body) }}",
  { full: true, urlExpr: `={{ '${SUPABASE}/rest/v1/rpc/' + $json.finish.rpc }}` });
const smsSender = wf('Zella - SMS Sender', [
  node('Every minute', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 200], { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } }),
  rpcNode('Claim reminders', [240, 200], 'zella_claim_reminders', '={{ JSON.stringify({ p_limit: 20 }) }}'),
  code('Plan', [480, 200], 'sms-plan.js'),
  ifBool('Is a text', [720, 200], '={{ !$json.finish }}'),
  rpcNode('Prepare text', [960, 100], 'zella_prepare_sms', '={{ JSON.stringify($json.prepare) }}', { full: true }),
  code('Decide', [1200, 100], 'sms-decide.js'),
  ifBool('Needs sending', [1440, 100], '={{ !$json.finish }}'),
  rpcNode('Log message', [1680, 0], 'zella_log_outbound_sms', '={{ JSON.stringify($json.log) }}', { full: true }),
  code('After log', [1920, 0], 'sms-after-log.js'),
  ifBool('Send for real', [2160, 0], '={{ !$json.finish }}'),
  node('Send via Telnyx', 'n8n-nodes-base.httpRequest', 4.2, [2400, -100], {
    method: 'POST', url: 'https://api.telnyx.com/v2/messages', authentication: 'none',
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.telnyx) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('After send', [2640, -100], 'sms-after-send.js'),
  rpcNode('Update message', [2880, -100], 'zella_update_outbound_sms', '={{ JSON.stringify($json.update) }}', { full: true }),
  code('Restore result', [3120, -100], 'sms-restore.js'),
  finishNode([3360, 200]),
], {
  'Every minute': { main: [[link('Claim reminders')]] },
  'Claim reminders': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a text')]] },
  'Is a text': { main: [[link('Prepare text')], [link('Finish reminder')]] },
  'Prepare text': { main: [[link('Decide')]] },
  'Decide': { main: [[link('Needs sending')]] },
  'Needs sending': { main: [[link('Log message')], [link('Finish reminder')]] },
  'Log message': { main: [[link('After log')]] },
  'After log': { main: [[link('Send for real')]] },
  'Send for real': { main: [[link('Send via Telnyx')], [link('Finish reminder')]] },
  'Send via Telnyx': { main: [[link('After send')]] },
  'After send': { main: [[link('Update message')]] },
  'Update message': { main: [[link('Restore result')]] },
  'Restore result': { main: [[link('Finish reminder')]] },
});

writeFileSync(join(out, 'zella-event-gateway.json'), JSON.stringify(gateway, null, 2) + '\n');
writeFileSync(join(out, 'zella-event-router.json'), JSON.stringify(router, null, 2) + '\n');
writeFileSync(join(out, 'zella-schedulers.json'), JSON.stringify(schedulers, null, 2) + '\n');
writeFileSync(join(out, 'zella-sms-sender.json'), JSON.stringify(smsSender, null, 2) + '\n');
console.log('Built', gateway.nodes.length, 'gateway nodes,', router.nodes.length, 'router nodes,', schedulers.nodes.length, 'scheduler nodes and', smsSender.nodes.length, 'sms sender nodes.');
