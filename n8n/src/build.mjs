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
// Every outside call gets a time limit, so a slow provider cannot hold a run open (60 s for the AI, 30 s for the rest).
const withTimeout = (type, parameters) => {
  if (type !== 'n8n-nodes-base.httpRequest' || !parameters || typeof parameters !== 'object') return parameters;
  const options = parameters.options && typeof parameters.options === 'object' ? parameters.options : {};
  if (options.timeout) return parameters;
  return { ...parameters, options: { ...options, timeout: String(parameters.url || '').includes('api.anthropic.com') ? 60000 : 30000 } };
};
const node = (name, type, typeVersion, position, parameters, extra = {}) => ({
  parameters: withTimeout(type, parameters), id: id(name), name, type, typeVersion, position, ...extra,
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
const codeAll = (name, position, file, vars = {}) =>
  node(name, 'n8n-nodes-base.code', 2, position, { mode: 'runOnceForAllItems', jsCode: loadCode(file, vars) });
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
  name, nodes, connections, active: false, settings: { executionOrder: 'v1', executionTimeout: 300 }, pinData: {},
  meta: { templateCredsSetupCompleted: false },
});

// Every webhook Vapi calls is checked by the database before anything else runs (sql/zella_vapi_auth.sql): the exact
// bytes, Vapi's HMAC signature and timestamp (or its Bearer token), and that the request was not seen before. The
// gateway header (X-Zella-Secret) stays as an outer check. A refused request gets 401 where Vapi waits for an answer.
const secureVapi = (w, webhookName, respond) => {
  const hook = w.nodes.find((n) => n.name === webhookName);
  hook.parameters.options = { ...hook.parameters.options, rawBody: true };
  const next = w.connections[webhookName].main[0];
  const [x, y] = hook.position;
  w.nodes.push(
    codeAll('Read request', [x + 120, y - 240], 'vapi-auth-read.js'),
    rpcNode('Check signature', [x + 360, y - 240], 'zella_vapi_authenticate', '={{ JSON.stringify($json.record) }}', { full: true }),
    ifBool('Signed', [x + 600, y - 240], "={{ $json.statusCode === 200 && $json.body === 'ok' }}"),
    codeAll('Request', [x + 840, y - 320], 'vapi-auth-pass.js', { WEBHOOK: webhookName }),
  );
  if (respond) w.nodes.push(node('Refuse', 'n8n-nodes-base.respondToWebhook', 1.1, [x + 840, y - 120], {
    respondWith: 'json', responseBody: '={{ JSON.stringify({ error: "Unauthorized" }) }}', options: { responseCode: 401 },
  }));
  w.connections[webhookName] = { main: [[link('Read request')]] };
  w.connections['Read request'] = { main: [[link('Check signature')]] };
  w.connections['Check signature'] = { main: [[link('Signed')]] };
  w.connections['Signed'] = { main: [[link('Request')], respond ? [link('Refuse')] : []] };
  w.connections['Request'] = { main: [next] };
  return w;
};

// Every workflow except the gateway is started by the database dispatcher (sql/zella_dispatcher.sql), which
// calls it only when something is waiting. This keeps n8n Cloud's monthly run allowance for real work.
const runTrigger = (workflowName) => node('Run now', 'n8n-nodes-base.webhook', 2, [0, 200], {
  httpMethod: 'POST', path: 'zella/run/' + workflowName, authentication: 'headerAuth', responseMode: 'onReceived', options: {},
}, { webhookId: id('webhook:zella-run-' + workflowName), credentials: GATEWAY_CRED });

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
  runTrigger('event-router'),
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
  'Run now': { main: [[link('Claim events')]] },
  'Claim events': { main: [[link('Route')]] },
  'Route': { main: [[link('Start execution')]] },
  'Start execution': { main: [[link('Has handler')]] },
  'Has handler': { main: [[link('Run handler')], [link('Result')]] },
  'Run handler': { main: [[link('Result')]] },
  'Result': { main: [[link('Finish execution')]] },
  'Finish execution': { main: [[link('Complete event')]] },
});


// ------------------------------------------------------------------ Timed jobs
// The 11 timed database jobs (overdue leads, daily summary, weekly review ...) no longer run in n8n. They run
// inside Supabase with pg_cron (sql/zella_dispatcher.sql), which costs no n8n runs. See n8n/README.md.

// ------------------------------------------------------------------ SMS Sender (reminders)
// Claim reminders -> prepare (consent + template) -> log -> send (only when live) -> report back.
// Dry-run is the default: until the database setting sms_live is true, nothing is sent.
// The Telnyx box ships with NO credential on purpose: n8n would otherwise attach any Header Auth
// credential it finds (including the gateway secret). Add the Telnyx key by hand when going live.
const finishNode = (name, pos) => rpcNode(name, pos, '', "={{ JSON.stringify($json.finish.body) }}",
  { full: true, urlExpr: `={{ '${SUPABASE}/rest/v1/rpc/' + $json.finish.rpc }}` });

// The same safe pipeline serves reminders and follow-up texts. Only the claim step and the small
// Code files differ (which id, which template, how the result is reported back).
function smsFlow(name, { claim, claimName, finishName, files, runName, email = false }) {
  const C = claimName;
  // Text and email use the same pipeline; only the database functions and the final send box differ.
  const k = email
    ? { is: 'Is an email', prep: 'Prepare email', send: 'Send via Resend', prepFn: 'zella_prepare_email', logFn: 'zella_log_outbound_email', updFn: 'zella_update_outbound_email', field: 'resend' }
    : { is: 'Is a text', prep: 'Prepare text', send: 'Send via Telnyx', prepFn: 'zella_prepare_sms', logFn: 'zella_log_outbound_sms', updFn: 'zella_update_outbound_sms', field: 'telnyx' };
  const sendNode = email
    ? node(k.send, 'n8n-nodes-base.httpRequest', 4.2, [2400, -100], {
        method: 'POST', url: 'https://api.resend.com/emails', authentication: 'none',
        sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.resend) }}',
        options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
      })
    : node(k.send, 'n8n-nodes-base.httpRequest', 4.2, [2400, -100], {
        method: 'POST', url: 'https://api.telnyx.com/v2/messages', authentication: 'none',
        sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.telnyx) }}',
        options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
      });
  return wf(name, [
    runTrigger(runName),
    claim(C, [240, 200]),
    code('Plan', [480, 200], files.plan),
    ifBool(k.is, [720, 200], '={{ !$json.finish }}'),
    rpcNode(k.prep, [960, 100], k.prepFn, '={{ JSON.stringify($json.prepare) }}', { full: true }),
    code('Decide', [1200, 100], files.decide),
    ifBool('Needs sending', [1440, 100], '={{ !$json.finish }}'),
    rpcNode('Log message', [1680, 0], k.logFn, '={{ JSON.stringify($json.log) }}', { full: true }),
    code('After log', [1920, 0], files.afterLog),
    ifBool('Send for real', [2160, 0], '={{ !$json.finish }}'),
    sendNode,
    code('After send', [2640, -100], files.afterSend),
    rpcNode('Update message', [2880, -100], k.updFn, '={{ JSON.stringify($json.update) }}', { full: true }),
    code('Restore result', [3120, -100], 'sms-restore.js'),
    finishNode(finishName, [3360, 200]),
  ], {
    'Run now': { main: [[link(C)]] },
    [C]: { main: [[link('Plan')]] },
    'Plan': { main: [[link(k.is)]] },
    [k.is]: { main: [[link(k.prep)], [link(finishName)]] },
    [k.prep]: { main: [[link('Decide')]] },
    'Decide': { main: [[link('Needs sending')]] },
    'Needs sending': { main: [[link('Log message')], [link(finishName)]] },
    'Log message': { main: [[link('After log')]] },
    'After log': { main: [[link('Send for real')]] },
    'Send for real': { main: [[link(k.send)], [link(finishName)]] },
    [k.send]: { main: [[link('After send')]] },
    'After send': { main: [[link('Update message')]] },
    'Update message': { main: [[link('Restore result')]] },
    'Restore result': { main: [[link(finishName)]] },
  });
}

