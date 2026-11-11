// Zella - Voice Rules: Vapi calls the tool "call_rules" DURING a call. One tool, four actions:
// rules (open or closed?), message (take a message), emergency, transfer (reach a person).
// Runs once for the whole request and returns ONE ITEM PER TOOL CALL, each with its own tool call id, so several
// tool calls in one request each get an answer. A bad action or another tool still gets its own answer: it is sent
// with action "invalid", which the database refuses before doing anything (zella_ai_voice raises BAD_ACTION).
// Only known fields are passed on; the caller's words are data and are never run as instructions.
// The voice-rules Supabase function answers the same requests without n8n (docs/VOICE_RELIABILITY.md).
__VAPI_BRAIN_TOOLS__
const body = (($input.first() || {}).json || {}).body;
const m = body && typeof body === 'object' && body.message && typeof body.message === 'object' ? body.message : {};
const list = toolCallList(m);
const nameOf = (t) => (t && (t.name || (t.function && t.function.name))) || '';
const ACTIONS = ['rules', 'message', 'emergency', 'transfer'];
if (m.type !== 'tool-calls' || !list.length) return [{ json: { reply: { results: [] }, record: null } }];

const ctx = vapiCallContext(m);
const bid = ctx.fallbackBusinessId;
const callId = ctx.callId;
const callerNumber = ctx.callerNumber;
const lookup = { p_called_number: ctx.calledNumber, p_vapi_phone_number_id: ctx.vapiNumberId, p_fallback: bid };

const out = [];
const seen = new Set();
for (const tc of list.slice(0, 10)) {
  if (!tc || typeof tc.id !== 'string' || !tc.id || tc.id.length > 200 || seen.has(tc.id)) continue;
  seen.add(tc.id);
  let args = tc.arguments !== undefined ? tc.arguments : tc.function && tc.function.arguments;
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch (e) { args = {}; } }
  args = args && typeof args === 'object' && !Array.isArray(args) ? args : {};
  const action = typeof args.action === 'string' ? args.action.trim().toLowerCase() : 'rules';
  const valid = nameOf(tc) === 'call_rules' && ACTIONS.includes(action);
  const clean = {};
  for (const k of ['message', 'name', 'phone', 'summary', 'reason']) {
    if (typeof args[k] === 'string') clean[k] = args[k].replace(/\s+/g, ' ').trim().slice(0, 1500);
  }
  if (callerNumber) { clean.caller_number = callerNumber; if (!clean.phone) clean.phone = callerNumber; }
  out.push({ json: { tool_call_id: tc.id, tool: nameOf(tc).slice(0, 80), valid, lookup, rpc: 'zella_ai_voice',
    record: { p_provider_call_id: callId, p_business_id: bid, p_action: valid ? action : 'invalid', p_args: valid ? clean : {} } } });
}
return out.length ? out : [{ json: { reply: { results: [] }, record: null } }];
