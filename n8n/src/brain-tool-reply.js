// Zella - Receptionist Brain: the answer for ONE tool call, matched by its own toolCallId. Short, no database details.
// Vapi's format (ToolCallResult): { name, toolCallId, result } on success or { name, toolCallId, error } on failure,
// each a single-line string.
// The transfer number is never given to the model: the system picks it when Vapi asks (transfer-destination-request).
// A caller the backend screened out gets the screening instruction instead of anything else.
const plan = $('Use business').item.json;
const r = $json;
const status = Number(r.statusCode);
const b = r.body && typeof r.body === 'object' && !Array.isArray(r.body) ? r.body : null;
const line = (s, n) => String(s).replace(/[\r\n]+/g, ' ').slice(0, n);
if (!(status >= 200 && status < 300) || !b || typeof b.say !== 'string') {
  return { json: { name: String(plan.tool || '').slice(0, 80), toolCallId: plan.tool_call_id, error: 'This could not be completed right now. Tell the caller the team will call them back. Do not say it was done.' } };
}
const caller = b.caller && typeof b.caller === 'object' ? b.caller : {};
const scr = caller.screening && typeof caller.screening === 'object' ? caller.screening : {};
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
  if (Array.isArray(b.slots)) out.times = b.slots.slice(0, 5).map((s) => ({ say: s.say, start: s.start }));
  if (Array.isArray(b.appointments)) out.appointments = b.appointments.slice(0, 3).map((a) => ({ appointment_id: a.appointment_id, title: a.title, say: a.say }));
  if (Array.isArray(b.results)) out.results = b.results.slice(0, 3).map((x) => ({ title: x.title, answer: x.answer }));
  if (typeof b.first_name === 'string') out.first_name = b.first_name.slice(0, 80);
}
return { json: { name: String(plan.tool || '').slice(0, 80), toolCallId: plan.tool_call_id, result: JSON.stringify(out) } };
