// Zella - Connection Tests: one claimed provider name in, a clean provider name out.
// Only the three known providers pass; anything else is dropped so a bad row can never choose where a request goes.
const p = String($json.provider || '');
if (!['telnyx', 'vapi', 'resend'].includes(p)) return { json: { provider: null } };
return { json: { provider: p } };
