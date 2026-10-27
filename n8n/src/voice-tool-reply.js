// Zella - Voice Rules: the answer for ONE tool call, under its own toolCallId. Short, no database details.
// A caller the backend screened out gets the screening instruction (end politely, use no tools) in place of
// everything else; other callers get the caller note added. The transfer number is never given to the model.
// The same reply is built by the voice-rules edge function (web/supabase/functions/voice-rules/logic.ts).
const plan = $('Use business').item.json;
const r = $json;
const status = Number(r.statusCode);
const b = r.body && typeof r.body === 'object' && !Array.isArray(r.body) ? r.body : null;
const line = (s, n) => String(s).replace(/[\r\n]+/g, ' ').slice(0, n);
if (!plan.valid) return { json: { toolCallId: plan.tool_call_id, error: 'Use the tool call_rules with action rules, message, emergency or transfer.' } };
if (!(status >= 200 && status < 300) || !b || typeof b.say !== 'string') {
  return { json: { toolCallId: plan.tool_call_id, error: 'This could not be done right now. Tell the caller the team will call them back. Do not promise anything else.' } };
}
const caller = b.caller && typeof b.caller === 'object' ? b.caller : {};
const scr = caller.screening && typeof caller.screening === 'object' ? caller.screening : {};
const decision = typeof scr.decision === 'string' ? scr.decision : null;
let out;
if (b.status === 'screened' || (['blocked', 'restricted', 'screened'].includes(decision) && typeof caller.say === 'string')) {
  out = { status: 'screened', instruction: line(b.status === 'screened' ? b.say : caller.say, 600), can_transfer: false };
  if (Array.isArray(b.emergency_keywords)) out.emergency_words = b.emergency_keywords.slice(0, 20);
} else {
  out = { status: b.status, instruction: line(b.say + (typeof caller.say === 'string' && caller.say ? ' About this caller: ' + caller.say : ''), 900) };
  if (typeof b.open === 'boolean') out.open = b.open;
  if (typeof b.can_transfer === 'boolean') out.can_transfer = b.can_transfer;
  // the number is never given to the model; the system chooses it when Vapi sends transfer-destination-request
  if (b.status === 'transfer') out.use_transfer_tool = true;
  if (Array.isArray(b.emergency_keywords)) out.emergency_words = b.emergency_keywords.slice(0, 20);
  if (decision === 'flagged') out.caution = true;
}
return { json: { toolCallId: plan.tool_call_id, result: JSON.stringify(out) } };
