// Zella Voice - Calendar Sync: build the request that lists one business calendar's upcoming events (Google or Outlook).
const c = $json;
const provider = c && c.provider === 'outlook' ? 'outlook' : 'google';
if (!c || !c.connection_id || !c.refresh_token || !c.calendar_id) return { json: { connection_id: c && c.connection_id ? c.connection_id : null, provider, token_form: null, url: null, prefer: '' } };
if (provider === 'outlook') {
  const MS_PROP = 'String {6f1d2c9a-3b7e-4a51-9c0d-8e2f4b6a1c35} Name zella_appointment_id';
  const where = String(c.calendar_id) === 'primary' ? 'me/calendarView' : 'me/calendars/' + encodeURIComponent(String(c.calendar_id)) + '/calendarView';
  const q = new URLSearchParams({ startDateTime: c.from, endDateTime: c.to, $top: '250', $select: 'id,showAs,isCancelled,isAllDay,start,end',
    $expand: "singleValueExtendedProperties($filter=id eq '" + MS_PROP + "')" });
  return { json: { connection_id: c.connection_id, provider, token_form: { refresh_token: String(c.refresh_token) },
    url: 'https://graph.microsoft.com/v1.0/' + where + '?' + q.toString(), prefer: 'outlook.timezone="UTC"' } };
}
const q = new URLSearchParams({ timeMin: c.from, timeMax: c.to, singleEvents: 'true', orderBy: 'startTime', maxResults: '250',
  fields: 'nextPageToken,items(id,status,transparency,start,end,extendedProperties)' });
return { json: { connection_id: c.connection_id, provider, token_form: { refresh_token: String(c.refresh_token) },
  url: 'https://www.googleapis.com/calendar/v3/calendars/' + encodeURIComponent(String(c.calendar_id)) + '/events?' + q.toString(), prefer: '' } };
