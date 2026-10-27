// Zella - Assistant Tools: the answer for ONE tool call, under its own toolCallId. It never contains database
// details; the assistant is told the same thing whether or not the question could be stored (a failure is visible
// in n8n executions).
const plan = $('Use business').item.json;
return { json: { toolCallId: plan.tool_call_id, result: plan.reply_text } };
