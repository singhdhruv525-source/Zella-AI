// Zella - Outbound Calls: what Vapi answered when asked to place the call.
// Accepted -> remember the provider's call id (the result arrives later from Vapi's end-of-call report).
// Refused or unreachable -> count it as a failed attempt so the normal retry rules apply.
const plan = $('Plan').item.json;
const r = $json;
const status = Number(r.statusCode);
const body = r.body && typeof r.body === 'object' ? r.body : {};
const note = ('vapi_' + (isNaN(status) ? 'error' : status)).slice(0, 60);

if (status >= 200 && status < 300 && typeof body.id === 'string' && body.id) {
  return { json: { ...plan, record: { rpc: 'zella_mark_call_placed', body: { p_source: plan.source, p_id: plan.id, p_provider_call_id: body.id } } } };
}
return {
  json: {
    ...plan,
    record: plan.source === 'callback'
      ? { rpc: 'zella_record_callback_attempt', body: { p_callback_id: plan.id, p_outcome: 'failed_connection', p_error: note } }
      : { rpc: 'zella_complete_followup_task', body: { p_task_id: plan.id, p_outcome: 'failed', p_notes: note } },
  },
};
