// Zella - Calendar Sync: read Google's answer and report it back to the database (which retries or raises an alert).
// Only a short error name is kept; Google's response text is never stored.
const plan = $('Plan sync').item.json;
const rec = (ok, eventId, error) => ({ json: { record: { p_queue_id: plan.queue_id, p_ok: ok, p_event_id: eventId || null, p_error: ok ? null : String(error).slice(0, 80) } } });
if (!plan.queue_id) return { json: { record: null } };
if (!plan.needs_google) return plan.skip_ok ? rec(true, null) : rec(false, null, 'bad_queue_item');
let tok = null;
try { tok = $('Get Google token').item.json; } catch (e) { tok = null; }
const tb = tok && tok.body && typeof tok.body === 'object' ? tok.body : {};
if (!tb.access_token) return rec(false, null, 'google_token_' + (typeof tb.error === 'string' ? tb.error.replace(/[^a-z_]/gi, '').slice(0, 30) : 'failed'));
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
if (plan.google.action === 'delete') return (status >= 200 && status < 300) || status === 404 || status === 410 ? rec(true, null) : rec(false, null, 'google_' + (status || 'no_answer'));
if (status >= 200 && status < 300 && typeof b.id === 'string') return rec(true, b.id);
return rec(false, null, 'google_' + (status || 'no_answer'));
