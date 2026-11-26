// Zella Voice - Follow-up Emails: read the answer from "prepare" and decide what happens to this task.
const plan = $('Plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const skip = (reason) => ({ json: { task_id: plan.task_id, finish: { rpc: 'zella_skip_followup_task', body: { p_task_id: plan.task_id, p_reason: reason } } } });
const fail = (reason) => ({ json: { task_id: plan.task_id, finish: { rpc: 'zella_complete_followup_task', body: { p_task_id: plan.task_id, p_outcome: 'failed', p_notes: reason, p_retry_in_minutes: 15 } } } });

if (!(status >= 200 && status < 300)) return fail('The database call zella_prepare_email returned ' + status + '.');
if (b.allowed !== true) return skip(String(b.reason || 'not_allowed').slice(0, 60));
if (b.live === true && !b.from) return fail('sender_address_not_set');
// Who sends (sql/zella_business_email_send.sql): the business's verified domain or the fallback, both through Resend,
// or its connected mailbox through Gmail or Microsoft Graph. Anything else is Resend.
const transport = b.transport === 'gmail' || b.transport === 'outlook' ? b.transport : 'resend';
const route = typeof b.sender_route === 'string' && /^[a-z_]{1,20}$/.test(b.sender_route) ? b.sender_route : 'fallback';

return {
  json: {
    task_id: plan.task_id,
    live: b.live === true,
    transport,
    from: b.from || null,
    from_name: b.from_name || '',
    reply_to: b.reply_to || null,
    unsubscribe_url: typeof b.unsubscribe_url === 'string' && /^https:\/\/[^\s]+$/.test(b.unsubscribe_url) ? b.unsubscribe_url : null,
    to: b.to,
    subject: b.subject,
    text: b.body_text,
    html: b.body_html,
    finish: null,
    log: {
      p_business_id: plan.business_id,
      p_customer_id: plan.customer_id,
      p_to: b.to,
      p_from: b.from || '',
      p_subject: b.subject,
      p_body_text: b.body_text,
      p_body_html: b.body_html,
      p_dedupe_key: 'task:' + plan.task_id,
      p_status: b.live === true ? 'queued' : 'dry_run',
      p_meta: { task_id: plan.task_id, template_id: b.template_id, template_version: b.template_version, dry_run: b.live !== true, transport, sender_route: route },
    },
  },
};
