// Zella - Voice Rules: the answer sent back to Vapi. Short, no database details.
// A caller the backend screened out gets the screening instruction (end politely, use no tools) in place of
// everything else; other callers get the caller note added. The same reply is built by the voice-rules edge
// function (web/supabase/functions/voice-rules/logic.ts), which is the recommended path: it doesn't wait for n8n.
const plan = $('Plan').item.json;
if (!plan.record) return { json: plan.reply };
const r = $json;
const status = Number(r.statusCode);
const b = r.body && typeof r.body === 'object' ? r.body : null;
let result;
if (status >= 200 && status < 300 && b && typeof b.say === 'string') {
  const caller = b.caller && typeof b.caller === 'object' ? b.caller : {};
  const scr = caller.screening && typeof caller.screening === 'object' ? caller.screening : {};
  const decision = typeof scr.decision === 'string' ? scr.decision : null;
  let out;
  if (b.status === 'screened' || (['blocked', 'restricted', 'screened'].includes(decision) && typeof caller.say === 'string')) {
    out = { status: 'screened', instruction: b.status === 'screened' ? b.say : caller.say, can_transfer: false };
    if (Array.isArray(b.emergency_keywords)) out.emergency_words = b.emergency_keywords.slice(0, 20);
  } else {
    out = { status: b.status, instruction: b.say + (typeof caller.say === 'string' && caller.say ? ' About this caller: ' + caller.say : '') };
    if (typeof b.open === 'boolean') out.open = b.open;
    if (typeof b.can_transfer === 'boolean') out.can_transfer = b.can_transfer;
    // the number is never given to the model; the system chooses it when Vapi sends transfer-destination-request
    if (b.status === 'transfer') out.use_transfer_tool = true;
    if (Array.isArray(b.emergency_keywords)) out.emergency_words = b.emergency_keywords.slice(0, 20);
    if (decision === 'flagged') out.caution = true;
  }
  result = JSON.stringify(out);
} else {
  result = JSON.stringify({ status: 'error', instruction: 'This could not be done right now. Tell the caller the team will call them back. Do not promise anything else.' });
}
return { json: { results: [{ toolCallId: plan.tool_call_id, result }] } };
