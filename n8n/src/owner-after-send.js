// Zella - Owner Emails: turn the provider's answer into the message update and the notification result.
// The provider's response text is never stored, only its status and a short error name.
const prev = $('After log').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const externalId = b.id ? String(b.id) : null;
const ok = status >= 200 && status < 300 && !!externalId;
const name = typeof b.name === 'string' && /^[a-z_]{1,40}$/.test(b.name) ? ' (' + b.name + ')' : '';
const error = ok ? null : 'The email provider returned ' + status + name + '.';

return {
  json: {
    notification_id: prev.notification_id,
    update: { p_id: prev.message_id, p_status: ok ? 'sent' : 'failed', p_external_id: externalId, p_error: error },
    finish: { rpc: 'zella_finish_owner_email', body: { p_id: prev.notification_id, p_result: ok ? 'sent' : 'failed', p_note: error } },
  },
};
