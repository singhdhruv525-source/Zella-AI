// Zella - Calendar Sync: turn the calendar's events into busy blocks. Cancelled, "free" and Zella-made events are left out.
const plan = $('Plan pull').item.json;
const outlook = plan.provider === 'outlook';
const name = outlook ? 'microsoft' : 'google';
const fail = (error, fatal) => ({ json: { events: null, error: { p_connection_id: plan.connection_id, p_error: String(error).slice(0, 80), p_fatal: !!fatal } } });
if (!plan.connection_id || !plan.url) return { json: { events: null, error: null } };
let tok = null;
for (const node of outlook ? ['Get Microsoft pull token'] : ['Get pull token']) { try { tok = $(node).item.json; } catch (e) { tok = null; } }
const tb = tok && tok.body && typeof tok.body === 'object' ? tok.body : {};
if (!tb.access_token) { const err = typeof tb.error === 'string' ? tb.error.replace(/[^a-z_]/gi, '').slice(0, 30) : 'failed'; return fail(name + '_token_' + err, err === 'invalid_grant'); }
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const list = outlook ? b.value : b.items;
if (!(status >= 200 && status < 300) || !Array.isArray(list)) return fail(name + '_' + (status || 'no_answer'), status === 404);
if (b.nextPageToken || b['@odata.nextLink']) return fail(name + '_truncated', false);
const events = [];
for (const e of list) {
  if (!e || typeof e.id !== 'string') continue;
  if (outlook) {
    if (e.isCancelled || e.showAs === 'free') continue;
    if (Array.isArray(e.singleValueExtendedProperties) && e.singleValueExtendedProperties.some((p) => p && p.value)) continue;
    if (!e.start || !e.end || typeof e.start.dateTime !== 'string' || typeof e.end.dateTime !== 'string') continue;
    // with Prefer: outlook.timezone="UTC" the times come back in UTC, without a zone suffix
    events.push({ id: e.id, start: e.start.dateTime.slice(0, 19) + 'Z', end: e.end.dateTime.slice(0, 19) + 'Z', all_day: !!e.isAllDay });
    continue;
  }
  if (e.status === 'cancelled' || e.transparency === 'transparent') continue;
  if (e.extendedProperties && e.extendedProperties.private && e.extendedProperties.private.zella_appointment_id) continue;
  if (e.start && e.start.dateTime && e.end && e.end.dateTime) events.push({ id: e.id, start: e.start.dateTime, end: e.end.dateTime, all_day: false });
  else if (e.start && e.start.date && e.end && e.end.date) events.push({ id: e.id, start: e.start.date + 'T00:00:00Z', end: e.end.date + 'T00:00:00Z', all_day: true });
}
return { json: { events: { p_connection_id: plan.connection_id, p_events: events }, error: null } };
