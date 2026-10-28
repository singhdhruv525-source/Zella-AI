// Zella - Review Replies: read the AI's reply. Anything unreadable keeps the standard draft (the database also refuses
// replies that are too short, too long or contain links).
const plan = $('Draft plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const keep = { json: { record: { p_review_id: plan.review_id, p_draft: '' } } };
if (!(status >= 200 && status < 300) || !Array.isArray(b.content)) return keep;
const text = b.content.filter((c) => c && c.type === 'text').map((c) => c.text).join('');
let d;
try { d = JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, '').trim()); } catch (e) { return keep; }
const reply = d && typeof d.reply === 'string' ? d.reply.replace(/\s+\n/g, '\n').trim().slice(0, 1500) : '';
return { json: { record: { p_review_id: plan.review_id, p_draft: reply } } };
