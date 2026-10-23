// Zella - Follow-up Emails: turn one claimed follow-up task into a "prepare this email" request.
// Reactivation is marketing, so it needs the person's opt-in. The others follow up on something
// the person asked for. Anything unknown is skipped with a visible reason, never dropped silently.
const t = $json;
const skip = (reason) => ({ json: { task_id: t.task_id, finish: { rpc: 'zella_skip_followup_task', body: { p_task_id: t.task_id, p_reason: reason } } } });

const kinds = {
  no_show_follow_up: { key: 'no_show_follow_up', purpose: 'transactional' },
  post_appointment_follow_up: { key: 'post_appointment_follow_up', purpose: 'transactional' },
  quote_follow_up: { key: 'quote_follow_up', purpose: 'transactional' },
  lead_reactivation: { key: 'lead_reactivation', purpose: 'marketing' },
  welcome_new_customer: { key: 'welcome_new_customer', purpose: 'transactional' },
  feedback_request: { key: 'feedback_request', purpose: 'transactional' },
  cancellation_confirmation: { key: 'cancellation_confirmation', purpose: 'transactional' },
  record_status_update: { key: 'record_status_update', purpose: 'transactional' },
  service_due: { key: 'service_due', purpose: 'transactional' },
  no_response_follow_up: { key: 'no_response_follow_up', purpose: 'transactional' },
};
// A callback that ran out of tries leaves a task behind. The message depends on why the callback existed.
const byReason = { missed_call: 'missed_call_follow_up', new_lead: 'lead_acknowledgement' };
let k = kinds[t.kind];
if (t.kind === 'callback_sms') {
  const key = byReason[t.callback_reason];
  if (!key) return skip('unknown_callback_reason:' + String(t.callback_reason).slice(0, 30));
  k = { key, purpose: 'transactional' };
}
if (t.channel !== 'email') return skip('channel_not_email:' + t.channel);
if (!k) return skip('unknown_followup_kind:' + t.kind);

const vars = {};
if (t.vars && typeof t.vars === 'object') {
  for (const [key, val] of Object.entries(t.vars)) if (typeof val === 'string') vars[key] = val.slice(0, 300);
}

return {
  json: {
    task_id: t.task_id,
    business_id: t.business.id,
    customer_id: t.customer.id,
    template_key: k.key,
    prepare: { p_business_id: t.business.id, p_customer_id: t.customer.id, p_template_key: k.key, p_vars: vars, p_purpose: k.purpose },
    finish: null,
  },
};
