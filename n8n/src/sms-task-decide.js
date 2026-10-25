// Zella - Follow-up Texts: read the answer from "prepare" and decide what happens to this task.
const plan = $('Plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const skip = (reason) => ({ json: { task_id: plan.task_id, finish: { rpc: 'zella_skip_followup_task', body: { p_task_id: plan.task_id, p_reason: reason } } } });
const fail = (reason) => ({ json: { task_id: plan.task_id, finish: { rpc: 'zella_complete_followup_task', body: { p_task_id: plan.task_id, p_outcome: 'failed', p_notes: reason, p_retry_in_minutes: 15 } } } });

if (!(status >= 200 && status < 300)) return fail('The database call zella_prepare_sms returned ' + status + '.');
if (b.allowed !== true) return skip(String(b.reason || 'not_allowed').slice(0, 60));
if (b.live === true && !b.from) return fail('sender_number_not_set');

return {
  json: {
    task_id: plan.task_id,
    live: b.live === true,
    from: b.from || null,
    to: b.to,
    text: b.body,
    finish: null,
    log: {
      p_business_id: plan.business_id,
      p_customer_id: plan.customer_id,
      p_to: b.to,
      p_from: b.from || '',
      p_body: b.body,
      p_dedupe_key: 'task:' + plan.task_id,
      p_status: b.live === true ? 'queued' : 'dry_run',
      p_meta: { task_id: plan.task_id, template_id: b.template_id, template_version: b.template_version, dry_run: b.live !== true },
    },
  },
};