const smsSender = smsFlow('Zella - SMS Sender', {
  runName: 'sms-sender', claimName: 'Claim reminders', finishName: 'Finish reminder',
  claim: (n, pos) => rpcNode(n, pos, 'zella_claim_reminders', '={{ JSON.stringify({ p_limit: 20 }) }}'),
  files: { plan: 'sms-plan.js', decide: 'sms-decide.js', afterLog: 'sms-after-log.js', afterSend: 'sms-after-send.js' },
});

// Email sender: appointment confirmations and reminders whose channel is email. Same pipeline and the
// same dry-run default (platform setting email_live). The Resend box ships with NO credential, for the
// same reason as the Telnyx box. It claims only email reminders, so it never touches text reminders.
const emailSender = smsFlow('Zella - Email Sender', {
  runName: 'email-sender', email: true, claimName: 'Claim email reminders', finishName: 'Finish reminder',
  claim: (n, pos) => rpcNode(n, pos, 'zella_claim_reminders', "={{ JSON.stringify({ p_limit: 20, p_channel: 'email' }) }}"),
  files: { plan: 'email-plan.js', decide: 'email-decide.js', afterLog: 'email-after-log.js', afterSend: 'email-after-send.js' },
});

// Owner emails: daily summaries, weekly reviews and warning or urgent alerts, emailed to the people who
// should get them (the database decides who, honouring each person's email preferences). Same dry-run
// switch and Resend box as the email sender, same rule that the Resend box ships with no credential.
const ownerEmails = wf('Zella - Owner Emails', [
  runTrigger('owner-emails'),
  rpcNode('Claim owner emails', [240, 200], 'zella_claim_owner_emails', '={{ JSON.stringify({ p_limit: 20 }) }}'),
  code('Plan', [480, 200], 'owner-plan.js'),
  ifBool('Needs sending', [720, 200], '={{ !$json.finish }}'),
  rpcNode('Log message', [960, 100], 'zella_log_outbound_email', '={{ JSON.stringify($json.log) }}', { full: true }),
  code('After log', [1200, 100], 'owner-after-log.js'),
  ifBool('Send for real', [1440, 100], '={{ !$json.finish }}'),
  node('Send via Resend', 'n8n-nodes-base.httpRequest', 4.2, [1680, 0], {
    method: 'POST', url: 'https://api.resend.com/emails', authentication: 'none',
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.resend) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('After send', [1920, 0], 'owner-after-send.js'),
  rpcNode('Update message', [2160, 0], 'zella_update_outbound_email', '={{ JSON.stringify($json.update) }}', { full: true }),
  code('Restore result', [2400, 0], 'sms-restore.js'),
  finishNode('Finish notification', [2640, 200]),
], {
  'Run now': { main: [[link('Claim owner emails')]] },
  'Claim owner emails': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Needs sending')]] },
  'Needs sending': { main: [[link('Log message')], [link('Finish notification')]] },
  'Log message': { main: [[link('After log')]] },
  'After log': { main: [[link('Send for real')]] },
  'Send for real': { main: [[link('Send via Resend')], [link('Finish notification')]] },
  'Send via Resend': { main: [[link('After send')]] },
  'After send': { main: [[link('Update message')]] },
  'Update message': { main: [[link('Restore result')]] },
  'Restore result': { main: [[link('Finish notification')]] },
});

export const FOLLOWUP_EMAIL_KINDS = ['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up', 'cross_sell'];
// Texts also send the quick replies to HELP and waitlist offers (the database queues them).
export const FOLLOWUP_KINDS = [...FOLLOWUP_EMAIL_KINDS, 'reply_confirmed', 'reply_reschedule', 'reply_help', 'reply_after_hours', 'waitlist_offer'];
// Follow-up emails: the same kinds as the follow-up texts, for tasks whose channel is email (a task moves to
// email when the customer cannot be texted but can be emailed). Same dry-run switch and Resend box as the
// other email workflows. Reactivation is marketing and is skipped with a visible reason until unsubscribe exists.
const followupEmails = smsFlow('Zella - Follow-up Emails', {
  runName: 'followup-emails', email: true, claimName: 'Claim follow-up emails', finishName: 'Finish follow-up',
  claim: (n, pos) => rpcNode(n, pos, 'zella_claim_followup_emails', `={{ JSON.stringify({ p_limit: 20, p_kinds: ${JSON.stringify(FOLLOWUP_EMAIL_KINDS)} }) }}`),
  files: { plan: 'email-task-plan.js', decide: 'email-task-decide.js', afterLog: 'email-task-after-log.js', afterSend: 'email-task-after-send.js' },
});

// Follow-up texts: no-show, post-visit, quote and reactivation. Text tasks only, so call tasks are
// never picked up here. (Waitlist offers need reply handling and are not included yet.)
const followupSender = smsFlow('Zella - Follow-up Texts', {
  runName: 'followup-texts', claimName: 'Claim follow-ups', finishName: 'Finish follow-up',
  claim: (n, pos) => rpcNode(n, pos, 'zella_claim_followup_texts', `={{ JSON.stringify({ p_limit: 20, p_kinds: ${JSON.stringify(FOLLOWUP_KINDS)} }) }}`),
  files: { plan: 'sms-task-plan.js', decide: 'sms-task-decide.js', afterLog: 'sms-task-after-log.js', afterSend: 'sms-task-after-send.js' },
});

// Outbound calls: callbacks Zella may place itself (missed call, new lead) and follow-up tasks set to "call".
// Dry-run by default: until calls_live is true and Vapi is set up, nothing is dialled and the item is put back
// for later. The Vapi box ships with NO credential, for the same reason as Telnyx and Resend. The result of a
// call (answered, no answer, voicemail) arrives afterwards from Vapi's end-of-call report.
const outboundCalls = wf('Zella - Outbound Calls', [
  runTrigger('outbound-calls'),
  rpcNode('Claim callback calls', [240, 100], 'zella_claim_callback_calls', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  rpcNode('Claim follow-up calls', [240, 300], 'zella_claim_followup_calls', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan', [480, 200], 'call-plan.js'),
  ifBool('Place call', [720, 200], '={{ !!$json.call }}'),
  node('Start Vapi call', 'n8n-nodes-base.httpRequest', 4.2, [960, 100], {
    method: 'POST', url: 'https://api.vapi.ai/call', authentication: 'none',
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.call) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('After call', [1200, 100], 'call-after.js'),
  rpcNode('Record call', [1440, 200], '', '={{ JSON.stringify($json.record.body) }}',
    { full: true, urlExpr: `={{ '${SUPABASE}/rest/v1/rpc/' + $json.record.rpc }}` }),
], {
  'Run now': { main: [[link('Claim callback calls'), link('Claim follow-up calls')]] },
  'Claim callback calls': { main: [[link('Plan')]] },
  'Claim follow-up calls': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Place call')]] },
  'Place call': { main: [[link('Start Vapi call')], [link('Record call')]] },
  'Start Vapi call': { main: [[link('After call')]] },
  'After call': { main: [[link('Record call')]] },
});

// Call results: Vapi posts an end-of-call report when a call Zella placed ends. Event-driven (runs only then).
// Point the Vapi assistant's server URL at <n8n>/webhook/zella/vapi with the header X-Zella-Secret, and set its
// server messages to end-of-call-report and status-update only, so no other message wakes the workflow.
// status-update creates the call record as the call starts (zella_record_call_status), so a lost report can't erase it.
const callResults = secureVapi(wf('Zella - Call Results', [
  node('Vapi report', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/vapi', authentication: 'headerAuth', responseMode: 'onReceived', options: {},
  }, { webhookId: id('webhook:zella-vapi'), credentials: GATEWAY_CRED }),
  code('Plan', [240, 200], 'call-result-plan.js'),
  ifBool('Is a call result', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Record call result', [720, 100], 'zella_record_call_result', '={{ JSON.stringify($json.record) }}', { full: true }),
  ifBool('Is an inbound call', [720, 320], '={{ !!$json.inbound }}'),
  rpcNode('Record inbound call', [960, 320], 'zella_record_inbound_call', '={{ JSON.stringify($json.inbound) }}', { full: true }),
  ifBool('Is a status update', [960, 520], '={{ !!$json.status }}'),
  rpcNode('Record call status', [1200, 520], 'zella_record_call_status', '={{ JSON.stringify($json.status) }}', { full: true }),
], {
  'Vapi report': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a call result')]] },
  'Is a call result': { main: [[link('Record call result')], [link('Is an inbound call')]] },
  'Is an inbound call': { main: [[link('Record inbound call')], [link('Is a status update')]] },
  'Is a status update': { main: [[link('Record call status')], []] },
}), 'Vapi report', false);

// Knowledge: (1) publish knowledge an owner added or changed, (2) draft answers for questions the assistant could not
// answer (the owner must still approve them). Started by the dispatcher only when something is waiting. The AI box
// ships with NO credential and is skipped unless knowledge_ai_live is true; add the Anthropic key by hand.
const knowledge = wf('Zella - Knowledge', [
  runTrigger('knowledge-sync'),
  rpcNode('Claim knowledge updates', [240, 100], 'zella_claim_knowledge_updates', '={{ JSON.stringify({ p_limit: 20 }) }}'),
  code('Check item', [480, 100], 'knowledge-check.js'),
  ifBool('Has update', [720, 100], '={{ !!$json.record }}'),
  rpcNode('Mark item', [960, 0], 'zella_complete_knowledge_update', '={{ JSON.stringify($json.record) }}', { full: true }),
  rpcNode('Claim questions', [240, 400], 'zella_claim_gap_drafts', '={{ JSON.stringify({ p_limit: 5 }) }}'),
  code('Draft plan', [480, 400], 'knowledge-draft-plan.js'),
  ifBool('Has request', [720, 400], '={{ !!$json.request }}'),
  node('Ask AI', 'n8n-nodes-base.httpRequest', 4.2, [960, 300], {
    method: 'POST', url: 'https://api.anthropic.com/v1/messages', authentication: 'none',
    sendHeaders: true, headerParameters: { parameters: [{ name: 'anthropic-version', value: '2023-06-01' }] },
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.request) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('Read draft', [1200, 300], 'knowledge-draft-after.js'),
  ifBool('Has draft', [1440, 300], '={{ !!$json.record }}'),
  rpcNode('Save draft', [1680, 200], 'zella_set_gap_suggestion', '={{ JSON.stringify($json.record) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim knowledge updates'), link('Claim questions')]] },
  'Claim knowledge updates': { main: [[link('Check item')]] },
  'Check item': { main: [[link('Has update')]] },
  'Has update': { main: [[link('Mark item')], []] },
  'Claim questions': { main: [[link('Draft plan')]] },
  'Draft plan': { main: [[link('Has request')]] },
  'Has request': { main: [[link('Ask AI')], []] },
  'Ask AI': { main: [[link('Read draft')]] },
  'Read draft': { main: [[link('Has draft')]] },
  'Has draft': { main: [[link('Save draft')], []] },
});

// Assistant tools: Vapi calls this DURING a call (a server tool) when the assistant cannot answer a question. It logs the
// question for the owner to review (the Knowledge workflow then drafts an answer). It answers Vapi straight away.
// One item per tool call, so several tool calls in one request each get their own answer, matched by toolCallId.
// In Vapi: add a server tool "report_unanswered_question" (parameter: question, text) pointing at
// <n8n>/webhook/zella/vapi-tools with the X-Zella-Secret header. The call must carry the business id (call metadata
// or the assistant variable business_id) unless the call is already known to Zella.
const assistantTools = secureVapi(wf('Zella - Assistant Tools', [
  node('Vapi tool call', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/vapi-tools', authentication: 'headerAuth', responseMode: 'responseNode', options: {},
  }, { webhookId: id('webhook:zella-vapi-tools'), credentials: GATEWAY_CRED }),
  codeAll('Plan', [240, 200], 'vapi-tool-plan.js'),
  ifBool('Has question', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Find business', [720, 100], 'zella_business_for_number', '={{ JSON.stringify($json.lookup) }}', { full: true }),
  code('Use business', [960, 100], 'business-apply.js'),
  rpcNode('Log question', [1200, 100], '', '={{ JSON.stringify($json.record) }}', { full: true, urlExpr: `={{ '${SUPABASE}/rest/v1/rpc/' + $json.rpc }}` }),
  code('Build reply', [1440, 100], 'vapi-tool-reply.js'),
  codeAll('Collect replies', [1680, 100], 'brain-tool-collect.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1920, 200], {
    respondWith: 'json', responseBody: '={{ JSON.stringify({ results: Array.isArray($json.results) ? $json.results : [] }) }}', options: { responseCode: 200 },
  }),
], {
  'Vapi tool call': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Has question')]] },
  'Has question': { main: [[link('Find business')], [link('Reply')]] },
  'Find business': { main: [[link('Use business')]] },
  'Use business': { main: [[link('Log question')]] },
  'Log question': { main: [[link('Build reply')]] },
  'Build reply': { main: [[link('Collect replies')]] },
  'Collect replies': { main: [[link('Reply')]] },
}), 'Vapi tool call', true);

// Appointment booking by the phone assistant: Vapi calls this during a call with two tools, check_availability and
// book_appointment (and, for existing bookings, find_my_appointments / reschedule_appointment / cancel_appointment).
// They go through the same gateway as the Receptionist Brain (zella_ai_tool: the caller must confirm before a booking is
// changed, retries return the first answer, every call is logged), limited to these five tools, one answer per tool call.
const BOOKING_TOOLS = 'check_availability,book_appointment,find_my_appointments,reschedule_appointment,cancel_appointment';
const aiBooking = secureVapi(wf('Zella - Appointment Booking', [
  node('Vapi booking tool', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/vapi-booking', authentication: 'headerAuth', responseMode: 'responseNode', options: {},
  }, { webhookId: id('webhook:zella-vapi-booking'), credentials: GATEWAY_CRED }),
  codeAll('Plan', [240, 200], 'brain-tool-plan.js', { ONLY_TOOLS: BOOKING_TOOLS }),
  ifBool('Is a booking tool', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Find business', [720, 100], 'zella_business_for_number', '={{ JSON.stringify($json.lookup) }}', { full: true }),
  code('Use business', [960, 100], 'business-apply.js'),
  rpcNode('Run booking', [1200, 100], 'zella_ai_tool', '={{ JSON.stringify($json.record) }}', { full: true }),
  code('Build reply', [1440, 100], 'brain-tool-reply.js'),
  codeAll('Collect replies', [1680, 100], 'brain-tool-collect.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1920, 200], {
    respondWith: 'json', responseBody: '={{ JSON.stringify({ results: Array.isArray($json.results) ? $json.results : [] }) }}', options: { responseCode: 200 },
  }),
], {
  'Vapi booking tool': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a booking tool')]] },
  'Is a booking tool': { main: [[link('Find business')], [link('Reply')]] },
  'Find business': { main: [[link('Use business')]] },
  'Use business': { main: [[link('Run booking')]] },
  'Run booking': { main: [[link('Build reply')]] },
  'Build reply': { main: [[link('Collect replies')]] },
  'Collect replies': { main: [[link('Reply')]] },
}), 'Vapi booking tool', true);

