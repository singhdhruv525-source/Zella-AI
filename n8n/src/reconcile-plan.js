// Zella - Call Reconciliation: fetch the provider's own record of a call whose end-of-call report never arrived.
// The database chose the call (zella_calls_to_reconcile); only a well-formed provider call id is ever put in a URL.
const id = typeof $json.provider_call_id === 'string' ? $json.provider_call_id : '';
if (!/^[A-Za-z0-9_-]{6,100}$/.test(id)) return { json: { skip: true, id: null } };
return { json: { skip: false, id, url: 'https://api.vapi.ai/call/' + encodeURIComponent(id) } };
