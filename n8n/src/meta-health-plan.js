// Zella - Meta Health: one connection due for a check.
const pageId = typeof $json.page_id === 'string' && /^[0-9]{5,30}$/.test($json.page_id) ? $json.page_id : null;
if (!pageId) return { json: { skip: true } };
const waba = typeof $json.waba_id === 'string' && /^[0-9]{5,30}$/.test($json.waba_id) ? $json.waba_id : null;
return { json: { skip: false, page_id: pageId, waba_id: waba } };
