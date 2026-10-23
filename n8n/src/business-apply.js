// Zella - Vapi tools: put the business found from the called number into the database call.
// The lookup answers with the business id (or null). A number that is not registered keeps the id from the call
// settings only if the database accepted it as a fallback; with no business the database call refuses to act.
const plan = $('Plan').item.json;
const b = $json.body;
const found = typeof b === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(b) ? b : null;
return { json: { ...plan, record: { ...plan.record, p_business_id: found } } };
