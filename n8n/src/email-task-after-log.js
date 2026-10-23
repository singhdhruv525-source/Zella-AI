// Zella - Follow-up Emails: after the message is logged, decide whether to really send.
// A repeat of the same task is never sent twice. In dry-run nothing is sent.
const d = $('Decide').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const done = (rpc, body) => ({ json: { task_id: d.task_id, finish: { rpc, body } } });
const complete = (outcome, notes) => done('zella_complete_followup_task', { p_task_id: d.task_id, p_outcome: outcome, p_notes: notes, p_retry_in_minutes: 15 });

if (!(status >= 200 && status < 300)) return complete('failed', 'The database call zella_log_outbound_email returned ' + status + '.');
if (b.duplicate === true) {
  if (b.status === 'sent' || b.status === 'delivered') return complete('email_sent', null);
  return done('zella_skip_followup_task', { p_task_id: d.task_id, p_reason: 'duplicate_suppressed' });
}
if (d.live !== true) return done('zella_skip_followup_task', { p_task_id: d.task_id, p_reason: 'dry_run: no email was sent' });

const name = String(d.from_name || '').replace(/[\r\n"<>]+/g, ' ').trim();
const resend = { from: name ? name + ' <' + d.from + '>' : d.from, to: [d.to], subject: d.subject, text: d.text, html: d.html };
return { json: { task_id: d.task_id, message_id: b.id, finish: null, resend } };
