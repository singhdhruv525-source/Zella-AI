// @ts-self-types="./vapi-call-events.d.ts"
// Vapi call events -> the database call that records them. ONE implementation, used by the voice-rules edge function
// (import) and by n8n Call Results (inlined at build time by n8n/src/load.mjs, with the `export` keyword removed).
// No network, no secrets. Field names follow Vapi's ServerMessage schema (@vapi-ai/server-sdk 3.0.0):
//   status-update:      message.status, message.endedReason (only when ended), message.timestamp (number), message.call
//   end-of-call-report: message.endedReason, message.startedAt / endedAt (ISO), message.artifact.{transcript, recordingUrl},
//                       message.analysis.{summary, structuredData}, message.call
// Older top-level fields (summary, transcript, recordingUrl, durationSeconds) are still read when present.
// Returns { record, inbound, status }: at most one is set; all null means "nothing to record".

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LIVE_STATUSES = ['ringing', 'in-progress', 'forwarding', 'ended'];
const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const o = (v) => (isObj(v) ? v : {});
const phoneOrNull = (x) => (typeof x === 'string' && /^\+?[0-9() .-]{7,20}$/.test(x) ? x.slice(0, 30) : null);
const iso = (v) => { if (typeof v !== 'string') return null; const t = Date.parse(v); return Number.isNaN(t) ? null : new Date(t).toISOString(); };

// Vapi sends message.timestamp as a number; its unit is not stated in the schema. Milliseconds are assumed, and a value
// that can only be seconds (before the year 2001 as milliseconds) is read as seconds, so a call is never dated 1970.
export function eventTime(ts) {
  const t = typeof ts === 'number' ? ts : typeof ts === 'string' && /^[0-9]{9,13}$/.test(ts) ? Number(ts) : Date.parse(String(ts || ''));
  if (!Number.isFinite(t) || t <= 0) return null;
  return new Date(t < 1e12 ? t * 1000 : t).toISOString();
}

// Duration only from what the provider reported: its own duration, or the gap between its own start and end times.
function seconds(m) {
  const d = Number(m.durationSeconds);
  if (m.durationSeconds !== undefined && m.durationSeconds !== null && Number.isFinite(d) && d >= 0) return Math.round(d);
  const call = o(m.call);
  const a = Date.parse(m.startedAt || call.startedAt || ''), b = Date.parse(m.endedAt || call.endedAt || '');
  return Number.isFinite(a) && Number.isFinite(b) && b >= a ? Math.round((b - a) / 1000) : null;
}

export function planCallEvent(message) {
  const m = o(message);
  const call = o(m.call);
  const none = { record: null, inbound: null, status: null };
  const pn = isObj(call.phoneNumber) ? call.phoneNumber : o(m.phoneNumber);
  const callId = typeof call.id === 'string' && call.id ? call.id.slice(0, 200) : '';
  const direction = /inbound/i.test(String(call.type || '')) ? 'inbound' : /outbound/i.test(String(call.type || '')) ? 'outbound' : 'other';

  // Call status: recorded as it happens, so a lost end-of-call report can't erase the call. The database applies each
  // status once and in order (late or repeated events change nothing) and finds the business from the called number.
  if (m.type === 'status-update') {
    const st = typeof m.status === 'string' ? m.status : '';
    if (!callId || !LIVE_STATUSES.includes(st)) return none;
    return { ...none, status: {
      p_provider_call_id: callId, p_status: st, p_called_number: phoneOrNull(pn.number),
      p_vapi_phone_number_id: typeof call.phoneNumberId === 'string' ? call.phoneNumberId.slice(0, 100) : typeof pn.id === 'string' ? pn.id.slice(0, 100) : null,
      p_from_number: phoneOrNull(o(call.customer).number), p_direction: direction, p_event_at: eventTime(m.timestamp),
      p_ended_reason: typeof m.endedReason === 'string' ? m.endedReason.slice(0, 80) : null } };
  }
  if (m.type !== 'end-of-call-report') return none;

  const art = o(m.artifact);
  const an = o(m.analysis);
  const sd = o(an.structuredData);
  const meta = o(call.metadata);
  const reasonRaw = String(m.endedReason || call.endedReason || '');
  const secs = seconds(m);
  const source = meta.zella_source === 'callback' ? 'callback' : meta.zella_source === 'task' ? 'task' : null;

  if (!source || typeof meta.zella_id !== 'string' || !UUID.test(meta.zella_id)) {
    // a customer called the business
    if (!callId || direction !== 'inbound') return none;
    const sum = String(an.summary || m.summary || '').replace(/\s+/g, ' ').trim().slice(0, 1500);
    const ask = sd.callback_requested === true || /(asked|wants?|requested|would like) (for )?(a |to be |someone to )?(call ?back|called back|call (them|her|him) back|return (the |a )?call)/i.test(sum);
    const rec = typeof art.recordingUrl === 'string' ? art.recordingUrl : m.recordingUrl;
    const tr = typeof art.transcript === 'string' ? art.transcript : m.transcript;
    return { ...none, inbound: {
      p_provider_call_id: callId, p_called_number: typeof pn.number === 'string' ? pn.number.slice(0, 30) : null,
      p_vapi_phone_number_id: typeof call.phoneNumberId === 'string' ? call.phoneNumberId.slice(0, 100) : null,
      p_from_number: typeof o(call.customer).number === 'string' ? call.customer.number.slice(0, 30) : null,
      p_started_at: iso(m.startedAt || call.startedAt), p_ended_at: iso(m.endedAt || call.endedAt),
      p_seconds: secs, p_reason: reasonRaw.slice(0, 80), p_summary: sum || null,
      p_recording_url: typeof rec === 'string' && /^https:\/\//.test(rec) ? rec.slice(0, 1000) : null,
      p_transcript: typeof tr === 'string' ? tr.slice(0, 60000) : null, p_wants_callback: ask } };
  }

  // a call Zella placed (a callback or a follow-up task)
  const reason = reasonRaw.toLowerCase();
  const talked = secs !== null && secs >= 8;
  let outcome;
  if (/voicemail/.test(reason)) outcome = 'voicemail';
  else if (/did-not-answer|no-answer/.test(reason)) outcome = 'no_answer';
  else if (/busy/.test(reason)) outcome = 'busy';
  else if (/invalid|misdial|unallocated|number-not|not-a-valid/.test(reason)) outcome = 'invalid_number';
  else if (/customer-ended-call|assistant-ended-call|silence-timed-out|exceeded-max-duration|assistant-forwarded-call|assistant-said-end-call/.test(reason)) outcome = talked ? 'connected' : 'no_answer';
  else outcome = 'failed_connection';

  const summary = String(an.summary || m.summary || '').replace(/\s+/g, ' ').trim().slice(0, 250);
  let finalOutcome = outcome;
  let notes = summary || ('vapi_' + reason.replace(/[^a-z0-9-]/g, '').slice(0, 60));
  if (source === 'task') {
    if (outcome === 'connected') {
      finalOutcome = ['rescheduled', 'wants_callback', 'declined'].includes(sd.outcome) ? sd.outcome : 'wants_callback';
      if (!summary) notes = 'Spoke with the customer; no summary was returned.';
    } else if (outcome === 'busy') finalOutcome = 'no_answer';
    else if (outcome === 'invalid_number' || outcome === 'failed_connection') finalOutcome = 'failed';
  }
  return { ...none, record: { p_source: source, p_id: meta.zella_id, p_outcome: finalOutcome, p_provider_call_id: callId || null, p_notes: notes } };
}
