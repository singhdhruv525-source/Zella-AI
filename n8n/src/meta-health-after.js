// Zella - Meta Health: liveness result. A rejected token means the page must be reconnected; anything else is a temporary error.
const plan = $('Build request').item.json;
if (plan.fail) return { json: { record: plan.fail, templates: false } };
const r = $json;
const status = Number(r.statusCode);
const b = r.body && typeof r.body === 'object' ? r.body : {};
if (status >= 200 && status < 300) return { json: { record: { p_page_id: plan.page_id, p_ok: true, p_permissions: null, p_auth_failed: false, p_error: null }, templates: !!plan.waba_id } };
const code = b.error && typeof b.error === 'object' ? Number(b.error.code) : 0;
const auth = status === 401 || code === 190;
return { json: { record: { p_page_id: plan.page_id, p_ok: false, p_permissions: null, p_auth_failed: auth, p_error: ('HTTP ' + (status || 'none') + (code ? ' code ' + code : '')).slice(0, 100) }, templates: false } };
