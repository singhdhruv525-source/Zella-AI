// Zella - Calendar Sync: turn one queued booking change into a Google Calendar request. Nothing is sent from here.
// The refresh token only lives in this run's data; it is never logged or stored.
const it = $json;
const none = { json: { queue_id: it && it.queue_id ? it.queue_id : null, needs_google: false, token_form: null, google: null, skip_ok: false } };
if (!it || !it.queue_id || !it.refresh_token || !it.calendar_id) return none;
const cal = encodeURIComponent(String(it.calendar_id));
const base = 'https://www.googleapis.com/calendar/v3/calendars/' + cal + '/events';
const tokenForm = { refresh_token: String(it.refresh_token) };
if (it.action === 'delete') {
  if (!it.event_id) return { json: { queue_id: it.queue_id, needs_google: false, token_form: null, google: null, skip_ok: true } };
  return { json: { queue_id: it.queue_id, needs_google: true, token_form: tokenForm, skip_ok: false,
    google: { action: 'delete', method: 'DELETE', url: base + '/' + encodeURIComponent(String(it.event_id)), body: null } } };
}
if (it.action !== 'upsert' || !it.event || !it.event.start || !it.event.end) return none;
const e = it.event;
const body = {
  summary: String(e.summary || 'Appointment').slice(0, 200),
  description: String(e.description || '').slice(0, 1000),
  start: { dateTime: e.start, timeZone: e.timezone || 'America/New_York' },
  end: { dateTime: e.end, timeZone: e.timezone || 'America/New_York' },
  extendedProperties: { private: { zella_appointment_id: String(it.appointment_id || '') } },
};
const update = !!it.event_id;
return { json: { queue_id: it.queue_id, needs_google: true, token_form: tokenForm, skip_ok: false,
  google: { action: 'upsert', method: update ? 'PATCH' : 'POST', url: update ? base + '/' + encodeURIComponent(String(it.event_id)) : base, body } } };
