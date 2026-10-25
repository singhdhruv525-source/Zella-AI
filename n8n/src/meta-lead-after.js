// Zella - Meta Leads: turn Meta's answer into either "save this lead" or "mark this attempt failed".
// Nothing from the answer except the form answers and the campaign name is kept.
const plan = $('Build request').item.json;
if (plan.fail) return { json: { save: null, fail: plan.fail } };
const r = $json;
const status = Number(r.statusCode);
const b = r.body && typeof r.body === 'object' ? r.body : {};
if (status >= 200 && status < 300 && Array.isArray(b.field_data)) {
  const fields = b.field_data.slice(0, 40).filter((f) => f && typeof f.name === 'string').map((f) => ({
    name: f.name.slice(0, 80), values: Array.isArray(f.values) ? f.values.slice(0, 3).map((v) => String(v).slice(0, 300)) : [],
  }));
  const camp = typeof b.campaign_name === 'string' ? b.campaign_name : typeof b.ad_name === 'string' ? b.ad_name : null;
  return { json: { save: { p_event_id: plan.event_id, p_fields: fields, p_campaign: camp ? camp.slice(0, 120) : null }, fail: null } };
}
const code = b.error && typeof b.error === 'object' ? Number(b.error.code) : 0;
// a lead that no longer exists or may not be read will never work; anything else is tried again
const permanent = status === 404 || (status === 400 && code === 100);
return { json: { save: null, fail: { p_event_id: plan.event_id, p_error: ('HTTP ' + (status || 'none') + (code ? ' code ' + code : '')).slice(0, 100), p_permanent: permanent } } };
