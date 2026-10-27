// Zella - Voice Rules: Vapi calls the tool "call_rules" DURING a call. One tool, four actions:
// rules (open or closed?), message (take a message), emergency, transfer (reach a person).
// Runs once for the whole request and returns ONE ITEM PER TOOL CALL, each with its own tool call id, so several
// tool calls in one request each get an answer. A bad action or another tool still gets its own answer: it is sent
// with action "invalid", which the database refuses before doing anything (zella_ai_voice raises BAD_ACTION).
// Only known fields are passed on; the caller's words are data and are never run as instructions.
// The voice-rules Supabase function answers the same requests without n8n (docs/VOICE_RELIABILITY.md).
const body = (($input.first() || {}).json || {}).body;
const m = body && typeof body === 'object' && body.message && typeof body.message === 'object' ? body.message : {};
const list = Array.isArray(m.toolCallList) ? m.toolCallList : Array.isArray(m.toolCalls) ? m.toolCalls : [];
const nameOf = (t) => (t && (t.name || (t.function && t.function.name))) || '';
const ACTIONS = ['rules', 'message', 'emergency', 'transfer'];
if (m.type !== 'tool-calls' || !list.length) return [{ json: { reply: { results: [] }, record: null } }];

const call = m.call && typeof m.call === 'object' ? m.call : {};
const meta = call.metadata && typeof call.metadata === 'object' ? call.metadata : {};
const vars = call.assistantOverrides && call.assistantOverrides.variableValues && typeof call.assistantOverrides.variableValues === 'object' ? call.assistantOverrides.variableValues : {};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const bid = [meta.business_id, vars.business_id].find((v) => typeof v === 'string' && uuid.test(v)) || null;
// Which number was called? Used to find the business (a registered number always wins over call settings).
const pn = call.phoneNumber && typeof call.phoneNumber === 'object' ? call.phoneNumber : m.phoneNumber && typeof m.phoneNumber === 'object' ? m.phoneNumber : {};
const calledNumber = typeof pn.number === 'string' && /^\+?[0-9() .-]{7,20}$/.test(pn.number) ? pn.number : null;
const vapiNumberId = typeof call.phoneNumberId === 'string' ? call.phoneNumberId.slice(0, 100) : typeof pn.id === 'string' ? pn.id.slice(0, 100) : null;
const lookup = { p_called_number: calledNumber, p_vapi_phone_number_id: vapiNumberId, p_fallback: bid };
// The caller's own number comes from the phone network, never from what they say.
const cn = call.customer && typeof call.customer === 'object' ? String(call.customer.number || '') : '';
const callerNumber = /^\+?[0-9]{7,15}$/.test(cn) ? cn : null;
const callId = typeof call.id === 'string' ? call.id.slice(0, 200) : null;

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
