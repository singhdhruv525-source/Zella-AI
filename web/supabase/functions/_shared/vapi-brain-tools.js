// @ts-self-types="./vapi-brain-tools.d.ts"
// Receptionist Brain tools: one Vapi tool call -> one call to the audited gateway zella_ai_tool, and its answer back.
// ONE implementation, used by the voice-rules edge function (import) and by n8n Brain Tools (inlined at build time by
// n8n/src/load.mjs, `export` removed). No network, no secrets. Every decision (business, confirmation, spam screening,
// availability, locks, idempotency, verification, audit) is made by zella_ai_tool in the database; this only checks
// the shape of the arguments, keeps known fields, and takes the caller's number from the phone network.

// The tools the database defines (zella_brain_tool_defs). Anything else is answered "not something you can do".
const TOOLS = ['search_knowledge', 'check_open_hours', 'lookup_caller', 'update_caller', 'check_availability', 'book_appointment', 'find_my_appointments',
  'reschedule_appointment', 'cancel_appointment', 'take_message', 'report_emergency', 'transfer_to_human', 'request_follow_up', 'report_unanswered_question'];
export const BRAIN_TOOLS = TOOLS;
export const BOOKING_TOOLS = ['check_availability', 'book_appointment', 'find_my_appointments', 'reschedule_appointment', 'cancel_appointment'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STRINGS = ['query', 'appointment_id', 'date', 'start', 'first_name', 'last_name', 'phone', 'email', 'title', 'notes', 'name', 'message',
  'preferred_contact_method', 'reason', 'when', 'summary', 'question'];
const NUMBERS = ['days', 'duration_minutes'];
const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const o = (v) => (isObj(v) ? v : {});

// Who is calling, which line, which call: from Vapi's call object only (never from what is said).
export function vapiCallContext(message) {
  const m = o(message);
  const call = o(m.call);
  const meta = o(call.metadata);
  const vars = o(o(call.assistantOverrides).variableValues);
  const pn = isObj(call.phoneNumber) ? call.phoneNumber : o(m.phoneNumber);
  const cn = String(o(call.customer).number || '');
  const bid = [meta.business_id, vars.business_id].find((v) => typeof v === 'string' && UUID.test(v)) || null;
  return {
    callId: typeof call.id === 'string' && call.id ? call.id.slice(0, 200) : null,
    calledNumber: typeof pn.number === 'string' && /^\+?[0-9() .-]{7,20}$/.test(pn.number) ? pn.number : null,
    vapiNumberId: typeof call.phoneNumberId === 'string' ? call.phoneNumberId.slice(0, 100) : typeof pn.id === 'string' ? pn.id.slice(0, 100) : null,
    callerNumber: /^\+?[0-9]{7,15}$/.test(cn) ? cn : null,
    // only a fallback: a registered number always wins (zella_business_for_number), and zella_ai_tool prefers the call's own business
    fallbackBusinessId: bid,
  };
}

export const toolName = (tc) => String((tc && (tc.name || (tc.function && tc.function.name))) || '').slice(0, 80);

export function toolArgs(tc) {
  let args = tc && tc.arguments !== undefined ? tc.arguments : tc && tc.function && tc.function.arguments;
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch (_e) { args = {}; } }
  return o(args);
}

// Shape checks. A value that is present but malformed is refused with a clear instruction instead of being guessed at;
// the database still checks meaning (availability, ownership, email format, need for a name).
function invalidField(clean) {
  if (clean.date !== undefined && (!/^\d{4}-\d{2}-\d{2}$/.test(clean.date) || Number.isNaN(Date.parse(clean.date + 'T00:00:00Z')))) return 'date must be YYYY-MM-DD';
  if (clean.start !== undefined && (Number.isNaN(Date.parse(clean.start)) || !/[T ]\d{2}:\d{2}/.test(clean.start))) return 'start must be a time exactly as returned by check_availability';
  if (clean.appointment_id !== undefined && !UUID.test(clean.appointment_id)) return 'appointment_id must come from find_my_appointments';
  if (clean.days !== undefined && !(Number.isInteger(clean.days) && clean.days >= 1 && clean.days <= 14)) return 'days must be a whole number from 1 to 14';
  if (clean.duration_minutes !== undefined && !(Number.isInteger(clean.duration_minutes) && clean.duration_minutes >= 5 && clean.duration_minutes <= 480)) return 'duration_minutes must be a whole number from 5 to 480';
  if (clean.preferred_contact_method !== undefined && !['call', 'sms', 'email'].includes(clean.preferred_contact_method)) return 'preferred_contact_method must be call, sms or email';
  if (clean.email !== undefined && clean.email.length > 200) return 'email is too long';
  return null;
}