// Voice rules: the phone assistant asks "call_rules" during a call (open or closed, take a message, emergency, reach a person).
// Every decision is made by the database (zella_ai_voice); this workflow only passes the question on and the answer back.
// One item per tool call, each answered under its own toolCallId. The voice-rules Supabase function does the same without n8n.
const voiceRules = secureVapi(wf('Zella - Voice Rules', [
  node('Vapi voice tool', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/vapi-voice', authentication: 'headerAuth', responseMode: 'responseNode', options: {},
  }, { webhookId: id('webhook:zella-vapi-voice'), credentials: GATEWAY_CRED }),
  codeAll('Plan', [240, 200], 'voice-tool-plan.js'),
  ifBool('Is a voice tool', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Find business', [720, 100], 'zella_business_for_number', '={{ JSON.stringify($json.lookup) }}', { full: true }),
  code('Use business', [960, 100], 'business-apply.js'),
  rpcNode('Run voice rule', [1200, 100], '', '={{ JSON.stringify($json.record) }}', { full: true, urlExpr: `={{ '${SUPABASE}/rest/v1/rpc/' + $json.rpc }}` }),
  code('Build reply', [1440, 100], 'voice-tool-reply.js'),
  codeAll('Collect replies', [1680, 100], 'brain-tool-collect.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1920, 200], {
    respondWith: 'json', responseBody: '={{ JSON.stringify({ results: Array.isArray($json.results) ? $json.results : [] }) }}', options: { responseCode: 200 },
  }),
], {
  'Vapi voice tool': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a voice tool')]] },
  'Is a voice tool': { main: [[link('Find business')], [link('Reply')]] },
  'Find business': { main: [[link('Use business')]] },
  'Use business': { main: [[link('Run voice rule')]] },
  'Run voice rule': { main: [[link('Build reply')]] },
  'Build reply': { main: [[link('Collect replies')]] },
  'Collect replies': { main: [[link('Reply')]] },
}), 'Vapi voice tool', true);

