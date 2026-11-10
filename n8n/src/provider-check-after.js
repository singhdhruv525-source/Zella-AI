// Zella - Connection Tests: turn the provider's answer into a short result. Only the status number is kept,
// never the response text (it can contain account details).
const plan = $('Plan').item.json;
if (!plan.provider) return { json: { record: null } };
const status = Number($json.statusCode);
const ok = status >= 200 && status < 300;
const detail = ok ? 'ok' : status === 401 || status === 403 ? 'key rejected (' + status + ')' : status ? 'HTTP ' + status : 'no answer';
return { json: { record: { p_provider: plan.provider, p_ok: ok, p_detail: detail } } };
