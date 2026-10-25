// Zella - Meta Health: ask Meta who the token belongs to (a cheap call that fails if the token is dead) and which permissions it has.
const plan = $('Plan').item.json;
const t = $json.body;
const token = typeof t === 'string' && t.length >= 20 && t.length < 1000 ? t : null;
if (!token) return { json: { ...plan, fail: { p_page_id: plan.page_id, p_ok: false, p_permissions: null, p_auth_failed: true, p_error: 'no_token' } } };
return { json: { ...plan, fail: null, auth: 'Bearer ' + token, url: 'https://graph.facebook.com/v21.0/me?fields=id,name' } };