// Inbound email: Resend posts here when a customer replies to an email. The event only names the email, so it is fetched
// from Resend (key added by hand at go-live) and handed to the database, which checks the secret key in the address,
// finds the business and customer, sorts the reply and tells the team. Always answers 200 so Resend does not keep retrying.
const inboundEmail = wf('Zella - Inbound Email', [
  node('Resend inbound', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/inbound-email', authentication: 'none', responseMode: 'responseNode', options: { rawBody: true },
  }, { webhookId: id('webhook:zella-inbound-email') }),
  code('Plan', [240, 200], 'inbound-email-plan.js'),
  ifBool('Is an email', [480, 200], '={{ !!$json.fetch }}'),
  node('Fetch email', 'n8n-nodes-base.httpRequest', 4.2, [720, 100], {
    method: 'GET', url: '={{ $json.fetch.url }}', authentication: 'none',
    options: { timeout: 15000, response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('Map email', [960, 100], 'inbound-email-map.js'),
  ifBool('Has email', [1200, 100], '={{ !!$json.record }}'),
  rpcNode('Save email', [1440, 0], 'zella_receive_inbound_email_signed', '={{ JSON.stringify($json.record) }}', { full: true }),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1680, 200], {
    respondWith: 'json', responseBody: '={{ JSON.stringify({ ok: true }) }}', options: { responseCode: 200 },
  }),
], {
  'Resend inbound': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is an email')]] },
  'Is an email': { main: [[link('Fetch email')], [link('Reply')]] },
  'Fetch email': { main: [[link('Map email')]] },
  'Map email': { main: [[link('Has email')]] },
  'Has email': { main: [[link('Save email')], [link('Reply')]] },
  'Save email': { main: [[link('Reply')]] },
});

// Email events: Resend posts here when an email is delivered, bounces or is marked as spam. Event-driven (runs only then).
// Resend cannot send a custom header, so the webhook address carries a secret key (?key=...) and the DATABASE checks it
// against a Vault secret; a wrong key changes nothing. Bad addresses and spam complaints are never emailed again.
const emailEvents = wf('Zella - Email Events', [
  node('Resend event', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/resend', authentication: 'none', responseMode: 'responseNode', options: { rawBody: true },
  }, { webhookId: id('webhook:zella-resend') }),
  code('Plan', [240, 200], 'email-event-plan.js'),
  ifBool('Has event', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Record event', [720, 100], 'zella_record_email_event_signed', '={{ JSON.stringify($json.record) }}', { full: true }),
  code('Build reply', [960, 200], 'email-event-reply.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1200, 200], {
    respondWith: 'json', responseBody: '={{ JSON.stringify($json.body) }}', options: { responseCode: '={{ $json.status }}' },
  }),
], {
  'Resend event': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Has event')]] },
  'Has event': { main: [[link('Record event')], [link('Build reply')]] },
  'Record event': { main: [[link('Build reply')]] },
  'Build reply': { main: [[link('Reply')]] },
});

