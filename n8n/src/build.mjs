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

export const FOLLOWUP_EMAIL_KINDS = ['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms'];
// Texts also send the quick replies to HELP and waitlist offers (the database queues them).
export const FOLLOWUP_KINDS = [...FOLLOWUP_EMAIL_KINDS, 'reply_confirmed', 'reply_reschedule', 'reply_help', 'waitlist_offer'];
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
// server messages to end-of-call-report only, so no other message wakes the workflow.
const callResults = wf('Zella - Call Results', [
  node('Vapi report', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/vapi', authentication: 'headerAuth', responseMode: 'onReceived', options: {},
  }, { webhookId: id('webhook:zella-vapi'), credentials: GATEWAY_CRED }),
  code('Plan', [240, 200], 'call-result-plan.js'),
  ifBool('Is a call result', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Record call result', [720, 100], 'zella_record_call_result', '={{ JSON.stringify($json.record) }}', { full: true }),
], {
  'Vapi report': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a call result')]] },
  'Is a call result': { main: [[link('Record call result')], []] },
});

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
// In Vapi: add a server tool "report_unanswered_question" (parameter: question, text) pointing at
// <n8n>/webhook/zella/vapi-tools with the X-Zella-Secret header. The call must carry the business id (call metadata
// or the assistant variable business_id) unless the call is already known to Zella.
const assistantTools = wf('Zella - Assistant Tools', [
  node('Vapi tool call', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/vapi-tools', authentication: 'headerAuth', responseMode: 'responseNode', options: {},
  }, { webhookId: id('webhook:zella-vapi-tools'), credentials: GATEWAY_CRED }),
  code('Plan', [240, 200], 'vapi-tool-plan.js'),
  ifBool('Has question', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Log question', [720, 100], 'zella_report_unanswered', '={{ JSON.stringify($json.record) }}', { full: true }),
  code('Build reply', [960, 200], 'vapi-tool-reply.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1200, 200], {
    respondWith: 'json', responseBody: '={{ JSON.stringify($json) }}', options: { responseCode: 200 },
  }),
], {
  'Vapi tool call': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Has question')]] },
  'Has question': { main: [[link('Log question')], [link('Build reply')]] },
  'Log question': { main: [[link('Build reply')]] },
  'Build reply': { main: [[link('Reply')]] },
});

// Appointment booking by the phone assistant: Vapi calls this during a call with two tools, check_availability and
// book_appointment (and, for existing bookings, find_my_appointments / reschedule_appointment / cancel_appointment). All decisions are made in the database (zella_ai_booking); this only passes them through.
const aiBooking = wf('Zella - Appointment Booking', [
  node('Vapi booking tool', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/vapi-booking', authentication: 'headerAuth', responseMode: 'responseNode', options: {},
  }, { webhookId: id('webhook:zella-vapi-booking'), credentials: GATEWAY_CRED }),
  code('Plan', [240, 200], 'booking-tool-plan.js'),
  ifBool('Is a booking tool', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Run booking', [720, 100], '', '={{ JSON.stringify($json.record) }}', { full: true, urlExpr: `={{ '${SUPABASE}/rest/v1/rpc/' + $json.rpc }}` }),
  code('Build reply', [960, 200], 'booking-tool-reply.js'),
  node('Reply', 'n8n-nodes-base.respondToWebhook', 1.1, [1200, 200], {
    respondWith: 'json', responseBody: '={{ JSON.stringify($json) }}', options: { responseCode: 200 },
  }),
], {
  'Vapi booking tool': { main: [[link('Plan')]] },
  'Plan': { main: [[link('Is a booking tool')]] },
  'Is a booking tool': { main: [[link('Run booking')], [link('Build reply')]] },
  'Run booking': { main: [[link('Build reply')]] },
  'Build reply': { main: [[link('Reply')]] },
});

// Email events: Resend posts here when an email is delivered, bounces or is marked as spam. Event-driven (runs only then).
// Resend cannot send a custom header, so the webhook address carries a secret key (?key=...) and the DATABASE checks it
// against a Vault secret; a wrong key changes nothing. Bad addresses and spam complaints are never emailed again.
const emailEvents = wf('Zella - Email Events', [
  node('Resend event', 'n8n-nodes-base.webhook', 2, [0, 200], {
    httpMethod: 'POST', path: 'zella/resend', authentication: 'none', responseMode: 'responseNode', options: {},
  }, { webhookId: id('webhook:zella-resend') }),
  code('Plan', [240, 200], 'email-event-plan.js'),
  ifBool('Has event', [480, 200], '={{ !!$json.record }}'),
  rpcNode('Record event', [720, 100], 'zella_record_email_event', '={{ JSON.stringify($json.record) }}', { full: true }),
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

writeFileSync(join(out, 'zella-event-gateway.json'), JSON.stringify(gateway, null, 2) + '\n');
writeFileSync(join(out, 'zella-event-router.json'), JSON.stringify(router, null, 2) + '\n');
writeFileSync(join(out, 'zella-sms-sender.json'), JSON.stringify(smsSender, null, 2) + '\n');
writeFileSync(join(out, 'zella-email-sender.json'), JSON.stringify(emailSender, null, 2) + '\n');
writeFileSync(join(out, 'zella-owner-emails.json'), JSON.stringify(ownerEmails, null, 2) + '\n');
writeFileSync(join(out, 'zella-followup-emails.json'), JSON.stringify(followupEmails, null, 2) + '\n');
writeFileSync(join(out, 'zella-followup-texts.json'), JSON.stringify(followupSender, null, 2) + '\n');
writeFileSync(join(out, 'zella-outbound-calls.json'), JSON.stringify(outboundCalls, null, 2) + '\n');
writeFileSync(join(out, 'zella-knowledge.json'), JSON.stringify(knowledge, null, 2) + '\n');
writeFileSync(join(out, 'zella-assistant-tools.json'), JSON.stringify(assistantTools, null, 2) + '\n');
writeFileSync(join(out, 'zella-appointment-booking.json'), JSON.stringify(aiBooking, null, 2) + '\n');
writeFileSync(join(out, 'zella-email-events.json'), JSON.stringify(emailEvents, null, 2) + '\n');
writeFileSync(join(out, 'zella-call-results.json'), JSON.stringify(callResults, null, 2) + '\n');
console.log('Built', [gateway, router, smsSender, followupSender, emailSender, followupEmails, ownerEmails, outboundCalls, callResults, knowledge, assistantTools, aiBooking, emailEvents].map((w) => w.name + ' (' + w.nodes.length + ')').join(', '));
