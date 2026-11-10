// Zella - Email Sender: after the email is logged, decide whether to really send.
// A repeat of the same reminder is never sent twice. In dry-run nothing is sent.
const d = $('Decide').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const done = (rpc, body) => ({ json: { reminder_id: d.reminder_id, finish: { rpc, body } } });

if (!(status >= 200 && status < 300)) {
  return done('zella_complete_reminder', { p_reminder_id: d.reminder_id, p_ok: false, p_error: 'The database call zella_log_outbound_email returned ' + status + '.' });
}
if (b.duplicate === true) {
  if (b.status === 'sent' || b.status === 'delivered') return done('zella_complete_reminder', { p_reminder_id: d.reminder_id, p_ok: true });
  return done('zella_skip_reminder', { p_reminder_id: d.reminder_id, p_reason: 'duplicate_suppressed' });
}
if (d.live !== true) return done('zella_skip_reminder', { p_reminder_id: d.reminder_id, p_reason: 'dry_run: no email was sent' });

const name = String(d.from_name || '').replace(/[\r\n"<>]+/g, ' ').trim();
const resend = { from: name ? name + ' <' + d.from + '>' : d.from, to: [d.to], subject: d.subject, text: d.text, html: d.html };
if (d.reply_to) resend.reply_to = d.reply_to;
return { json: { reminder_id: d.reminder_id, message_id: b.id, finish: null, resend } };