// Calendar Sync: copies bookings to the business's Google Calendar and reads its busy times back into Zella.
// Started by the dispatcher only when a booking change or a refresh is waiting (and calendar_sync_live is true).
// The two Google token boxes ship with NO credential; the Google client id and secret are pasted by hand at go-live.
const googleToken = (name, pos, tokenExpr) => node(name, 'n8n-nodes-base.httpRequest', 4.2, pos, {
  method: 'POST', url: 'https://oauth2.googleapis.com/token', authentication: 'none',
  sendBody: true, contentType: 'form-urlencoded',
  bodyParameters: { parameters: [
    { name: 'grant_type', value: 'refresh_token' },
    { name: 'refresh_token', value: tokenExpr },
    { name: 'client_id', value: 'PASTE_GOOGLE_CLIENT_ID' },
    { name: 'client_secret', value: 'PASTE_GOOGLE_CLIENT_SECRET' },
  ] },
  options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
});
const googleAuthHeader = { sendHeaders: true, headerParameters: { parameters: [{ name: 'Authorization', value: '=Bearer {{ $json.body.access_token }}' }] } };
const calendarSync = wf('Zella - Calendar Sync', [
  runTrigger('calendar-sync'),
  rpcNode('Claim sync items', [240, 100], 'zella_claim_calendar_sync', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan sync', [480, 100], 'calendar-sync-plan.js'),
  ifBool('Needs Google', [720, 100], '={{ $json.needs_google }}'),
  googleToken('Get Google token', [960, 0], "={{ $('Plan sync').item.json.token_form.refresh_token }}"),
  ifBool('Token ok', [1200, 0], '={{ !!$json.body && !!$json.body.access_token }}'),
  ifBool('Is delete', [1440, -60], "={{ $('Plan sync').item.json.google.method === 'DELETE' }}"),
  node('Google call', 'n8n-nodes-base.httpRequest', 4.2, [1680, -140], {
    method: "={{ $('Plan sync').item.json.google.method }}", url: "={{ $('Plan sync').item.json.google.url }}", authentication: 'none',
    ...googleAuthHeader,
    sendBody: true, specifyBody: 'json',
    jsonBody: "={{ JSON.stringify($('Plan sync').item.json.google.body) }}",
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  node('Google delete', 'n8n-nodes-base.httpRequest', 4.2, [1680, 20], {
    method: 'DELETE', url: "={{ $('Plan sync').item.json.google.url }}", authentication: 'none', ...googleAuthHeader,
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('Read result', [1680, 100], 'calendar-sync-after.js'),
  ifBool('Has result', [1920, 100], '={{ !!$json.record }}'),
  rpcNode('Finish sync', [2160, 0], 'zella_finish_calendar_sync', '={{ JSON.stringify($json.record) }}', { full: true }),
  rpcNode('Claim refreshes', [240, 500], 'zella_claim_calendar_pulls', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan pull', [480, 500], 'calendar-pull-plan.js'),
  googleToken('Get pull token', [720, 500], "={{ $json.token_form ? $json.token_form.refresh_token : '' }}"),
  ifBool('Pull token ok', [960, 500], '={{ !!$json.body && !!$json.body.access_token }}'),
  node('List events', 'n8n-nodes-base.httpRequest', 4.2, [1200, 400], {
    method: 'GET', url: "={{ $('Plan pull').item.json.url }}", authentication: 'none', ...googleAuthHeader,
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('Map busy', [1440, 500], 'calendar-pull-map.js'),
  ifBool('Has events', [1680, 500], '={{ !!$json.events }}'),
  rpcNode('Replace busy times', [1920, 400], 'zella_replace_calendar_busy', '={{ JSON.stringify($json.events) }}', { full: true }),
  ifBool('Has error', [1920, 620], '={{ !!$json.error }}'),
  rpcNode('Mark error', [2160, 620], 'zella_calendar_mark_error', '={{ JSON.stringify($json.error) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim sync items'), link('Claim refreshes')]] },
  'Claim sync items': { main: [[link('Plan sync')]] },
  'Plan sync': { main: [[link('Needs Google')]] },
  'Needs Google': { main: [[link('Get Google token')], [link('Read result')]] },
  'Get Google token': { main: [[link('Token ok')]] },
  'Token ok': { main: [[link('Is delete')], [link('Read result')]] },
  'Is delete': { main: [[link('Google delete')], [link('Google call')]] },
  'Google delete': { main: [[link('Read result')]] },
  'Google call': { main: [[link('Read result')]] },
  'Read result': { main: [[link('Has result')]] },
  'Has result': { main: [[link('Finish sync')], []] },
  'Claim refreshes': { main: [[link('Plan pull')]] },
  'Plan pull': { main: [[link('Get pull token')]] },
  'Get pull token': { main: [[link('Pull token ok')]] },
  'Pull token ok': { main: [[link('List events')], [link('Map busy')]] },
  'List events': { main: [[link('Map busy')]] },
  'Map busy': { main: [[link('Has events')]] },
  'Has events': { main: [[link('Replace busy times')], [link('Has error')]] },
  'Has error': { main: [[link('Mark error')], []] },
});


// ------------------------------------------------------------------ Connection Tests
// Every few hours (when provider_checks_live is true) the dispatcher wakes this workflow. It makes one cheap read-only call to
// each provider (Telnyx, Vapi, Resend) and records only whether it worked. The three boxes ship with NO credential, for
// the same reason as the sender boxes: add each provider's key by hand when going live.
const checkBox = (name, position, url) => node(name, 'n8n-nodes-base.httpRequest', 4.2, position, {
  method: 'GET', url, authentication: 'none',
  options: { timeout: 10000, response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
});
const connectionTests = wf('Zella - Connection Tests', [
  runTrigger('connection-tests'),
  rpcNode('Claim checks', [240, 200], 'zella_claim_provider_checks', '={{ JSON.stringify({ p_limit: 5 }) }}'),
  code('Plan', [480, 200], 'provider-check-plan.js'),
  ifBool('Is Telnyx', [720, 200], "={{ $json.provider === 'telnyx' }}"),
  checkBox('Check Telnyx', [960, 60], 'https://api.telnyx.com/v2/balance'),
  ifBool('Is Vapi', [960, 300], "={{ $json.provider === 'vapi' }}"),
  checkBox('Check Vapi', [1200, 200], 'https://api.vapi.ai/assistant?limit=1'),
  ifBool('Is Resend', [1200, 420], "={{ $json.provider === 'resend' }}"),
  checkBox('Check Resend', [1440, 340], 'https://api.resend.com/domains'),
  code('Read result', [1680, 200], 'provider-check-after.js'),
  ifBool('Has result', [1920, 200], '={{ !!$json.record }}'),
  rpcNode('Record check', [2160, 200], 'zella_record_provider_check', '={{ JSON.stringify($json.record) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim checks')]] },
  'Claim checks': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is Telnyx')]] },
  'Is Telnyx': { main: [[link('Check Telnyx')], [link('Is Vapi')]] },
  'Is Vapi': { main: [[link('Check Vapi')], [link('Is Resend')]] },
  'Is Resend': { main: [[link('Check Resend')], []] },
  'Check Telnyx': { main: [[link('Read result')]] },
  'Check Vapi': { main: [[link('Read result')]] },
  'Check Resend': { main: [[link('Read result')]] },
  'Read result': { main: [[link('Has result')]] },
  'Has result': { main: [[link('Record check')], []] },
});


// ------------------------------------------------------------------ Meta (Facebook, Instagram, WhatsApp)
// Supabase decides everything (signature check, leads, messages, comments, retries, connection health: sql/zella_meta.sql).
// n8n only (1) answers Meta's webhook, (2) fetches a lead's details from Meta, (3) sends replies, (4) checks the connection.
// The page token is read from the database for each call and is never stored in a workflow. Set these workflows to
// "do not save successful executions" so the token does not stay in the execution history.
const graphGet = (name, position, urlExpr, authExpr) => node(name, 'n8n-nodes-base.httpRequest', 4.2, position, {
  method: 'GET', url: urlExpr, authentication: 'none', sendHeaders: true,
  headerParameters: { parameters: [{ name: 'Authorization', value: authExpr }] },
  options: { timeout: 15000, response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
});
const tokenRpc = (position) => rpcNode('Get token', position, 'zella_meta_token', '={{ JSON.stringify({ p_page_id: $json.page_id }) }}', { full: true });

const metaWebhook = wf('Zella - Meta Webhook', [
  node('Meta set-up check', 'n8n-nodes-base.webhook', 2, [0, 80], {
    httpMethod: 'GET', path: 'zella/meta', authentication: 'none', responseMode: 'responseNode', options: {},
  }, { webhookId: id('webhook:zella-meta-get') }),
  code('Check', [240, 80], 'meta-verify-plan.js'),
  rpcNode('Verify word', [480, 80], 'zella_meta_verify_token', '={{ JSON.stringify($json.record) }}', { full: true }),
  code('Answer check', [720, 80], 'meta-verify-after.js'),
  ifBool('Word is right', [960, 80], '={{ $json.ok }}'),
  node('Send challenge', 'n8n-nodes-base.respondToWebhook', 1.1, [1200, 0], { respondWith: 'text', responseBody: '={{ $json.challenge }}', options: { responseCode: 200 } }),
  node('Refuse check', 'n8n-nodes-base.respondToWebhook', 1.1, [1200, 160], { respondWith: 'text', responseBody: 'forbidden', options: { responseCode: 403 } }),
  node('Meta events', 'n8n-nodes-base.webhook', 2, [0, 400], {
    httpMethod: 'POST', path: 'zella/meta', authentication: 'none', responseMode: 'responseNode', options: { rawBody: true },
  }, { webhookId: id('webhook:zella-meta-post') }),
  node('Prepare', 'n8n-nodes-base.code', 2, [240, 400], { mode: 'runOnceForAllItems', jsCode: loadCode('meta-receive-plan.js') }),
  rpcNode('Save events', [480, 400], 'zella_meta_receive', '={{ JSON.stringify($json.record) }}', { full: true }),
  code('Answer', [720, 400], 'meta-receive-after.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [960, 400], { respondWith: 'json', responseBody: '={{ JSON.stringify($json.body) }}', options: { responseCode: '={{ $json.code }}' } }),
], {
  'Meta set-up check': { main: [[link('Check')]] },
  'Check': { main: [[link('Verify word')]] },
  'Verify word': { main: [[link('Answer check')]] },
  'Answer check': { main: [[link('Word is right')]] },
  'Word is right': { main: [[link('Send challenge')], [link('Refuse check')]] },
  'Meta events': { main: [[link('Prepare')]] },
  'Prepare': { main: [[link('Save events')]] },
  'Save events': { main: [[link('Answer')]] },
  'Answer': { main: [[link('Reply')]] },
});

const metaLeads = wf('Zella - Meta Leads', [
  runTrigger('meta-leads'),
  rpcNode('Claim leads', [240, 200], 'zella_meta_claim_leads', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan', [480, 200], 'meta-lead-plan.js'),
  ifBool('Is a lead', [720, 200], '={{ !$json.skip }}'),
  tokenRpc([960, 100]),
  code('Build request', [1200, 100], 'meta-lead-request.js'),
  ifBool('Can fetch', [1440, 100], '={{ !$json.fail }}'),
  graphGet('Fetch lead', [1680, 0], '={{ $json.url }}', '={{ $json.auth }}'),
  code('Read result', [1920, 200], 'meta-lead-after.js'),
  ifBool('Can save', [2160, 200], '={{ !!$json.save }}'),
  rpcNode('Save lead', [2400, 100], 'zella_meta_capture_lead', '={{ JSON.stringify($json.save) }}', { full: true }),
  rpcNode('Record failure', [2400, 320], 'zella_meta_fail_event', '={{ JSON.stringify($json.fail) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim leads')]] },
  'Claim leads': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a lead')]] },
  'Is a lead': { main: [[link('Get token')], []] },
  'Get token': { main: [[link('Build request')]] },
  'Build request': { main: [[link('Can fetch')]] },
  'Can fetch': { main: [[link('Fetch lead')], [link('Read result')]] },
  'Fetch lead': { main: [[link('Read result')]] },
  'Read result': { main: [[link('Can save')]] },
  'Can save': { main: [[link('Save lead')], [link('Record failure')]] },
});

const metaSender = wf('Zella - Meta Sender', [
  runTrigger('meta-sender'),
  rpcNode('Claim replies', [240, 200], 'zella_meta_claim_outbox', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan', [480, 200], 'meta-send-plan.js'),
  ifBool('Is a reply', [720, 200], '={{ !$json.skip }}'),
  node('Get token', 'n8n-nodes-base.httpRequest', 4.2, [960, 100], {
    method: 'POST', url: `${SUPABASE}/rest/v1/rpc/zella_meta_token`, authentication: 'genericCredentialType', genericAuthType: 'httpCustomAuth',
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify({ p_page_id: $json.page_id }) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }, { credentials: SUPABASE_CRED }),
  code('Build request', [1200, 100], 'meta-send-request.js'),
  ifBool('Can send', [1440, 100], '={{ !$json.fail }}'),
  node('Send reply', 'n8n-nodes-base.httpRequest', 4.2, [1680, 0], {
    method: 'POST', url: '={{ $json.url }}', authentication: 'none', sendHeaders: true,
    headerParameters: { parameters: [{ name: 'Authorization', value: '={{ $json.auth }}' }] },
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.body) }}',
    options: { timeout: 15000, response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('Read result', [1920, 200], 'meta-send-after.js'),
  rpcNode('Record send', [2160, 200], 'zella_meta_record_send', '={{ JSON.stringify($json.record) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim replies')]] },
  'Claim replies': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a reply')]] },
  'Is a reply': { main: [[link('Get token')], []] },
  'Get token': { main: [[link('Build request')]] },
  'Build request': { main: [[link('Can send')]] },
  'Can send': { main: [[link('Send reply')], [link('Read result')]] },
  'Send reply': { main: [[link('Read result')]] },
  'Read result': { main: [[link('Record send')]] },
});

const metaHealth = wf('Zella - Meta Health', [
  runTrigger('meta-health'),
  rpcNode('Claim checks', [240, 200], 'zella_meta_claim_checks', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan', [480, 200], 'meta-health-plan.js'),
  ifBool('Is a check', [720, 200], '={{ !$json.skip }}'),
  tokenRpc([960, 100]),
  code('Build request', [1200, 100], 'meta-health-request.js'),
  ifBool('Can check', [1440, 100], '={{ !$json.fail }}'),
  graphGet('Check connection', [1680, 0], '={{ $json.url }}', '={{ $json.auth }}'),
  code('Read result', [1920, 200], 'meta-health-after.js'),
  rpcNode('Record check', [2160, 200], 'zella_meta_record_check', '={{ JSON.stringify($json.record) }}', { full: true }),
  ifBool('Has WhatsApp', [2400, 200], "={{ $('Read result').item.json.templates }}"),
  graphGet('Get templates', [2640, 100], "={{ 'https://graph.facebook.com/v21.0/' + $('Build request').item.json.waba_id + '/message_templates?fields=name,language,status,category,components&limit=100' }}", "={{ $('Build request').item.json.auth }}"),
  code('Map templates', [2880, 100], 'meta-templates-map.js'),
  ifBool('Has templates', [3120, 100], '={{ !!$json.record }}'),
  rpcNode('Record templates', [3360, 100], 'zella_meta_record_templates', '={{ JSON.stringify($json.record) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim checks')]] },
  'Claim checks': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a check')]] },
  'Is a check': { main: [[link('Get token')], []] },
  'Get token': { main: [[link('Build request')]] },
  'Build request': { main: [[link('Can check')]] },
  'Can check': { main: [[link('Check connection')], [link('Read result')]] },
  'Check connection': { main: [[link('Read result')]] },
  'Read result': { main: [[link('Record check')]] },
  'Record check': { main: [[link('Has WhatsApp')]] },
  'Has WhatsApp': { main: [[link('Get templates')], []] },
  'Get templates': { main: [[link('Map templates')]] },
  'Map templates': { main: [[link('Has templates')]] },
  'Has templates': { main: [[link('Record templates')], []] },
});

