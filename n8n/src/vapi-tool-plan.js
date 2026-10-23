// Zella - Assistant Tools: Vapi calls this during a call when the assistant could not answer a question.
// Input is Vapi's tool-calls message. Output: { reply, record }. reply = what to send back to Vapi (always valid),
// record = the database call to make (or null). Nothing from the caller is run as instructions.
const body = $json.body && typeof $json.body === 'object' ? $json.body : {};
const m = body.message && typeof body.message === 'object' ? body.message : {};
const list = Array.isArray(m.toolCallList) ? m.toolCallList : Array.isArray(m.toolCalls) ? m.toolCalls : [];
const reply = (id, text) => ({ results: [{ toolCallId: id, result: text }] });
const ok = 'Noted. Tell the caller you will pass the question to the team and they will get back to them.';

const tc = list.find((t) => t && (t.name === 'report_unanswered_question' || (t.function && t.function.name === 'report_unanswered_question')));
if (m.type !== 'tool-calls' || !tc || typeof tc.id !== 'string') return { json: { reply: { results: [] }, record: null } };

let args = tc.arguments !== undefined ? tc.arguments : tc.function && tc.function.arguments;
if (typeof args === 'string') { try { args = JSON.parse(args); } catch (e) { args = {}; } }
args = args && typeof args === 'object' ? args : {};
const question = String(args.question || '').replace(/\s+/g, ' ').trim().slice(0, 500);
if (question.length < 3) return { json: { reply: reply(tc.id, ok), record: null } };

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

return {
  json: {
    reply: reply(tc.id, ok),
    lookup,
    record: { p_provider_call_id: typeof call.id === 'string' ? call.id.slice(0, 200) : null, p_business_id: bid, p_question: question },
  },
};
