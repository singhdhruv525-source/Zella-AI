// Zella - Assistant Tools: the answer for ONE tool call, under its own toolCallId. It never contains database
// details; a failed write returns an error so the assistant cannot claim the team was notified.
const plan = $('Use business').item.json;
if (plan.loggable && !(Number($json.statusCode) >= 200 && Number($json.statusCode) < 300)) return { json: { name: String(plan.tool || '').slice(0, 80), toolCallId: plan.tool_call_id, error: 'The request could not be saved. Offer to try again or take another contact route; do not say the team was notified.' } };
return { json: { name: String(plan.tool || '').slice(0, 80), toolCallId: plan.tool_call_id, result: plan.reply_text } };