// Receptionist Brain: the webhook for every tool the phone assistant uses during a call (14 tools behind zella_ai_tool).
// One item per tool call, so several tool calls in one request each get their own answer, matched by toolCallId.
// Until phase 3 moves live-call tools to a Supabase function, this is the endpoint brain_tools_url points at.
const brainTools = secureVapi(wf('Zella - Receptionist Brain Tools', [
  node('Vapi brain tool', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/vapi-brain', authentication: 'headerAuth', responseMode: 'responseNode', options: {},
  }, { webhookId: '9439095a-ccca-43a3-bc4b-5a5c07862415', credentials: GATEWAY_CRED }),
  codeAll('Plan', [240, 200], 'brain-tool-plan.js'),
  ifBool('Is a brain tool', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Find business', [720, 100], 'zella_business_for_number', '={{ JSON.stringify($json.lookup) }}', { full: true }),
  code('Use business', [960, 100], 'business-apply.js'),
  rpcNode('Run tool', [1200, 100], 'zella_ai_tool', '={{ JSON.stringify($json.record) }}', { full: true }),
  code('Build reply', [1440, 100], 'brain-tool-reply.js'),
  codeAll('Collect replies', [1680, 100], 'brain-tool-collect.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1920, 200], {
    respondWith: 'json', responseBody: '={{ JSON.stringify({ results: Array.isArray($json.results) ? $json.results : [] }) }}', options: { responseCode: 200 },
  }),
], {
  'Vapi brain tool': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a brain tool')]] },
  'Is a brain tool': { main: [[link('Find business')], [link('Reply')]] },
  'Find business': { main: [[link('Use business')]] },
  'Use business': { main: [[link('Run tool')]] },
  'Run tool': { main: [[link('Build reply')]] },
  'Build reply': { main: [[link('Collect replies')]] },
  'Collect replies': { main: [[link('Reply')]] },
}), 'Vapi brain tool', true);
writeFileSync(join(out, 'zella-brain-tools.json'), JSON.stringify(brainTools, null, 2) + '\n');

// Call Reconciliation: for calls whose end-of-call report never arrived, ask the provider for its record of the call and
// let the database complete it (zella_reconcile_call). Started by the dispatcher only when such calls exist; off until
// call_reconcile_live is true. The "Fetch Vapi call" box ships with NO credential: add the Vapi private key by hand.
const callReconcile = wf('Zella - Call Reconciliation', [
  runTrigger('call-reconcile'),
  rpcNode('Claim calls', [240, 200], 'zella_calls_to_reconcile', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan', [480, 200], 'reconcile-plan.js'),
  ifBool('Can fetch', [720, 200], '={{ !$json.skip }}'),
  node('Fetch Vapi call', 'n8n-nodes-base.httpRequest', 4.2, [960, 100], {
    method: 'GET', url: '={{ $json.url }}', authentication: 'none',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('Read call', [1200, 100], 'reconcile-read.js'),
  rpcNode('Record call', [1440, 100], 'zella_reconcile_call', '={{ JSON.stringify($json.record) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim calls')]] },
  'Claim calls': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Can fetch')]] },
  'Can fetch': { main: [[link('Fetch Vapi call')], []] },
  'Fetch Vapi call': { main: [[link('Read call')]] },
  'Read call': { main: [[link('Record call')]] },
});
writeFileSync(join(out, 'zella-call-reconciliation.json'), JSON.stringify(callReconcile, null, 2) + '\n');

writeFileSync(join(out, 'zella-event-gateway.json'), JSON.stringify(gateway, null, 2) + '\n');
writeFileSync(join(out, 'zella-event-router.json'), JSON.stringify(router, null, 2) + '\n');

