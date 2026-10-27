// Zella - Vapi webhooks: hand the database the exact request bytes and the signature headers. The database checks the
// signature, the timestamp and that the request is new (zella_vapi_authenticate); the secret never reaches n8n.
// Nothing else in the workflow runs unless the answer is "ok".
const first = $input.first() || { json: {} };
const h = first.json.headers && typeof first.json.headers === 'object' ? first.json.headers : {};
const headers = {};
for (const k of ['x-signature', 'x-timestamp', 'authorization']) if (typeof h[k] === 'string') headers[k] = h[k].slice(0, 1000);
let raw = '';
try {
  const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
  raw = buf.toString('utf8');
} catch (e) { raw = ''; }
if (raw.length > 262144) raw = '';
return [{ json: { record: { p_raw: raw, p_headers: headers } } }];
