// Zella - Calendar Sync: turn one queued booking change into a request to the business's calendar provider
// (Google Calendar, or Outlook / Microsoft 365 through Microsoft Graph). Nothing is sent from here.
// The refresh token passes through execution data; this workflow does not save execution data.
const it = $json;
const provider = it && it.provider === 'outlook' ? 'outlook' : 'google';
// Zella's marker on events it created (so busy-time reading leaves them out and edits find them)
const MS_PROP = 'String {6f1d2c9a-3b7e-4a51-9c0d-8e2f4b6a1c35} Name zella_appointment_id';
const none = { json: { queue_id: it && it.queue_id ? it.queue_id : null, provider, needs_google: false, token_form: null, google: null, skip_ok: false } };
if (!it || !it.queue_id || !it.refresh_token || !it.calendar_id) return none;
const tokenForm = { refresh_token: String(it.refresh_token) };
const ask = (google) => ({ json: { queue_id: it.queue_id, provider, needs_google: true, token_form: tokenForm, skip_ok: false, google } });
let base;
if (provider === 'outlook') {
  base = String(it.calendar_id) === 'primary' ? 'https://graph.microsoft.com/v1.0/me/events'
    : 'https://graph.microsoft.com/v1.0/me/calendars/' + encodeURIComponent(String(it.calendar_id)) + '/events';
} else {
  base = 'https://www.googleapis.com/calendar/v3/calendars/' + encodeURIComponent(String(it.calendar_id)) + '/events';
}
// Graph addresses an event by id alone, whichever calendar holds it
const eventUrl = (id) => provider === 'outlook' ? 'https://graph.microsoft.com/v1.0/me/events/' + encodeURIComponent(String(id)) : base + '/' + encodeURIComponent(String(id));
if (it.action === 'delete') {
  if (!it.event_id) return { json: { queue_id: it.queue_id, provider, needs_google: false, token_form: null, google: null, skip_ok: true } };
  return ask({ action: 'delete', method: 'DELETE', url: eventUrl(it.event_id), body: null });
}
if (it.action !== 'upsert' || !it.event || !it.event.start || !it.event.end) return none;
const e = it.event;
const update = !!it.event_id;
let body;
if (provider === 'outlook') {
  const utc = (s) => { const d = new Date(s); return Number.isFinite(d.getTime()) ? d.toISOString().slice(0, 19) : null; };
  const start = utc(e.start); const end = utc(e.end);
  if (!start || !end) return none; // Graph: a local date-time plus its time zone
  body = {
    subject: String(e.summary || 'Appointment').slice(0, 200),
    body: { contentType: 'text', content: String(e.description || '').slice(0, 1000) },
    start: { dateTime: start, timeZone: 'UTC' },
    end: { dateTime: end, timeZone: 'UTC' },
    singleValueExtendedProperties: [{ id: MS_PROP, value: String(it.appointment_id || '') }],
  };
} else {
  body = {
    summary: String(e.summary || 'Appointment').slice(0, 200),
    description: String(e.description || '').slice(0, 1000),
    start: { dateTime: e.start, timeZone: e.timezone || 'America/New_York' },
    end: { dateTime: e.end, timeZone: e.timezone || 'America/New_York' },
    extendedProperties: { private: { zella_appointment_id: String(it.appointment_id || '') } },
  };
}
return ask({ action: 'upsert', method: update ? 'PATCH' : 'POST', url: update ? eventUrl(it.event_id) : base, body });
