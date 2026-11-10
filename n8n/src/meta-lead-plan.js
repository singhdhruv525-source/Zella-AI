// Zella - Meta Leads: one claimed lead event in. Only plain ids are used to build the request.
const id = (v, re) => (typeof v === 'string' && re.test(v) ? v : null);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const eventId = id($json.event_id, uuid);
const pageId = id($json.page_id, /^[0-9]{5,30}$/);
const leadId = id($json.leadgen_id, /^[0-9]{5,30}$/);
if (!eventId) return { json: { skip: true } };
return { json: { skip: false, event_id: eventId, page_id: pageId, leadgen_id: leadId, valid: !!(pageId && leadId) } };
