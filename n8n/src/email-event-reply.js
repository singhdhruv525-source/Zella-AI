// Zella - Email Events: answer Resend. 200 when handled (so it does not resend), 401 for a wrong key,
// 500 when the database could not be reached (Resend then tries again later). No details are returned.
const plan = $('Plan').item.json;
if (!plan.record) return { json: { status: 400, body: { ok: false } } };
const r = $json;
const code = Number(r.statusCode);
const result = typeof r.body === 'string' ? r.body : '';
if (code >= 200 && code < 300) {
  if (result === 'unauthorized') return { json: { status: 401, body: { ok: false } } };
  if (result === 'not_configured') return { json: { status: 503, body: { ok: false } } };
  return { json: { status: 200, body: { ok: true } } };
}
return { json: { status: 500, body: { ok: false } } };
