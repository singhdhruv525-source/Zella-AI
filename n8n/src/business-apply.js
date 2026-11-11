// Zella - Vapi tools: put the business found from the called number into the database call.
// All callers query with p_fallback null: only a trusted registered phone association can return an id.
// Unlinked call settings are rejected. Existing calls are resolved by the acting RPC even with a null business id.
const plan = $('Plan').item.json;
const b = $json.body;
const status = Number($json.statusCode);
const found = status >= 200 && status < 300 && typeof b === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(b) ? b : null;
return { json: { ...plan, record: { ...plan.record, p_business_id: found } } };
