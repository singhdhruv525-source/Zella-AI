// Zella - Voice Rules: the answer sent back to Vapi. Short, no database details.
const plan = $('Plan').item.json;
if (!plan.record) return { json: plan.reply };
const r = $json;
const status = Number(r.statusCode);
const b = r.body && typeof r.body === 'object' ? r.body : null;
let result;
if (status >= 200 && status < 300 && b && typeof b.say === 'string') {
  const out = { status: b.status, instruction: b.say };
  if (typeof b.open === 'boolean') out.open = b.open;
  if (typeof b.can_transfer === 'boolean') out.can_transfer = b.can_transfer;
  if (b.status === 'transfer' && typeof b.transfer_number === 'string' && /^\+?[0-9]{7,15}$/.test(b.transfer_number)) out.transfer_number = b.transfer_number;
  if (Array.isArray(b.emergency_keywords)) out.emergency_words = b.emergency_keywords.slice(0, 20);
  result = JSON.stringify(out);
} else {
  result = JSON.stringify({ status: 'error', instruction: 'This could not be done right now. Tell the caller the team will call them back. Do not promise anything else.' });
}
return { json: { results: [{ toolCallId: plan.tool_call_id, result }] } };
