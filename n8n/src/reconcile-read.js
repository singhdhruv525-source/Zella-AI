// Zella - Call Reconciliation: hand the database only the fields it records (ids, times, ended reason, numbers,
// summary, transcript, recording link). The database checks the id matches and that the call really ended.
const plan = $('Plan').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' && !Array.isArray($json.body) ? $json.body : {};
const str = (v, n) => (typeof v === 'string' ? v.slice(0, n) : null);
const a = b.artifact && typeof b.artifact === 'object' ? b.artifact : {};
const an = b.analysis && typeof b.analysis === 'object' ? b.analysis : {};
const call = {
  id: str(b.id, 200), status: str(b.status, 30), startedAt: str(b.startedAt, 40), endedAt: str(b.endedAt, 40), endedReason: str(b.endedReason, 80),
  phoneNumberId: str(b.phoneNumberId, 100),
  phoneNumber: { number: str(b.phoneNumber && b.phoneNumber.number, 30) }, customer: { number: str(b.customer && b.customer.number, 30) },
  analysis: { summary: str(an.summary, 1500), structuredData: { callback_requested: !!(an.structuredData && an.structuredData.callback_requested === true) } },
  artifact: { transcript: str(a.transcript || b.transcript, 60000), recordingUrl: str(a.recordingUrl || b.recordingUrl, 1000) },
};
return { json: { record: { p_provider_call_id: plan.id, p_status_code: Number.isFinite(status) ? status : null, p_call: call } } };
