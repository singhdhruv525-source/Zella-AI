// Zella - Follow-up Texts: turn Telnyx's answer into the message update and the task result.
// Telnyx's response text is never stored, only its status and its error code.
const prev = $('After log').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const externalId = b.data && b.data.id ? String(b.data.id) : null;
const ok = status >= 200 && status < 300 && !!externalId;
const code = Array.isArray(b.errors) && b.errors[0] && b.errors[0].code ? ' (code ' + String(b.errors[0].code).slice(0, 20) + ')' : '';
const limited = status === 429;
const error = ok ? null : limited ? 'Rate limited (429); trying again later.' : isNaN(status) ? 'No answer from the provider (timed out); trying again later.' : 'Telnyx returned ' + status + code + '.';

return {
  json: {
    task_id: prev.task_id,
    update: { p_id: prev.message_id, p_status: ok ? 'sent' : 'failed', p_external_id: externalId, p_error: error },
    finish: { rpc: 'zella_complete_followup_task', body: { p_task_id: prev.task_id, p_outcome: ok ? 'sms_sent' : 'failed', p_notes: error, p_retry_in_minutes: status === 429 ? 30 : 15 } },
  },
};
