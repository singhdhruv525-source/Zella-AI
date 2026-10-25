// Zella - Appointment Booking: the answer sent back to Vapi. Short, no database details.
const plan = $('Plan').item.json;
if (!plan.record) return { json: plan.reply };
const r = $json;
const status = Number(r.statusCode);
const b = r.body && typeof r.body === 'object' ? r.body : null;
let result;
if (status >= 200 && status < 300 && b && typeof b.say === 'string') {
  const out = { status: b.status, instruction: b.say };
  if (Array.isArray(b.slots)) out.times = b.slots.slice(0, 5).map((s) => ({ say: s.say, start: s.start }));
  if (Array.isArray(b.appointments)) out.appointments = b.appointments.slice(0, 3).map((a) => ({ appointment_id: a.appointment_id, title: a.title, say: a.say }));
  result = JSON.stringify(out);
} else {
  result = JSON.stringify({ status: 'error', instruction: 'This could not be completed right now. Tell the caller the team will call them back to finish the booking. Do not say it is booked.' });
}
return { json: { results: [{ toolCallId: plan.tool_call_id, result }] } };