// Website crawler: reads only the pages the owner approved (and the sitemap of an approved site), then hands what it
// found to the database, which keeps it as DRAFT knowledge for the owner to review. Started by the dispatcher only
// when a page or sitemap is due. Off until the platform setting website_crawl_live is true.
const websiteCrawler = wf('Zella - Website Crawler', [
  runTrigger('website-crawl'),
  rpcNode('Claim work', [240, 200], 'zella_website_claim', '={{ JSON.stringify({ p_limit: 6 }) }}'),
  code('Plan', [480, 200], 'website-plan.js'),
  ifBool('Safe to read', [720, 200], '={{ !$json.skip }}'),
  node('Fetch page', 'n8n-nodes-base.httpRequest', 4.2, [960, 100], {
    method: 'GET', url: '={{ $json.url }}', authentication: 'none',
    sendHeaders: true, headerParameters: { parameters: [{ name: 'User-Agent', value: 'ZellaBot/1.0 (reads pages its owner approved)' }, { name: 'Accept', value: 'text/html,application/xhtml+xml,application/xml;q=0.9' }] },
    options: { timeout: 15000, redirect: { redirect: { followRedirects: false } }, response: { response: { fullResponse: true, neverError: true, responseFormat: 'text' } } },
  }, { onError: 'continueRegularOutput' }),
  code('Parse', [1200, 100], 'website-parse.js'),
  ifBool('Is sitemap', [1440, 100], "={{ $json.mode === 'discover' }}"),
  rpcNode('Record sitemap', [1680, 0], 'zella_website_record_discovery', '={{ JSON.stringify($json.rpc) }}', { full: true }),
  rpcNode('Record page', [1680, 220], 'zella_website_record_page', '={{ JSON.stringify($json.rpc) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim work')]] },
  'Claim work': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Safe to read')]] },
  'Safe to read': { main: [[link('Fetch page')], []] },
  'Fetch page': { main: [[link('Parse')]] },
  'Parse': { main: [[link('Is sitemap')]] },
  'Is sitemap': { main: [[link('Record sitemap')], [link('Record page')]] },
});


// Failure alert: n8n runs this whenever another Zella workflow fails (set as that workflow's error workflow at go-live).
// It raises one platform alert in the database (deduped per workflow and step). No customer data is copied.
const failureAlert = wf('Zella - Failure Alert', [
  node('A workflow failed', 'n8n-nodes-base.errorTrigger', 1, [0, 200], {}),
  code('Describe failure', [240, 200], 'failure-alert.js'),
  rpcNode('Raise alert', [480, 200], 'zella_platform_alert', '={{ JSON.stringify($json.alert) }}', { full: true }),
], {
  'A workflow failed': { main: [[link('Describe failure')]] },
  'Describe failure': { main: [[link('Raise alert')]] },
});

// Admin alerts: one plain-text digest email to the active Zella admins with the platform alerts that are waiting
// (offers ending soon, limits reached, unusual claims, offers that could not go live, failed jobs, provider problems).
// The database hands out alerts only when email_live is on and a sender address is set. The Resend box ships with
// NO credential, like the other email workflows: add the Resend key by hand at go-live. A failed send is put back
// for the next run, up to 3 tries.
const adminAlerts = wf('Zella - Admin Alerts', [
  runTrigger('admin-alerts'),
  rpcNode('Claim alerts', [240, 200], 'zella_claim_admin_alert_email', '={{ JSON.stringify({ p_limit: 25 }) }}'),
  code('Plan', [480, 200], 'admin-alerts-plan.js'),
  ifBool('Anything to send', [720, 200], '={{ !$json.skip }}'),
  ifBool('Send for real', [960, 100], '={{ !$json.finish }}'),
  node('Send via Resend', 'n8n-nodes-base.httpRequest', 4.2, [1200, 0], {
    method: 'POST', url: 'https://api.resend.com/emails', authentication: 'none',
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.resend) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('After send', [1440, 0], 'admin-alerts-after-send.js'),
  finishNode('Report back', [1680, 200]),
], {
  'Run now': { main: [[link('Claim alerts')]] },
  'Claim alerts': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Anything to send')]] },
  'Anything to send': { main: [[link('Send for real')], []] },
  'Send for real': { main: [[link('Send via Resend')], [link('Report back')]] },
  'Send via Resend': { main: [[link('After send')]] },
  'After send': { main: [[link('Report back')]] },
});

// Staff texts: urgent notifications texted to team members who switched this on for themselves. The database decides who
// and enforces a limit of 5 per business per hour; nothing is claimed until sms_live is true. Same Telnyx box rule: no credential.
const staffTexts = wf('Zella - Staff Texts', [
  runTrigger('staff-sms'),
  rpcNode('Claim staff texts', [240, 200], 'zella_claim_staff_sms', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan', [480, 200], 'staff-sms-plan.js'),
  ifBool('Is a text', [720, 200], '={{ !$json.skip }}'),
  node('Send via Telnyx', 'n8n-nodes-base.httpRequest', 4.2, [960, 100], {
    method: 'POST', url: 'https://api.telnyx.com/v2/messages', authentication: 'none',
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.telnyx) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('After send', [1200, 100], 'staff-sms-after.js'),
  rpcNode('Update message', [1440, 100], 'zella_update_outbound_sms', '={{ JSON.stringify($json.update) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim staff texts')]] },
  'Claim staff texts': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a text')]] },
  'Is a text': { main: [[link('Send via Telnyx')], []] },
  'Send via Telnyx': { main: [[link('After send')]] },
  'After send': { main: [[link('Update message')]] },
});

// Spam Response: follow-up for spam incidents the database already detected, scored, saved and (for calls) screened.
// Routes each one by severity, checks repeat offenders, asks the AI only about ambiguous texts/emails the business
// allowed it for, and hands the result back to zella_spam_finish_work, which re-checks everything and applies only
// the approved policy (notifications, a temporary restriction for a sender the team confirmed twice, a platform alert).
// Nothing here can block a caller or answer a call: that never waits for n8n. Off until spam_workflow_live is true;
// the AI box ships with NO credential and is only reached when spam_ai_live is true and a business opted in.
const spamResponse = wf('Zella - Spam Response', [
  runTrigger('spam-response'),
  rpcNode('Claim work', [240, 200], 'zella_spam_claim_work', '={{ JSON.stringify({ p_limit: 20 }) }}'),
  code('Evaluate severity', [480, 200], 'spam-severity.js'),
  ifBool('Has work', [720, 200], "={{ $json.kind === 'incident' || $json.kind === 'report' }}"),
  ifBool('Is a report', [960, 200], "={{ $json.kind === 'report' }}"),
  code('Build report', [1200, 0], 'spam-report.js'),
  rpcNode('Save report', [1440, 0], 'zella_spam_save_report', '={{ JSON.stringify($json.body) }}', { full: true }),
  ifBool('Needs follow-up', [1200, 300], "={{ $json.route === 'alert' || $json.route === 'investigate' }}"),
  rpcNode('Log event', [1440, 500], 'zella_spam_finish_work', '={{ JSON.stringify($json.finish) }}', { full: true }),
  code('Check repeat offender', [1440, 200], 'spam-investigate.js'),
  ifBool('Needs AI', [1680, 200], '={{ !!$json.ai_request }}'),
  node('Ask AI', 'n8n-nodes-base.httpRequest', 4.2, [1920, 100], {
    method: 'POST', url: 'https://api.anthropic.com/v1/messages', authentication: 'none',
    sendHeaders: true, headerParameters: { parameters: [{ name: 'anthropic-version', value: '2023-06-01' }] },
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.ai_request) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('Read AI', [2160, 100], 'spam-ai-read.js'),
  rpcNode('Apply approved policy', [2400, 300], 'zella_spam_finish_work', '={{ JSON.stringify($json.finish) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim work')]] },
  'Claim work': { main: [[link('Evaluate severity')]] },
  'Evaluate severity': { main: [[link('Has work')]] },
  'Has work': { main: [[link('Is a report')], []] },
  'Is a report': { main: [[link('Build report')], [link('Needs follow-up')]] },
  'Build report': { main: [[link('Save report')]] },
  'Needs follow-up': { main: [[link('Check repeat offender')], [link('Log event')]] },
  'Check repeat offender': { main: [[link('Needs AI')]] },
  'Needs AI': { main: [[link('Ask AI')], [link('Apply approved policy')]] },
  'Ask AI': { main: [[link('Read AI')]] },
  'Read AI': { main: [[link('Apply approved policy')]] },
});
writeFileSync(join(out, 'zella-spam-response.json'), JSON.stringify(spamResponse, null, 2) + '\n');

