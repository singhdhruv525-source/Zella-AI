// Zella - Owner Emails: turn one claimed owner notification (one person) into a logged email.
// The database already checked who should get it and wrote the subject and body.
const r = $json;
const finish = (result, note) => ({ json: { notification_id: r.notification_id, finish: { rpc: 'zella_finish_owner_email', body: { p_id: r.notification_id, p_result: result, p_note: note } } } });

if (!r.notification_id || !r.business_id || !r.to || !r.subject || !r.body_text) return finish('failed', 'incomplete_notification');
if (r.live === true && !r.from) return finish('failed', 'sender_address_not_set');

return {
  json: {
    notification_id: r.notification_id,
    live: r.live === true,
    from: r.from || null,
    from_name: r.from_name || 'Zella',
    to: r.to,
    subject: r.subject,
    text: r.body_text,
    html: r.body_html,
    finish: null,
    log: {
      p_business_id: r.business_id,
      p_customer_id: null,
      p_to: r.to,
      p_from: r.from || '',
      p_subject: r.subject,
      p_body_text: r.body_text,
      p_body_html: r.body_html,
      p_dedupe_key: 'notif:' + r.notification_id + ':' + r.to,
      p_status: r.live === true ? 'queued' : 'dry_run',
      p_meta: { notification_id: r.notification_id, kind: r.kind || null, to_owner: true, dry_run: r.live !== true },
    },
  },
};
