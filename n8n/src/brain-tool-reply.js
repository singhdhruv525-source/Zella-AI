// Zella - Receptionist Brain: the answer for ONE tool call, matched by its own toolCallId (shared with the voice-rules
// edge function: web/supabase/functions/_shared/vapi-brain-tools.js, inlined by build.mjs).
__VAPI_BRAIN_TOOLS__
const plan = $('Use business').item.json;
const name = String(plan.tool || '').slice(0, 80);
if (plan.invalid) return { json: brainInvalidReply(name, plan.tool_call_id, plan.invalid) };
const status = Number($json.statusCode);
return { json: brainToolReply(name, plan.tool_call_id, status >= 200 && status < 300, $json.body) };
