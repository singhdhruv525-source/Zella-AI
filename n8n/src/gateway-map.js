// Zella - Event Gateway: turn the database answer into a short, safe reply.
// Input: the full HTTP response from zella_ingest_event ({ statusCode, body }).
const r = $json;
if (r.statusCode >= 200 && r.statusCode < 300 && r.body && typeof r.body === 'object') {
  return { json: { status: 200, body: { ok: true, id: r.body.id, duplicate: r.body.duplicate === true } } };
}
const text = JSON.stringify(r.body ?? '');
if (text.includes('INVALID_BUSINESS')) return { json: { status: 422, body: { ok: false, error: 'unknown_business' } } };
if (text.includes('BUSINESS_NOT_AVAILABLE')) return { json: { status: 422, body: { ok: false, error: 'business_not_available' } } };
if (r.statusCode === 400 || r.statusCode === 409 || r.statusCode === 422) return { json: { status: 422, body: { ok: false, error: 'event_rejected' } } };
// Never pass database details back to the caller.
return { json: { status: 502, body: { ok: false, error: 'storage_failed' } } };
