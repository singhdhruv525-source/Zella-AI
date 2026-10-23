// Zella - Knowledge: read the AI's draft and save it for the owner to check. Nothing is used until the owner submits.
// A failed or unreadable answer saves nothing; the question is tried again later (up to 3 times in total).
const plan = $('Draft plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const none = { json: { record: null } };
if (!(status >= 200 && status < 300) || !Array.isArray(b.content)) return none;
const text = b.content.filter((c) => c && c.type === 'text').map((c) => c.text).join('');
let d;
try { d = JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, '').trim()); } catch (e) { return none; }
if (!d || typeof d !== 'object') return none;
const confidence = ['high', 'low', 'none'].includes(d.confidence) ? d.confidence : 'low';
const answer = typeof d.answer === 'string' ? d.answer.trim().slice(0, 1000) : '';
const kind = ['faq', 'service', 'policy', 'hours', 'other'].includes(d.kind) ? d.kind : 'faq';
const title = typeof d.title === 'string' ? d.title.trim().slice(0, 120) : '';
return { json: { record: { p_gap_id: plan.gap_id, p_answer: confidence === 'none' ? '' : answer, p_title: title, p_kind: kind, p_source: 'ai_draft_from_approved_knowledge', p_confidence: answer ? confidence : 'none' } } };