// Review replies: (1) read each connected Google Business Profile location's reviews every 6 hours, (2) AI rewrites of
// the standard reply draft (only when review_ai_live is on), (3) post the replies an owner approved. Started by the
// dispatcher only when something is waiting (nothing is claimed until reviews_live / review_ai_live are on).
// The two Google boxes ship with NO credential: add the Google OAuth2 credential (scope business.manage) of the Google
// account that manages the businesses' profiles by hand. The AI box ships with no credential either (Anthropic key).
const googleBox = (name, pos, method, extra = {}) => node(name, 'n8n-nodes-base.httpRequest', 4.2, pos, {
  method, url: '={{ $json.url }}', authentication: 'none', ...extra,
  options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
});
const reviewReplies = wf('Zella - Review Replies', [
  runTrigger('review-replies'),
  rpcNode('Claim locations', [240, 0], 'zella_review_claim_fetch', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan fetch', [480, 0], 'review-fetch-plan.js'),
  ifBool('Can fetch', [720, 0], '={{ !$json.skip }}'),
  googleBox('Get Google reviews', [960, -100], 'GET'),
  code('Read reviews', [1200, -100], 'review-fetch-read.js'),
  rpcNode('Save reviews', [1440, -100], 'zella_review_ingest', '={{ JSON.stringify($json.record) }}', { full: true }),
  rpcNode('Claim drafts', [240, 300], 'zella_review_claim_ai', '={{ JSON.stringify({ p_limit: 5 }) }}'),
  code('Draft plan', [480, 300], 'review-draft-plan.js'),
  ifBool('Has request', [720, 300], '={{ !!$json.request }}'),
  node('Ask AI', 'n8n-nodes-base.httpRequest', 4.2, [960, 200], {
    method: 'POST', url: 'https://api.anthropic.com/v1/messages', authentication: 'none',
    sendHeaders: true, headerParameters: { parameters: [{ name: 'anthropic-version', value: '2023-06-01' }] },
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.request) }}',
    options: { response: { response: { fullResponse: true, neverError: true, responseFormat: 'json' } } },
  }),
  code('Read draft', [1200, 200], 'review-draft-read.js'),
  rpcNode('Save draft', [1440, 200], 'zella_review_save_ai_draft', '={{ JSON.stringify($json.record) }}', { full: true }),
  rpcNode('Claim replies', [240, 600], 'zella_review_claim_posts', '={{ JSON.stringify({ p_limit: 10 }) }}'),
  code('Plan post', [480, 600], 'review-post-plan.js'),
  ifBool('Can post', [720, 600], '={{ !$json.skip }}'),
  googleBox('Post reply on Google', [960, 500], 'PUT', { sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.body) }}' }),
  code('Read result', [1200, 500], 'review-post-read.js'),
  rpcNode('Save result', [1440, 500], 'zella_review_post_result', '={{ JSON.stringify($json.record) }}', { full: true }),
], {
  'Run now': { main: [[link('Claim locations'), link('Claim drafts'), link('Claim replies')]] },
  'Claim locations': { main: [[link('Plan fetch')]] },
  'Plan fetch': { main: [[link('Can fetch')]] },
  'Can fetch': { main: [[link('Get Google reviews')], []] },
  'Get Google reviews': { main: [[link('Read reviews')]] },
  'Read reviews': { main: [[link('Save reviews')]] },
  'Claim drafts': { main: [[link('Draft plan')]] },
  'Draft plan': { main: [[link('Has request')]] },
  'Has request': { main: [[link('Ask AI')], []] },
  'Ask AI': { main: [[link('Read draft')]] },
  'Read draft': { main: [[link('Save draft')]] },
  'Claim replies': { main: [[link('Plan post')]] },
  'Plan post': { main: [[link('Can post')]] },
  'Can post': { main: [[link('Post reply on Google')], []] },
  'Post reply on Google': { main: [[link('Read result')]] },
  'Read result': { main: [[link('Save result')]] },
});
writeFileSync(join(out, 'zella-review-replies.json'), JSON.stringify(reviewReplies, null, 2) + '\n');

writeFileSync(join(out, 'zella-sms-sender.json'), JSON.stringify(smsSender, null, 2) + '\n');
writeFileSync(join(out, 'zella-email-sender.json'), JSON.stringify(emailSender, null, 2) + '\n');
writeFileSync(join(out, 'zella-owner-emails.json'), JSON.stringify(ownerEmails, null, 2) + '\n');
writeFileSync(join(out, 'zella-followup-emails.json'), JSON.stringify(followupEmails, null, 2) + '\n');
writeFileSync(join(out, 'zella-followup-texts.json'), JSON.stringify(followupSender, null, 2) + '\n');
writeFileSync(join(out, 'zella-outbound-calls.json'), JSON.stringify(outboundCalls, null, 2) + '\n');
writeFileSync(join(out, 'zella-knowledge.json'), JSON.stringify(knowledge, null, 2) + '\n');
writeFileSync(join(out, 'zella-assistant-tools.json'), JSON.stringify(assistantTools, null, 2) + '\n');
writeFileSync(join(out, 'zella-meta-webhook.json'), JSON.stringify(metaWebhook, null, 2) + '\n');
writeFileSync(join(out, 'zella-meta-leads.json'), JSON.stringify(metaLeads, null, 2) + '\n');
writeFileSync(join(out, 'zella-meta-sender.json'), JSON.stringify(metaSender, null, 2) + '\n');
writeFileSync(join(out, 'zella-meta-health.json'), JSON.stringify(metaHealth, null, 2) + '\n');
writeFileSync(join(out, 'zella-failure-alert.json'), JSON.stringify(failureAlert, null, 2) + '\n');
writeFileSync(join(out, 'zella-admin-alerts.json'), JSON.stringify(adminAlerts, null, 2) + '\n');
writeFileSync(join(out, 'zella-staff-texts.json'), JSON.stringify(staffTexts, null, 2) + '\n');
writeFileSync(join(out, 'zella-website-crawler.json'), JSON.stringify(websiteCrawler, null, 2) + '\n');
writeFileSync(join(out, 'zella-inbound-email.json'), JSON.stringify(inboundEmail, null, 2) + '\n');
writeFileSync(join(out, 'zella-voice-rules.json'), JSON.stringify(voiceRules, null, 2) + '\n');
writeFileSync(join(out, 'zella-appointment-booking.json'), JSON.stringify(aiBooking, null, 2) + '\n');
writeFileSync(join(out, 'zella-email-events.json'), JSON.stringify(emailEvents, null, 2) + '\n');
writeFileSync(join(out, 'zella-calendar-sync.json'), JSON.stringify(calendarSync, null, 2) + '\n');
writeFileSync(join(out, 'zella-connection-tests.json'), JSON.stringify(connectionTests, null, 2) + '\n');
writeFileSync(join(out, 'zella-call-results.json'), JSON.stringify(callResults, null, 2) + '\n');
console.log('Built', [gateway, router, smsSender, followupSender, emailSender, followupEmails, ownerEmails, outboundCalls, callResults, knowledge, assistantTools, voiceRules, inboundEmail, metaWebhook, metaLeads, metaSender, metaHealth, aiBooking, emailEvents, calendarSync, connectionTests, websiteCrawler, staffTexts, adminAlerts, spamResponse, brainTools, callReconcile, reviewReplies].map((w) => w.name + ' (' + w.nodes.length + ')').join(', '));
