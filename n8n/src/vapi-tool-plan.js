// Zella - Assistant Tools: Vapi calls this during a call (1) when the assistant could not answer a question
// (report_unanswered_question) or (2) when the caller wants to complain, correct their details, or ask to see or
// remove their data (log_customer_request). Neither tool changes or releases any customer data.
// Runs once for the whole request and returns ONE ITEM PER TOOL CALL, each with its own tool call id and its own
// answer. Invalid customer-request arguments return an error before any logging RPC. Other non-loggable reports
// are sent as an empty question, which the database refuses. Nothing is run as instructions.
__VAPI_BRAIN_TOOLS__
const body = (($input.first() || {}).json || {}).body;
const m = body && typeof body === 'object' && body.message && typeof body.message === 'object' ? body.message : {};
const list = toolCallList(m);
const nameOf = (t) => (t && (t.name || (t.function && t.function.name))) || '';
const ALLOWED_TOOLS = ['report_unanswered_question', 'log_customer_request'];
if (m.type !== 'tool-calls' || !list.length) return [{ json: { reply: { results: [] }, record: null } }];

const ctx = vapiCallContext(m);
const bid = ctx.fallbackBusinessId;
const callId = ctx.callId;
const callerNumber = ctx.callerNumber;
const lookup = { p_called_number: ctx.calledNumber, p_vapi_phone_number_id: ctx.vapiNumberId, p_fallback: bid };
const kinds = ['complaint', 'correction', 'data_access', 'data_deletion'];

const out = [];
const seen = new Set();
for (const tc of list.slice(0, 10)) {
  if (!tc || typeof tc.id !== 'string' || !tc.id || tc.id.length > 200 || seen.has(tc.id)) continue;
  seen.add(tc.id);
  const name = nameOf(tc);
  const isRequest = name === 'log_customer_request';
  const ok = !ALLOWED_TOOLS.includes(name) ? 'This is not something you can do. Offer to take a message instead.'
    : isRequest
      ? 'Noted. Tell the caller the team has been told and will contact them. Do not say anything has been changed, sent or deleted, and do not read out or confirm any personal details.'
      : 'Noted. Tell the caller you will pass the question to the team and they will get back to them.';
  let args = tc.arguments !== undefined ? tc.arguments : tc.function && tc.function.arguments;
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch (e) { args = {}; } }
  args = args && typeof args === 'object' && !Array.isArray(args) ? args : {};
  const question = String((isRequest ? args.summary : args.question) || '').replace(/\s+/g, ' ').trim().slice(0, isRequest ? 1000 : 500);
  const kind = typeof args.kind === 'string' ? args.kind.trim().toLowerCase() : '';
  const invalid = isRequest && (typeof args.summary !== 'string' || question.length < 3 || !kinds.includes(kind)) ? 'Invalid arguments: provide a summary of at least 3 characters and a supported kind.' : null;
  const loggable = !invalid && ALLOWED_TOOLS.includes(name) && question.length >= 3 && (!isRequest || kinds.includes(kind));
  out.push({ json: { tool_call_id: tc.id, tool: name.slice(0, 80), reply_text: ok, loggable, lookup, invalid,
    rpc: isRequest ? 'zella_ai_log_request' : 'zella_report_unanswered',
    record: isRequest
      ? { p_provider_call_id: callId, p_business_id: bid, p_kind: kind, p_summary: question }
      : { p_provider_call_id: callId, p_business_id: bid, p_question: loggable ? question : '' } } });
}
return out.length ? out : [{ json: { reply: { results: [] }, record: null } }];
