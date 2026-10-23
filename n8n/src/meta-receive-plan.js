// Zella - Meta Webhook: Meta posts events here (leads, messages, comments). The exact bytes it sent are kept, because the
// signature is made over those bytes. The database checks the signature with the app secret in Vault; this step never sees it.
const first = $input.first();
const headers = first.json.headers && typeof first.json.headers === 'object' ? first.json.headers : {};
const sig = typeof headers['x-hub-signature-256'] === 'string' ? headers['x-hub-signature-256'].slice(0, 100) : '';
let raw = '';
try {
  const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
  raw = buf.toString('utf8');
} catch (e) { raw = ''; }
if (raw.length > 500000) raw = '';
return [{ json: { ok: !!raw && !!sig, record: { p_raw: raw, p_signature: sig } } }];