// One tool call -> { toolCallId, name, invalid, record }. record = the zella_ai_tool arguments (p_business_id filled in
// by the caller of this function from the number lookup). An unknown tool or bad arguments still gets a record with
// p_tool 'unknown', so a workflow that can only send everything to the database stays on one path; the database then
// refuses without acting. The edge function does not send those at all.
export function planBrainTool(tc, ctx, allowed = TOOLS) {
  const name = toolName(tc);
  const args = toolArgs(tc);
  const clean = {};
  for (const k of STRINGS) if (typeof args[k] === 'string') clean[k] = args[k].replace(/\s+/g, ' ').trim().slice(0, k === 'query' ? 300 : 1500);
  for (const k of NUMBERS) if (typeof args[k] === 'number' && Number.isFinite(args[k])) clean[k] = args[k];
  // the caller's yes must be a real boolean from the assistant; anything else counts as "not confirmed"
  clean.confirmed = args.confirmed === true;
  const known = TOOLS.includes(name) && allowed.includes(name);
  const invalid = known ? invalidField(clean) : null;
  return {
    toolCallId: tc.id, name, known, invalid,
    record: { p_provider_call_id: ctx.callId, p_business_id: ctx.fallbackBusinessId, p_tool: known && !invalid ? name : 'unknown',
              p_args: { ...clean, caller_number: ctx.callerNumber },
              // the tool call id makes a repeated delivery of the same call a no-op (and waits for one still running)
              p_idempotency_key: ctx.callId ? (ctx.callId + ':' + tc.id).slice(0, 300) : null },
  };
}

// The tool calls of one request: those with a usable id, each id once, at most 10.
export function toolCallList(message) {
  const m = o(message);
  const list = Array.isArray(m.toolCallList) ? m.toolCallList : Array.isArray(m.toolCalls) ? m.toolCalls : [];
  const out = [];
  const seen = new Set();
  for (const tc of list.slice(0, 10)) {
    if (!isObj(tc) || typeof tc.id !== 'string' || !tc.id || tc.id.length > 200 || seen.has(tc.id)) continue;
    seen.add(tc.id);
    out.push(tc);
  }
  return out;
}

export const BRAIN_FAILED = 'This could not be completed right now. Tell the caller the team will call them back. Do not say it was done.';
export const BRAIN_UNKNOWN = 'That is not something you can do. Offer to take a message instead.';
const line = (s, n) => String(s).replace(/[\r\n]+/g, ' ').slice(0, n);

// The answer for ONE tool call, in Vapi's ToolCallResult format: { name, toolCallId, result } or { name, toolCallId, error },
// single-line strings. Short, no database details. The transfer number is never given to the model (the system picks it
// on transfer-destination-request). A caller the backend screened out gets the screening instruction instead.
export function brainToolReply(name, toolCallId, ok, body) {
  const b = isObj(body) ? body : null;
  if (!ok || !b || typeof b.say !== 'string') return { name, toolCallId, error: BRAIN_FAILED };
  const caller = o(b.caller);
  const scr = o(caller.screening);
  let out;
  if (b.status === 'screened' || (['blocked', 'restricted', 'screened'].includes(scr.decision) && typeof caller.say === 'string')) {
    out = { status: 'screened', instruction: line(b.status === 'screened' ? b.say : caller.say, 600), can_transfer: false };
  } else {
    out = { status: b.status, instruction: line(b.say + (typeof caller.say === 'string' && caller.say ? ' About this caller: ' + caller.say : ''), 900) };
    if (typeof b.open === 'boolean') out.open = b.open;
    if (typeof b.can_transfer === 'boolean') out.can_transfer = b.can_transfer;
    if (b.status === 'transfer') out.use_transfer_tool = true;
    if (scr.decision === 'flagged') out.caution = true;
    if (Array.isArray(b.emergency_keywords)) out.emergency_words = b.emergency_keywords.slice(0, 20);
    if (Array.isArray(b.slots)) out.times = b.slots.slice(0, 5).map((s) => ({ say: o(s).say, start: o(s).start }));
    if (Array.isArray(b.appointments)) out.appointments = b.appointments.slice(0, 3).map((a) => ({ appointment_id: o(a).appointment_id, title: o(a).title, say: o(a).say }));
    if (Array.isArray(b.results)) out.results = b.results.slice(0, 3).map((x) => ({ title: o(x).title, answer: o(x).answer }));
    if (typeof b.first_name === 'string') out.first_name = b.first_name.slice(0, 80);
  }
  return { name, toolCallId, result: JSON.stringify(out) };
}

// An argument problem found before the database was asked: the model is told what to fix.
export const brainInvalidReply = (name, toolCallId, why) => ({ name, toolCallId, error: 'Invalid arguments: ' + why + '. Nothing was done.' });
