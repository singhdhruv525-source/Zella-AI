// Zella - Outbound Calls: turn one claimed call (a callback, or a follow-up task) into either a Vapi request
// or a database note. Nothing is dialled unless calls_live is true and Vapi is set up (c.live).
// Output: { source, id, call, record }. call = what to send to Vapi (or null); record = the database call to make.
const c = $json;
const source = c.source === 'callback' ? 'callback' : 'task';
const id = c.id;
const record = (rpc, body) => ({ json: { source, id, call: null, record: { rpc, body } } });

const raw = String((source === 'callback' ? c.contact_number : c.customer && c.customer.phone) || '');
const digits = raw.replace(/\D/g, '');
let to = null;
if (raw.trim().startsWith('+') && digits.length >= 8 && digits.length <= 15) to = '+' + digits;
else if (digits.length === 10) to = '+1' + digits;
else if (digits.length === 11 && digits[0] === '1') to = '+' + digits;

if (!to) {
  return source === 'callback'
    ? record('zella_record_callback_attempt', { p_callback_id: id, p_outcome: 'invalid_number', p_notes: 'no_valid_phone' })
    : record('zella_complete_followup_task', { p_task_id: id, p_outcome: 'failed', p_notes: 'no_valid_phone' });
}
if (!c.live) return record('zella_release_call', { p_source: source, p_id: id, p_reason: 'dry_run', p_defer_minutes: 720 });

const tz = (c.business && c.business.timezone) || 'America/New_York';
const appt = c.appointment && c.appointment.start_time ? new Date(c.appointment.start_time) : null;
const when = appt && !isNaN(appt.getTime())
  ? appt.toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', timeZone: tz }) + ' at ' + appt.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: tz })
  : '';
const first = String((c.customer && c.customer.first_name) || '').trim();
const last = String((c.customer && c.customer.last_name) || '').trim();

return {
  json: {
    source, id, record: null,
    call: {
      assistantId: c.assistant_id,
      phoneNumberId: c.phone_number_id,
      customer: { number: to, name: (first + ' ' + last).trim() || undefined },
      assistantOverrides: {
        variableValues: {
          business_name: (c.business && c.business.name) || '',
          first_name: first,
          call_reason: String(c.kind || c.reason || ''),
          appointment_title: String((c.appointment && c.appointment.title) || ''),
          appointment_time: when,
        },
      },
      metadata: { zella_source: source, zella_id: id, business_id: c.business && c.business.id },
    },
  },
};
