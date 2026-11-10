// Zella - SMS Sender: turn Telnyx's answer into the message update and the reminder result.
// Telnyx's response text is never stored, only its status and its error code.
const prev = $('After log').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const externalId = b.data && b.data.id ? String(b.data.id) : null;
const ok = status >= 200 && status < 300 && !!externalId;
const code = Array.isArray(b.errors) && b.errors[0] && b.errors[0].code ? ' (code ' + String(b.errors[0].code).slice(0, 20) + ')' : '';
const error = ok ? null : 'Telnyx returned ' + status + code + '.';

return {
  json: {
    reminder_id: prev.reminder_id,
    update: { p_id: prev.message_id, p_status: ok ? 'sent' : 'failed', p_external_id: externalId, p_error: error },
    finish: { rpc: 'zella_complete_reminder', body: ok ? { p_reminder_id: prev.reminder_id, p_ok: true } : { p_reminder_id: prev.reminder_id, p_ok: false, p_error: error } },
  },
};
