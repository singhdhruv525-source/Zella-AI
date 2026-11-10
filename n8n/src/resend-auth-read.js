// Read exact bytes for the mandatory database key and signature check.
const j = $json;
const h = j.headers || {};
let raw = '';
try { raw = (await this.helpers.getBinaryDataBuffer(0, 'data')).toString('utf8'); } catch (e) { raw = ''; }
if (raw.length > 500000) raw = '';
return { json: { record: { p_key: typeof j.query?.key === 'string' ? j.query.key.slice(0, 200) : '', p_endpoint: '__ENDPOINT__', p_id: String(h['svix-id'] || '').slice(0, 200), p_timestamp: String(h['svix-timestamp'] || '').slice(0, 20), p_signature: String(h['svix-signature'] || '').slice(0, 500), p_raw: raw || null } } };
