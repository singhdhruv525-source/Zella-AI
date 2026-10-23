// Zella - Call Results: turn Vapi's end-of-call report into one database call.
// Anything that is not an end-of-call report for a call Zella placed is ignored (record: null).
// The call carries zella_source and zella_id in its metadata (set by Outbound Calls).
const body = $json.body && typeof $json.body === 'object' ? $json.body : {};
const m = body.message && typeof body.message === 'object' ? body.message : {};
const none = { json: { record: null } };
if (m.type !== 'end-of-call-report') return none;

const call = m.call && typeof m.call === 'object' ? m.call : {};
const meta = call.metadata && typeof call.metadata === 'object' ? call.metadata : {};
const source = meta.zella_source === 'callback' ? 'callback' : meta.zella_source === 'task' ? 'task' : null;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
if (!source || typeof meta.zella_id !== 'string' || !uuid.test(meta.zella_id)) return none;

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

return { json: { record: { p_source: source, p_id: meta.zella_id, p_outcome: finalOutcome, p_provider_call_id: providerId, p_notes: notes } } };
