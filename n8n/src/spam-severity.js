// Zella - Spam Response: decide where each claimed item goes. The incident is already detected, scored, saved and
// (for calls) screened by the database before this runs; this only routes the follow-up:
//   log          nothing for anyone to do now (recorded as processed)
//   alert        tell the team (high risk, or medium when the business asked for medium alerts)
//   investigate  look closer first: a sender seen before, at other businesses, flooding, or an ambiguous message
// The database checks everything again when the result comes back, so a wrong route here can't cause harm.
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const j = $json && typeof $json === 'object' ? $json : {};

if (j.kind === 'report') {
  if (!uuid.test(String(j.business_id || '')) || !/^\d{4}-\d{2}-\d{2}$/.test(String(j.week_start || ''))) return { json: { kind: 'skip', why: 'bad_report' } };
  return { json: { kind: 'report', business_id: j.business_id, business_name: String(j.business_name || '').slice(0, 120), week_start: j.week_start, stats: j.stats && typeof j.stats === 'object' ? j.stats : {} } };
}
if (j.kind !== 'incident' || !uuid.test(String(j.incident_id || '')) || !uuid.test(String(j.claim || ''))) return { json: { kind: 'skip', why: 'not_an_item' } };

const inc = j.incident && typeof j.incident === 'object' ? j.incident : {};
const f = j.facts && typeof j.facts === 'object' ? j.facts : {};
const p = j.policy && typeof j.policy === 'object' ? j.policy : {};
const n = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
const seenBefore = n(f.here_prior) > 0 || n(f.here_confirmed) > 0 || n(f.other_businesses) > 0;
const flooding = n(inc.occurrences) >= Math.max(2, n(p.flood_alert_at) || 20);
const ai = j.ai_request && typeof j.ai_request === 'object' && Array.isArray(j.ai_request.messages) ? j.ai_request : null;

let route = 'log';
if (f.allowlisted === true) route = 'log';
else if (inc.risk_level === 'high') route = seenBefore || flooding ? 'investigate' : 'alert';
else if (inc.risk_level === 'medium') route = ai || seenBefore ? 'investigate' : p.notify_medium === true ? 'alert' : 'log';

return {
  json: {
    kind: 'incident', route, incident_id: j.incident_id, claim: j.claim,
    risk_level: inc.risk_level || null, channel: inc.channel || null, facts: f,
    ai_request: route === 'investigate' ? ai : null,
    finish: { p_incident_id: j.incident_id, p_claim: j.claim, p_result: { route } },
  },
};
