// Zella Voice - the business's own mailbox: with the access token, build the one send request. Gmail takes the whole
// email (RFC 5322, base64url, users.messages.send); Microsoft Graph takes a message (sendMail; it sends from the signed
// in account). Header values are made safe: no line breaks, a name that isn't plain ASCII is encoded.
const prev = $('After log').item.json;
const plan = $('Plan mailbox').item.json;
const status = Number($json.statusCode);
const t = $json.body && typeof $json.body === 'object' ? $json.body : {};
if (!(status >= 200 && status < 300) || typeof t.access_token !== 'string' || !t.access_token) {
  return { json: { mailbox_fail: t.error === 'invalid_grant' ? 'sign_in' : 'token_failed' } };
}
const m = prev.mail || {};
const one = (s) => String(s == null ? '' : s).replace(/[\r\n]+/g, ' ').trim();
const addr = (s) => { const a = one(s).toLowerCase(); return /^[^@\s,;<>"]+@[^@\s,;<>"]+\.[^@\s,;<>"]+$/.test(a) ? a : null; };
const to = addr(m.to), from = addr(m.from), replyTo = addr(m.reply_to);
if (!to || !from) return { json: { mailbox_fail: 'token_failed' } };

if (plan.provider === 'outlook') {
  const message = { subject: one(m.subject).slice(0, 300), body: { contentType: 'HTML', content: String(m.html || '') }, toRecipients: [{ emailAddress: { address: to } }] };
  if (replyTo) message.replyTo = [{ emailAddress: { address: replyTo } }];
  return { json: { mailbox_fail: null, access_token: t.access_token, request: { url: 'https://graph.microsoft.com/v1.0/me/sendMail', body: { message, saveToSentItems: true } } } };
}

const b64 = (s) => Buffer.from(String(s), 'utf8').toString('base64');
const word = (s) => (/^[\x20-\x7e]*$/.test(s) ? s : '=?UTF-8?B?' + b64(s) + '?=');
const wrap = (s) => s.replace(/.{1,76}/g, '$&\r\n');
const name = one(m.from_name).replace(/["<>\\]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
const boundary = 'zella_voice_' + String(prev.message_id || 'x').replace(/[^0-9a-z]/gi, '').slice(0, 40);
const headers = [
  'From: ' + (name ? (/^[\x20-\x7e]*$/.test(name) ? '"' + name + '"' : word(name)) + ' <' + from + '>' : from),
  'To: ' + to,
  ...(replyTo ? ['Reply-To: ' + replyTo] : []),
  'Subject: ' + word(one(m.subject).slice(0, 300)),
  ...(typeof m.unsubscribe_url === 'string' && /^https:\/\/[^\s<>]+$/.test(m.unsubscribe_url) ? ['List-Unsubscribe: <' + m.unsubscribe_url + '>'] : []),
  'MIME-Version: 1.0',
  'Content-Type: multipart/alternative; boundary="' + boundary + '"',
];
const mime = headers.join('\r\n') + '\r\n\r\n'
  + '--' + boundary + '\r\nContent-Type: text/plain; charset="UTF-8"\r\nContent-Transfer-Encoding: base64\r\n\r\n' + wrap(b64(m.text || ''))
  + '--' + boundary + '\r\nContent-Type: text/html; charset="UTF-8"\r\nContent-Transfer-Encoding: base64\r\n\r\n' + wrap(b64(m.html || ''))
  + '--' + boundary + '--\r\n';
const raw = b64(mime).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
return { json: { mailbox_fail: null, access_token: t.access_token, request: { url: 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send', body: { raw } } } };
