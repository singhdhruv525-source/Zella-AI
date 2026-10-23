// Zella - Email Sender: turn one claimed reminder into a "prepare this email" request.
// Only email reminders are handled here. Anything else is skipped with a visible reason, never dropped silently.
const r = $json;
const skip = (reason) => ({ json: { reminder_id: r.reminder_id, finish: { rpc: 'zella_skip_reminder', body: { p_reminder_id: r.reminder_id, p_reason: reason } } } });

const templates = { reminder: 'appointment_reminder', confirmation_request: 'appointment_reminder', confirmation: 'appointment_confirmation' };
const key = templates[r.kind];
if (r.channel !== 'email') return skip('channel_not_email:' + r.channel);
if (!key) return skip('unknown_reminder_kind:' + r.kind);

const tz = (r.business && r.business.timezone) || 'America/New_York';
const start = new Date(r.appointment && r.appointment.start_time);
if (isNaN(start.getTime())) return skip('invalid_appointment_time');
const date = start.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: tz });
const time = start.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: tz });
const label = (r.appointment.title || 'appointment').toString().trim().slice(0, 80) || 'appointment';

return {
  json: {
    reminder_id: r.reminder_id,
    business_id: r.business.id,
    customer_id: r.customer.id,
    template_key: key,
    prepare: {
      p_business_id: r.business.id,
      p_customer_id: r.customer.id,
      p_template_key: key,
      p_vars: { appointment: label, date, time, reschedule_line: typeof r.reschedule_line === 'string' ? r.reschedule_line : '' },
      p_purpose: 'transactional',
    },
    finish: null,
  },
};
