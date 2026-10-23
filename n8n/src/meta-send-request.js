// Zella - Meta Sender: add the token from the database. Without a token (or a valid destination) the reply fails and says why.
const plan = $('Plan').item.json;
const t = $json.body;
const token = typeof t === 'string' && t.length >= 20 && t.length < 1000 ? t : null;
if (!plan.valid) return { json: { ...plan, fail: { p_id: plan.id, p_ok: false, p_error: 'cannot_build_request', p_auth_failed: false, p_retry: false } } };
if (!token) return { json: { ...plan, fail: { p_id: plan.id, p_ok: false, p_error: 'no_token_reconnect_needed', p_auth_failed: false, p_retry: true } } };
return { json: { ...plan, fail: null, auth: 'Bearer ' + token } };
