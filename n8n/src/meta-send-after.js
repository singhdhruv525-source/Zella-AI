// Zella - Meta Sender: what happened. Success keeps only Meta's message id; failures keep a short code, never the response text.
const plan = $('Build request').item.json;
if (plan.fail) return { json: { record: plan.fail } };
const r = $json;
const status = Number(r.statusCode);
const b = r.body && typeof r.body === 'object' ? r.body : {};
if (status >= 200 && status < 300) {
  const ext = typeof b.message_id === 'string' ? b.message_id : Array.isArray(b.messages) && b.messages[0] && typeof b.messages[0].id === 'string' ? b.messages[0].id : null;
  return { json: { record: { p_id: plan.id, p_ok: true, p_external_id: ext ? ext.slice(0, 200) : null } } };
}
const code = b.error && typeof b.error === 'object' ? Number(b.error.code) : 0;
const auth = status === 401 || code === 190;
const retry = !auth && (status >= 500 || status === 429 || [1, 2, 4, 17, 32, 613].includes(code));
return { json: { record: { p_id: plan.id, p_ok: false, p_error: ('HTTP ' + (status || 'none') + (code ? ' code ' + code : '')).slice(0, 100), p_auth_failed: auth, p_retry: retry } } };
