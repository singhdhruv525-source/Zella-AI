// Zella - Appointment Booking: Vapi calls this DURING a call with the tools check_availability and book_appointment.
// Output: { reply, record }. record = the one database call that decides everything (zella_ai_booking), or null.
// Only known fields are passed on; the caller's words are data and are never run as instructions.
const body = $json.body && typeof $json.body === 'object' ? $json.body : {};
const m = body.message && typeof body.message === 'object' ? body.message : {};
const list = Array.isArray(m.toolCallList) ? m.toolCallList : Array.isArray(m.toolCalls) ? m.toolCalls : [];
const actions = { check_availability: 'availability', book_appointment: 'book' };
const nameOf = (t) => (t && (t.name || (t.function && t.function.name))) || '';
const tc = list.find((t) => t && typeof t.id === 'string' && actions[nameOf(t)]);
if (m.type !== 'tool-calls' || !tc) return { json: { reply: { results: [] }, record: null } };

let args = tc.arguments !== undefined ? tc.arguments : tc.function && tc.function.arguments;
if (typeof args === 'string') { try { args = JSON.parse(args); } catch (e) { args = {}; } }
args = args && typeof args === 'object' ? args : {};

const allowed = ['date', 'days', 'duration_minutes', 'start', 'first_name', 'last_name', 'phone', 'email', 'title', 'notes'];
const clean = {};
for (const k of allowed) {
  const v = args[k];
  if (typeof v === 'string') clean[k] = v.replace(/\s+/g, ' ').trim().slice(0, 500);
  else if (typeof v === 'number' && isFinite(v)) clean[k] = v;
}

const call = m.call && typeof m.call === 'object' ? m.call : {};
const meta = call.metadata && typeof call.metadata === 'object' ? call.metadata : {};
const vars = call.assistantOverrides && call.assistantOverrides.variableValues && typeof call.assistantOverrides.variableValues === 'object' ? call.assistantOverrides.variableValues : {};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const bid = [meta.business_id, vars.business_id].find((v) => typeof v === 'string' && uuid.test(v)) || null;

return {
  json: {
    tool_call_id: tc.id,
    reply: null,
    record: { p_provider_call_id: typeof call.id === 'string' ? call.id.slice(0, 200) : null, p_business_id: bid, p_action: actions[nameOf(tc)], p_args: clean },
  },
};
