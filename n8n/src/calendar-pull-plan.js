// Zella - Calendar Sync: build the request that lists one business calendar's upcoming events.
const c = $json;
if (!c || !c.connection_id || !c.refresh_token || !c.calendar_id) return { json: { connection_id: c && c.connection_id ? c.connection_id : null, token_form: null, url: null } };
const q = new URLSearchParams({ timeMin: c.from, timeMax: c.to, singleEvents: 'true', orderBy: 'startTime', maxResults: '250',
  fields: 'items(id,status,transparency,start,end,extendedProperties)' });
return { json: { connection_id: c.connection_id, token_form: { refresh_token: String(c.refresh_token) },
  url: 'https://www.googleapis.com/calendar/v3/calendars/' + encodeURIComponent(String(c.calendar_id)) + '/events?' + q.toString() } };
