// Zella - SMS Sender: read the answer from "prepare" and decide what happens to this reminder.
// Either it goes on to be logged (and maybe sent), or it is finished here: skipped with a reason, or failed.
const plan = $('Plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const finishSkip = (reason) => ({ json: { reminder_id: plan.reminder_id, finish: { rpc: 'zella_skip_reminder', body: { p_reminder_id: plan.reminder_id, p_reason: reason } } } });
const finishFail = (reason) => ({ json: { reminder_id: plan.reminder_id, finish: { rpc: 'zella_complete_reminder', body: { p_reminder_id: plan.reminder_id, p_ok: false, p_error: reason } } } });

if (!(status >= 200 && status < 300)) return finishFail('The database call zella_prepare_sms returned ' + status + '.');
if (b.allowed !== true) return finishSkip(String(b.reason || 'not_allowed').slice(0, 60));
if (b.live === true && !b.from) return finishFail('sender_number_not_set');

return {
  json: {
    reminder_id: plan.reminder_id,
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
      p_dedupe_key: 'reminder:' + plan.reminder_id,
      p_status: b.live === true ? 'queued' : 'dry_run',
      p_meta: { reminder_id: plan.reminder_id, template_id: b.template_id, template_version: b.template_version, dry_run: b.live !== true },
    },
  },
};
