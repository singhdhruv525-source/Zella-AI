// Zella - Meta Leads: build the request for Meta. The token comes from the database; without one the event is retried later.
const plan = $('Plan').item.json;
const t = $json.body;
const token = typeof t === 'string' && t.length >= 20 && t.length < 1000 ? t : null;
if (!plan.valid) return { json: { ...plan, fail: { p_event_id: plan.event_id, p_error: 'bad_event', p_permanent: true } } };
if (!token) return { json: { ...plan, fail: { p_event_id: plan.event_id, p_error: 'no_token_reconnect_needed', p_permanent: false } } };
return {
  json: {
    ...plan, fail: null,
    url: 'https://graph.facebook.com/v21.0/' + plan.leadgen_id + '?fields=field_data,campaign_name,ad_name,form_id,created_time',
    auth: 'Bearer ' + token,
  },
};
