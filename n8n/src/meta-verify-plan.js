// Zella - Meta Webhook (set-up check): when the webhook is first connected, Meta sends a word and a challenge.
// We hand the word to the database, which compares it with the secret in Vault, and echo the challenge only if it matches.
const q = $json.query && typeof $json.query === 'object' ? $json.query : {};
const mode = typeof q['hub.mode'] === 'string' ? q['hub.mode'] : '';
const token = typeof q['hub.verify_token'] === 'string' ? q['hub.verify_token'].slice(0, 200) : '';
const challenge = typeof q['hub.challenge'] === 'string' && /^[A-Za-z0-9_-]{1,100}$/.test(q['hub.challenge']) ? q['hub.challenge'] : '';
return { json: { check: mode === 'subscribe' && !!token && !!challenge, challenge, record: { p_token: token } } };
