// Zella - Meta Webhook: answer Meta. A wrong signature gets 403; everything else gets 200 so Meta does not keep retrying.
const plan = $('Prepare').item.json;
const r = $json;
const b = r.body && typeof r.body === 'object' ? r.body : {};
const bad = !plan.ok || b.result === 'unauthorized';
return { json: { code: bad ? 403 : 200, body: { ok: !bad } } };
