// Zella - Spam Response: read the AI's second opinion. It is only a suggestion shown to the team: the database keeps
// it (if this incident was allowed an AI review at all) and never blocks or changes anything because of it.
// If the AI is down or answers badly, the incident is still processed without it, so alerts are never held up.
const s = $('Check repeat offender').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const out = (extra) => ({ json: { ...s, finish: { ...s.finish, p_result: { ...s.finish.p_result, ...extra } } } });
if (!(status >= 200 && status < 300) || !Array.isArray(b.content)) return out({ ai_error: 'AI unavailable (' + (status || 'no answer') + ')' });
const text = b.content.filter((c) => c && c.type === 'text').map((c) => c.text).join('');
let d;
try { d = JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, '').trim()); } catch (e) { return out({ ai_error: 'Unreadable AI answer' }); }
if (!d || typeof d !== 'object' || !['spam', 'not_spam', 'unsure'].includes(d.label)) return out({ ai_error: 'Unreadable AI answer' });
const confidence = Number(d.confidence);
return out({
  ai: {
    label: d.label,
    confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : null,
    reason: typeof d.reason === 'string' ? d.reason.replace(/\s+/g, ' ').trim().slice(0, 200) : '',
  },
});
