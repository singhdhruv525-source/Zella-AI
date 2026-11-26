// Zella Voice - the business's own mailbox: after the database handed out the mailbox's sign in for this one email
// (zella_business_email_mailbox_credentials), get ready to ask the provider for a short lived access token.
// The refresh token passes through this run only; these workflows keep no execution data.
const prev = $('After log').item.json;
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
if (!(status >= 200 && status < 300) || b.ok !== true || typeof b.refresh_token !== 'string' || !b.refresh_token || b.provider !== prev.transport) {
  return { json: { mailbox_fail: 'not_connected', provider: prev.transport, token_form: null } };
}
return { json: { mailbox_fail: null, provider: b.provider, token_form: { refresh_token: b.refresh_token } } };
