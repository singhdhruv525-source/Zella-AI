// Zella - Owner Emails: after the email is logged, decide whether to really send.
// A repeat of the same notification and address is never sent twice. In dry-run nothing is sent.
const d = $('Plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const done = (result, note) => ({ json: { notification_id: d.notification_id, finish: { rpc: 'zella_finish_owner_email', body: { p_id: d.notification_id, p_result: result, p_note: note } } } });

if (!(status >= 200 && status < 300)) return done('failed', 'The database call zella_log_outbound_email returned ' + status + '.');
if (b.duplicate === true) {
  if (b.status === 'sent' || b.status === 'delivered') return done('sent', null);
  return done('skipped', 'duplicate_suppressed');
}
if (d.live !== true) return done('skipped', 'dry_run: no email was sent');

const name = String(d.from_name || '').replace(/[\r\n"<>]+/g, ' ').trim();
const resend = { from: name ? name + ' <' + d.from + '>' : d.from, to: [d.to], subject: d.subject, text: d.text, html: d.html };
return { json: { notification_id: d.notification_id, message_id: b.id, finish: null, resend } };
