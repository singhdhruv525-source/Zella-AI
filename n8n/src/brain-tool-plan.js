// Zella - Receptionist Brain: the webhook for every tool the phone assistant (Vapi) uses during a call.
// Runs once for the whole request and returns ONE ITEM PER TOOL CALL, so every tool call Vapi sent gets its own answer
// (Vapi may send several at once). Each item carries its own tool call id and one database call (zella_ai_tool), which
// checks, acts, verifies and logs. A request that isn't a tool call returns one item with an empty reply.
// Only known fields pass; the caller's words are data and are never run as instructions.
const body = (($input.first() || {}).json || {}).body;
const m = body && typeof body === 'object' && body.message && typeof body.message === 'object' ? body.message : {};
const list = Array.isArray(m.toolCallList) ? m.toolCallList : Array.isArray(m.toolCalls) ? m.toolCalls : [];
const nameOf = (t) => (t && (t.name || (t.function && t.function.name))) || '';
if (m.type !== 'tool-calls' || !list.length) return [{ json: { reply: { results: [] }, record: null } }];

const TOOLS = ['search_knowledge', 'check_open_hours', 'lookup_caller', 'update_caller', 'check_availability', 'book_appointment', 'find_my_appointments',
  'reschedule_appointment', 'cancel_appointment', 'take_message', 'report_emergency', 'transfer_to_human', 'request_follow_up', 'report_unanswered_question'];
// The Appointment Booking webhook reuses this file with only the booking tools (build.mjs fills __ONLY_TOOLS__ in);
// any other tool name sent there is answered "not something you can do".
const ONLY = '__ONLY_TOOLS__';
const ALLOWED = ONLY.startsWith('__') ? TOOLS : TOOLS.filter((t) => ONLY.split(',').includes(t));
const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const allowed = ['query', 'appointment_id', 'date', 'days', 'duration_minutes', 'start', 'first_name', 'last_name', 'phone', 'email', 'title', 'notes', 'name', 'message',
  'preferred_contact_method', 'reason', 'when', 'summary', 'question'];

const call = m.call && typeof m.call === 'object' ? m.call : {};
const meta = call.metadata && typeof call.metadata === 'object' ? call.metadata : {};
const vars = call.assistantOverrides && call.assistantOverrides.variableValues && typeof call.assistantOverrides.variableValues === 'object' ? call.assistantOverrides.variableValues : {};
const bid = [meta.business_id, vars.business_id].find((v) => typeof v === 'string' && uuidRe.test(v)) || null;
// Which number was called? A registered number always wins over call settings.
const pn = call.phoneNumber && typeof call.phoneNumber === 'object' ? call.phoneNumber : m.phoneNumber && typeof m.phoneNumber === 'object' ? m.phoneNumber : {};
const calledNumber = typeof pn.number === 'string' && /^\+?[0-9() .-]{7,20}$/.test(pn.number) ? pn.number : null;
const vapiNumberId = typeof call.phoneNumberId === 'string' ? call.phoneNumberId.slice(0, 100) : typeof pn.id === 'string' ? pn.id.slice(0, 100) : null;
const lookup = { p_called_number: calledNumber, p_vapi_phone_number_id: vapiNumberId, p_fallback: bid };
// The caller is known ONLY by the number the phone network reports, never by what is said.
const cn = call.customer && typeof call.customer === 'object' ? String(call.customer.number || '') : '';
const callerNumber = /^\+?[0-9]{7,15}$/.test(cn) ? cn : null;
const callId = typeof call.id === 'string' ? call.id.slice(0, 200) : null;

const out = [];
const seen = new Set();
for (const tc of list.slice(0, 10)) {
  // a tool call without a usable id can't be answered, and a repeated id in the same request is answered once
  if (!tc || typeof tc.id !== 'string' || !tc.id || tc.id.length > 200 || seen.has(tc.id)) continue;
  seen.add(tc.id);
  const name = nameOf(tc);
  let args = tc.arguments !== undefined ? tc.arguments : tc.function && tc.function.arguments;
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch (e) { args = {}; } }
  args = args && typeof args === 'object' && !Array.isArray(args) ? args : {};
  const clean = {};
  for (const k of allowed) {
    const v = args[k];
    if (typeof v === 'string') clean[k] = v.replace(/\s+/g, ' ').trim().slice(0, 1500);
    else if (typeof v === 'number' && isFinite(v)) clean[k] = v;
  }
  // the caller's yes must be a real boolean from the assistant; anything else counts as "not confirmed"
  clean.confirmed = args.confirmed === true;
  if (clean.appointment_id !== undefined && !uuidRe.test(String(clean.appointment_id))) delete clean.appointment_id;
  out.push({
    json: {
      tool_call_id: tc.id,
      tool: name,
      lookup,
      // a tool not on the list still gets an answer: the database replies "not something you can do" without acting
      record: { p_provider_call_id: callId, p_business_id: bid, p_tool: ALLOWED.includes(name) ? name : 'unknown',
                p_args: { ...clean, caller_number: callerNumber },
                // the tool call id makes a repeated delivery of the same call a no-op (and waits for one still running)
                p_idempotency_key: callId ? (callId + ':' + tc.id).slice(0, 300) : null },
    },
  });
}
return out.length ? out : [{ json: { reply: { results: [] }, record: null } }];
