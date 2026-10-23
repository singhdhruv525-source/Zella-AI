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
  // Replies to a customer's own text (C, R, HELP). The database queues these when the text arrives.
  reply_confirmed: { key: 'reply_confirmed', purpose: 'transactional' },
  reply_reschedule: { key: 'reply_reschedule', purpose: 'transactional' },
  reply_help: { key: 'reply_help', purpose: 'transactional' },
  // A time freed by a cancellation, offered to the next person on the waitlist (with a private Book this time button).
  waitlist_offer: { key: 'waitlist_offer', purpose: 'transactional' },
};
// A callback that ran out of tries leaves a text task behind. The message depends on why the callback existed.
const byReason = { missed_call: 'missed_call_follow_up', new_lead: 'lead_acknowledgement' };
let k = kinds[t.kind];
if (t.kind === 'callback_sms') {
  const key = byReason[t.callback_reason];
  if (!key) return skip('unknown_callback_reason:' + String(t.callback_reason).slice(0, 30));
  k = { key, purpose: 'transactional' };
}
if (t.channel !== 'sms') return skip('channel_not_supported_yet:' + t.channel);
if (!k) return skip('unknown_followup_kind:' + t.kind);

// Only the waitlist offer has details to fill in: the offered time and the private link.
let vars = {};
if (t.kind === 'waitlist_offer') {
  const tz = (t.business && t.business.timezone) || 'America/New_York';
  const start = new Date(t.offer && t.offer.start);
  if (isNaN(start.getTime())) return skip('offer_has_no_time');
  vars = {
    date: start.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: tz }),
    time: start.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: tz }),
    offer_line: typeof t.offer.line === 'string' ? t.offer.line : '',
  };
}

return {
  json: {
    task_id: t.task_id,
    business_id: t.business.id,
    customer_id: t.customer.id,
    template_key: k.key,
    prepare: { p_business_id: t.business.id, p_customer_id: t.customer.id, p_template_key: k.key, p_vars: vars, p_purpose: k.purpose },
    finish: null,
  },
};
