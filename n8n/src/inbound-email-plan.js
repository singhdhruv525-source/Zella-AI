// Zella - Inbound Email: Resend tells us an email arrived (event email.received). The event only says WHO and WHICH email,
// so the next step fetches the email itself. The secret key in the webhook address is checked by the database.
const key = typeof ($json.query && $json.query.key) === 'string' ? $json.query.key.slice(0, 200) : '';
const event = $json.body && typeof $json.body === 'object' && !Array.isArray($json.body) ? $json.body : null;
const data = event && event.data && typeof event.data === 'object' ? event.data : {};
const emailId = typeof data.email_id === 'string' && /^[A-Za-z0-9_-]{8,100}$/.test(data.email_id) ? data.email_id : null;
if (!event || event.type !== 'email.received' || !emailId || !key) return { json: { fetch: null } };
return { json: { key, fetch: { url: 'https://api.resend.com/emails/receiving/' + emailId }, hint: { to: data.to, from: data.from, subject: data.subject, message_id: data.message_id } } };
