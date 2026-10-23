// Zella - Follow-up Texts: turn one claimed follow-up task into a "prepare this text" request.
// Reactivation is marketing, so it needs the person's opt-in. The others follow up on something
// the person asked for. Anything unknown is skipped with a visible reason, never dropped silently.
const t = $json;
const skip = (reason) => ({ json: { task_id: t.task_id, finish: { rpc: 'zella_skip_followup_task', body: { p_task_id: t.task_id, p_reason: reason } } } });

const kinds = {
  no_show_follow_up: { key: 'no_show_follow_up', purpose: 'transactional' },
  post_appointment_follow_up: { key: 'post_appointment_follow_up', purpose: 'transactional' },
  quote_follow_up: { key: 'quote_follow_up', purpose: 'transactional' },
  lead_reactivation: { key: 'lead_reactivation', purpose: 'marketing' },
};
const k = kinds[t.kind];
if (t.channel !== 'sms') return skip('channel_not_supported_yet:' + t.channel);
if (!k) return skip('unknown_followup_kind:' + t.kind);

return {
  json: {
    task_id: t.task_id,
    business_id: t.business.id,
    customer_id: t.customer.id,
    template_key: k.key,
    prepare: { p_business_id: t.business.id, p_customer_id: t.customer.id, p_template_key: k.key, p_vars: {}, p_purpose: k.purpose },
    finish: null,
  },
};
