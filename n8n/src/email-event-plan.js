// Zella - Email Events: Resend tells us what happened to an email (delivered, bounced, marked as spam).
// The secret key in the webhook address and the event are handed to the database, which checks the key.
const key = typeof ($json.query && $json.query.key) === 'string' ? $json.query.key.slice(0, 200) : '';
const h = $json.headers && typeof $json.headers === 'object' ? $json.headers : {};
const event = $json.body && typeof $json.body === 'object' && !Array.isArray($json.body) ? $json.body : null;
const data = event && event.data && typeof event.data === 'object' ? event.data : {};
const eventId = String(h['svix-id'] || (event ? [event.type, data.email_id, event.created_at].filter(Boolean).join(':') : '')).slice(0, 200);
if (!event || !eventId) return { json: { record: null } };
return { json: { record: { p_key: key, p_event: event, p_event_id: eventId } } };
