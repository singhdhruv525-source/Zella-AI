// Zella - Assistant Tools: Vapi calls this during a call (1) when the assistant could not answer a question
// (report_unanswered_question) or (2) when the caller wants to complain, correct their details, or ask to see or
// remove their data (log_customer_request). Neither tool changes or releases any customer data.
// Runs once for the whole request and returns ONE ITEM PER TOOL CALL, each with its own tool call id and its own
// answer. Input that can't be logged (no question, unknown kind, other tool) is sent as an empty question, which the
// database refuses before doing anything; the assistant still gets a valid answer. Nothing is run as instructions.
const body = (($input.first() || {}).json || {}).body;
const m = body && typeof body === 'object' && body.message && typeof body.message === 'object' ? body.message : {};
const list = Array.isArray(m.toolCallList) ? m.toolCallList : Array.isArray(m.toolCalls) ? m.toolCalls : [];
const nameOf = (t) => (t && (t.name || (t.function && t.function.name))) || '';
const TOOLS = ['report_unanswered_question', 'log_customer_request'];
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
const callId = typeof call.id === 'string' ? call.id.slice(0, 200) : null;
const kinds = ['complaint', 'correction', 'data_access', 'data_deletion'];

const out = [];
const seen = new Set();
for (const tc of list.slice(0, 10)) {
  if (!tc || typeof tc.id !== 'string' || !tc.id || tc.id.length > 200 || seen.has(tc.id)) continue;
  seen.add(tc.id);
  const name = nameOf(tc);
  const isRequest = name === 'log_customer_request';
  const ok = !TOOLS.includes(name) ? 'This is not something you can do. Offer to take a message instead.'
    : isRequest
      ? 'Noted. Tell the caller the team has been told and will contact them. Do not say anything has been changed, sent or deleted, and do not read out or confirm any personal details.'
      : 'Noted. Tell the caller you will pass the question to the team and they will get back to them.';
  let args = tc.arguments !== undefined ? tc.arguments : tc.function && tc.function.arguments;
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch (e) { args = {}; } }
  args = args && typeof args === 'object' && !Array.isArray(args) ? args : {};
  const question = String((isRequest ? args.summary : args.question) || '').replace(/\s+/g, ' ').trim().slice(0, isRequest ? 1000 : 500);
  const kind = typeof args.kind === 'string' ? args.kind.trim().toLowerCase() : '';
  const loggable = TOOLS.includes(name) && question.length >= 3 && (!isRequest || kinds.includes(kind));
  out.push({ json: { tool_call_id: tc.id, reply_text: ok, loggable, lookup,
    rpc: loggable && isRequest ? 'zella_ai_log_request' : 'zella_report_unanswered',
    record: loggable && isRequest
      ? { p_provider_call_id: callId, p_business_id: bid, p_kind: kind, p_summary: question }
      : { p_provider_call_id: callId, p_business_id: bid, p_question: loggable ? question : '' } } });
}
return out.length ? out : [{ json: { reply: { results: [] }, record: null } }];
