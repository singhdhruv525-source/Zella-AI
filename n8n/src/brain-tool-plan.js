// Zella - Receptionist Brain: the webhook for every tool the phone assistant (Vapi) uses during a call.
// Runs once for the whole request and returns ONE ITEM PER TOOL CALL, each with its own tool call id and one database
// call (zella_ai_tool, which checks, acts, verifies and logs). A request that isn't a tool call returns one item with an
// empty reply. The parsing is shared with the voice-rules edge function (web/supabase/functions/_shared/vapi-brain-tools.js,
// inlined here by build.mjs), so both answer the same request the same way.
// The Appointment Booking webhook reuses this file with only the booking tools (build.mjs fills __ONLY_TOOLS__ in).
__VAPI_BRAIN_TOOLS__
const body = (($input.first() || {}).json || {}).body;
const m = body && typeof body === 'object' && body.message && typeof body.message === 'object' ? body.message : {};
const calls = m.type === 'tool-calls' ? toolCallList(m) : [];
if (!calls.length) return [{ json: { reply: { results: [] }, record: null } }];
const ONLY = '__ONLY_TOOLS__';
const allowed = ONLY.startsWith('__') ? TOOLS : TOOLS.filter((t) => ONLY.split(',').includes(t));
const ctx = vapiCallContext(m);
const lookup = { p_called_number: ctx.calledNumber, p_vapi_phone_number_id: ctx.vapiNumberId, p_fallback: ctx.fallbackBusinessId };
return calls.map((tc) => {
  const p = planBrainTool(tc, ctx, allowed);
  return { json: { tool_call_id: p.toolCallId, tool: p.name, invalid: p.invalid, lookup, record: p.record } };
});
