// Zella Voice - Email Sender: turn the provider's answer into the message update and the reminder result.
// The provider's response text is never stored, only its status and a short error name. A mailbox that refused for its
// daily limit or its sign in goes to zella_business_email_mailbox_refused: the reminder is due again at once, without
// using up a try, and goes out through the fallback (sql/zella_business_email.sql).
__MAILBOX_RESULT__
const prev = $('After log').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
let ok, externalId, error, refused = null;
if (prev.transport === 'gmail' || prev.transport === 'outlook') {
  const r = mailboxResult(prev.transport, status, $json.body, $json.mailbox_fail, prev.message_id);
  ok = r.ok; externalId = r.external_id; error = r.error; refused = r.refused;
} else {
  externalId = b.id ? String(b.id) : null;
  ok = status >= 200 && status < 300 && !!externalId;
  const name = typeof b.name === 'string' && /^[a-z_]{1,40}$/.test(b.name) ? ' (' + b.name + ')' : '';
  error = ok ? null : 'The email provider returned ' + status + name + '.';
}

return {
  json: {
    reminder_id: prev.reminder_id,
    update: { p_id: prev.message_id, p_status: ok ? 'sent' : 'failed', p_external_id: externalId, p_error: error },
    finish: refused ? { rpc: 'zella_business_email_mailbox_refused', body: { p_message_id: prev.message_id, p_reason: refused } }
      : { rpc: 'zella_complete_reminder', body: ok ? { p_reminder_id: prev.reminder_id, p_ok: true } : { p_reminder_id: prev.reminder_id, p_ok: false, p_error: error } },
  },
};
