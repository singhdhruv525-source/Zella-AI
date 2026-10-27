// Zella - Call Results: turn Vapi's end-of-call report into one database call.
// A call Zella placed -> record (callback / task result). A call a customer made to the business -> inbound (call wrap-up).
// Anything else is ignored (record: null, inbound: null).
// The call carries zella_source and zella_id in its metadata (set by Outbound Calls).
const body = $json.body && typeof $json.body === 'object' ? $json.body : {};
const m = body.message && typeof body.message === 'object' ? body.message : {};
const none = { json: { record: null, inbound: null, status: null } };
// Call status (ringing, in-progress, forwarding, ended): recorded as it happens, so a lost end-of-call report can't
// erase the call. The database applies each status once and in order, and finds the business from the called number.
if (m.type === 'status-update') {
  const call = m.call && typeof m.call === 'object' ? m.call : {};
  const id = typeof call.id === 'string' ? call.id.slice(0, 200) : '';
  const st = typeof m.status === 'string' ? m.status : '';
  if (!id || !['ringing', 'in-progress', 'forwarding', 'ended'].includes(st)) return none;
  const t = typeof m.timestamp === 'number' ? m.timestamp : Date.parse(m.timestamp || '');
  const phone = (x) => (typeof x === 'string' && /^\+?[0-9() .-]{7,20}$/.test(x) ? x.slice(0, 30) : null);
  const pn = (call.phoneNumber && typeof call.phoneNumber === 'object' ? call.phoneNumber : m.phoneNumber && typeof m.phoneNumber === 'object' ? m.phoneNumber : {});
  return { json: { record: null, inbound: null, status: {
    p_provider_call_id: id, p_status: st, p_called_number: phone(pn.number),
    p_vapi_phone_number_id: typeof call.phoneNumberId === 'string' ? call.phoneNumberId.slice(0, 100) : null,
    p_from_number: phone(call.customer && call.customer.number),
    p_direction: /inbound/i.test(String(call.type || '')) ? 'inbound' : /outbound/i.test(String(call.type || '')) ? 'outbound' : 'other',
    p_event_at: isNaN(t) ? null : new Date(t).toISOString(),
    p_ended_reason: typeof m.endedReason === 'string' ? m.endedReason.slice(0, 80) : null } } };
}
if (m.type !== 'end-of-call-report') return none;

const call = m.call && typeof m.call === 'object' ? m.call : {};
const meta = call.metadata && typeof call.metadata === 'object' ? call.metadata : {};
const source = meta.zella_source === 'callback' ? 'callback' : meta.zella_source === 'task' ? 'task' : null;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
if (!source || typeof meta.zella_id !== 'string' || !uuid.test(meta.zella_id)) {
  // a customer called the business
  const cid = typeof call.id === 'string' ? call.id.slice(0, 200) : '';
  if (!cid || !/inbound/i.test(String(call.type || ''))) return none;
  const iso = (v) => { const t = Date.parse(v); return isNaN(t) ? null : new Date(t).toISOString(); };
  const a = m.analysis && typeof m.analysis === 'object' ? m.analysis : {};
  const sd = a.structuredData && typeof a.structuredData === 'object' ? a.structuredData : {};
  const sum = String(m.summary || a.summary || '').replace(/\s+/g, ' ').trim().slice(0, 1500);
  const ask = sd.callback_requested === true || /(asked|wants?|requested|would like) (for )?(a |to be |someone to )?(call ?back|called back|call (them|her|him) back|return (the |a )?call)/i.test(sum);
  const phone = (x) => (typeof x === 'string' ? x.slice(0, 30) : null);
  return { json: { record: null, inbound: {
    p_provider_call_id: cid, p_called_number: phone(m.phoneNumber && m.phoneNumber.number), p_vapi_phone_number_id: typeof call.phoneNumberId === 'string' ? call.phoneNumberId.slice(0, 100) : null,
    p_from_number: phone(call.customer && call.customer.number), p_started_at: iso(m.startedAt || call.startedAt), p_ended_at: iso(m.endedAt || call.endedAt),
    p_seconds: Number.isFinite(Number(m.durationSeconds)) ? Math.round(Number(m.durationSeconds)) : null, p_reason: String(m.endedReason || call.endedReason || '').slice(0, 80),
    p_summary: sum || null, p_recording_url: typeof m.recordingUrl === 'string' && /^https:\/\//.test(m.recordingUrl) ? m.recordingUrl.slice(0, 1000) : null,
    p_transcript: typeof m.transcript === 'string' ? m.transcript.slice(0, 60000) : null, p_wants_callback: ask } } };
}

const reason = String(m.endedReason || call.endedReason || '').toLowerCase();
const seconds = Number(m.durationSeconds);
const talked = !isNaN(seconds) && seconds >= 8;

let outcome;
if (/voicemail/.test(reason)) outcome = 'voicemail';
else if (/did-not-answer|no-answer/.test(reason)) outcome = 'no_answer';
else if (/busy/.test(reason)) outcome = 'busy';
else if (/invalid|misdial|unallocated|number-not|not-a-valid/.test(reason)) outcome = 'invalid_number';
else if (/customer-ended-call|assistant-ended-call|silence-timed-out|exceeded-max-duration|assistant-forwarded-call|assistant-said-end-call/.test(reason)) outcome = talked ? 'connected' : 'no_answer';
else outcome = 'failed_connection';

const summary = String(m.summary || (m.analysis && m.analysis.summary) || '').replace(/\s+/g, ' ').trim().slice(0, 250);
const providerId = typeof call.id === 'string' ? call.id.slice(0, 200) : null;

let finalOutcome = outcome;
let notes = summary || ('vapi_' + reason.replace(/[^a-z0-9-]/g, '').slice(0, 60));
if (source === 'task') {
  if (outcome === 'connected') {
    const said = m.analysis && m.analysis.structuredData && m.analysis.structuredData.outcome;
    finalOutcome = ['rescheduled', 'wants_callback', 'declined'].includes(said) ? said : 'wants_callback';
    if (!summary) notes = 'Spoke with the customer; no summary was returned.';
  } else if (outcome === 'busy') finalOutcome = 'no_answer';
  else if (outcome === 'invalid_number' || outcome === 'failed_connection') finalOutcome = 'failed';
}

return { json: { inbound: null, record: { p_source: source, p_id: meta.zella_id, p_outcome: finalOutcome, p_provider_call_id: providerId, p_notes: notes } } };
