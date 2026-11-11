// Only a complete, successful lookup permits creating an event.
const plan = $('Plan sync').item.json;
const failed = () => ({ json: { record: { p_queue_id: plan.queue_id, p_ok: false, p_event_id: null, p_error: 'calendar_reconciliation_failed' } } });
const b = $json.body || {};
const events = plan.provider === 'outlook' ? b.value : b.items;
if ($json.statusCode !== 200 || !Array.isArray(events) || b.nextPageToken || b['@odata.nextLink'] || events.length > 1) {
  return failed();
}
const google = { ...plan.google };
if (events.length) {
  if (typeof events[0].id !== 'string' || !events[0].id) return failed();
  google.method = 'PATCH';
  google.url = plan.provider === 'outlook' ? 'https://graph.microsoft.com/v1.0/me/events/' + encodeURIComponent(events[0].id) : google.url + '/' + encodeURIComponent(events[0].id);
  google.body = { ...google.body };
  delete google.body.id;
  delete google.body.transactionId;
}
return { json: { google } };
