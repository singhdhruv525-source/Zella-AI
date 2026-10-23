// Zella - Assistant Tools: the answer sent back to Vapi. It never contains database details; the assistant is
// told the same thing whether or not the question could be stored (the failure is visible in n8n executions).
const plan = $('Plan').item.json;
return { json: plan.reply };
